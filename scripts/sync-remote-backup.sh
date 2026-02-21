#!/usr/bin/env bash
# sync-remote-backup.sh — Sync local Coroot backups to a Hetzner Storage Box.
#
# Copies the latest backup from /opt/coroot/backups/ to the remote storage box
# via rsync over SSH. Retains the same number of backups remotely as locally.
#
# Prerequisites:
#   - Hetzner Storage Box with SSH key auth configured
#   - rsync installed on the VPS (default on Ubuntu 24.04)
#   - Storage Box SSH key at /root/.ssh/storagebox_ed25519
#
# Usage:
#   ssh root@VPS 'bash -s' < scripts/sync-remote-backup.sh
#
#   # Sync a specific backup
#   ssh root@VPS 'bash -s -- /opt/coroot/backups/20260221-040000' < scripts/sync-remote-backup.sh
#
#   # Dry run
#   ssh root@VPS 'bash -s -- --dry-run' < scripts/sync-remote-backup.sh
#
# Environment variables (can be set before calling, or defaults are used):
#   STORAGEBOX_USER   — Storage box SSH user (e.g., u123456)
#   STORAGEBOX_HOST   — Storage box hostname (e.g., u123456.your-storagebox.de)
#   STORAGEBOX_PATH   — Remote directory path (default: ./coroot-backups)
#   STORAGEBOX_PORT   — SSH port (default: 23, Hetzner Storage Box SSH port)
#   STORAGEBOX_KEY    — Path to SSH private key (default: /root/.ssh/storagebox_ed25519)
#
# Exit codes:
#   0 — sync successful
#   1 — sync failed

set -euo pipefail

DRY_RUN=false
SPECIFIC_BACKUP=""
POSITIONAL_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) POSITIONAL_ARGS+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

if [[ $# -ge 1 && -d "$1" ]]; then
  SPECIFIC_BACKUP="$1"
fi

# Configuration (override via environment variables)
STORAGEBOX_USER="${STORAGEBOX_USER:-}"
STORAGEBOX_HOST="${STORAGEBOX_HOST:-}"
STORAGEBOX_PATH="${STORAGEBOX_PATH:-./coroot-backups}"
STORAGEBOX_PORT="${STORAGEBOX_PORT:-23}"
STORAGEBOX_KEY="${STORAGEBOX_KEY:-/root/.ssh/storagebox_ed25519}"

LOCAL_BACKUP_ROOT="/opt/coroot/backups"
MAX_REMOTE_BACKUPS=3

echo "=== Remote Backup Sync ==="
if [[ "${DRY_RUN}" == true ]]; then
  echo "MODE: DRY RUN (no data will be transferred)"
fi
echo ""

# Validate configuration
if [[ -z "${STORAGEBOX_USER}" || -z "${STORAGEBOX_HOST}" ]]; then
  echo "ERROR: STORAGEBOX_USER and STORAGEBOX_HOST must be set."
  echo ""
  echo "Set them as environment variables or configure in /etc/coroot-backup.conf:"
  echo "  export STORAGEBOX_USER=u123456"
  echo "  export STORAGEBOX_HOST=u123456.your-storagebox.de"
  echo ""
  echo "To set up a Hetzner Storage Box:"
  echo "  1. Order a Storage Box from https://robot.hetzner.com/storage"
  echo "  2. Generate an SSH key: ssh-keygen -t ed25519 -f /root/.ssh/storagebox_ed25519 -N ''"
  echo "  3. Install the key: ssh-copy-id -i /root/.ssh/storagebox_ed25519 -p 23 -s u123456@u123456.your-storagebox.de"
  echo "  4. Test: ssh -i /root/.ssh/storagebox_ed25519 -p 23 u123456@u123456.your-storagebox.de ls"
  exit 1
fi

# Load config file if it exists
if [[ -f /etc/coroot-backup.conf ]]; then
  echo "Loading config from /etc/coroot-backup.conf"
  # shellcheck source=/dev/null
  source /etc/coroot-backup.conf
fi

# Validate SSH key exists
if [[ ! -f "${STORAGEBOX_KEY}" ]]; then
  echo "ERROR: SSH key not found at ${STORAGEBOX_KEY}"
  echo "Generate one with: ssh-keygen -t ed25519 -f ${STORAGEBOX_KEY} -N ''"
  exit 1
fi

SSH_OPTS="-i ${STORAGEBOX_KEY} -p ${STORAGEBOX_PORT} -o StrictHostKeyChecking=accept-new -o BatchMode=yes"
REMOTE_DEST="${STORAGEBOX_USER}@${STORAGEBOX_HOST}:${STORAGEBOX_PATH}"

echo "Local backup root:  ${LOCAL_BACKUP_ROOT}"
echo "Remote destination: ${REMOTE_DEST}"
echo "SSH key:            ${STORAGEBOX_KEY}"
echo "SSH port:           ${STORAGEBOX_PORT}"
echo ""

# Determine which backup to sync
if [[ -n "${SPECIFIC_BACKUP}" ]]; then
  BACKUP_TO_SYNC="${SPECIFIC_BACKUP}"
elif [[ -f "${LOCAL_BACKUP_ROOT}/latest" ]]; then
  BACKUP_TO_SYNC=$(cat "${LOCAL_BACKUP_ROOT}/latest")
else
  BACKUP_TO_SYNC=$(ls -1d "${LOCAL_BACKUP_ROOT}"/[0-9]* 2>/dev/null | tail -1 || true)
fi

if [[ -z "${BACKUP_TO_SYNC}" || ! -d "${BACKUP_TO_SYNC}" ]]; then
  echo "ERROR: No local backup found to sync."
  exit 1
fi

BACKUP_NAME=$(basename "${BACKUP_TO_SYNC}")
backup_size=$(du -sh "${BACKUP_TO_SYNC}" | cut -f1)
echo "Backup to sync: ${BACKUP_NAME} (${backup_size})"
echo ""

# Hetzner Storage Boxes do NOT provide a shell. They only support:
#   - SFTP (for listing, mkdir, rm)
#   - rsync over SSH
#   - SCP
# All remote operations must use sftp/rsync, not ssh commands.

RSYNC_RSH="ssh ${SSH_OPTS}"

# Helper: run SFTP commands on the storage box
sftp_cmd() {
  sftp -P "${STORAGEBOX_PORT}" -i "${STORAGEBOX_KEY}" \
    -o StrictHostKeyChecking=accept-new -o BatchMode=yes \
    "${STORAGEBOX_USER}@${STORAGEBOX_HOST}" <<< "$1" 2>/dev/null
}

# Test connectivity via SFTP
echo "--- Testing remote connectivity ---"
if sftp_cmd "ls" > /dev/null 2>&1; then
  echo "  Remote connection successful (SFTP)"
else
  echo "  ERROR: Could not connect to ${STORAGEBOX_HOST} via SFTP"
  echo "  Check STORAGEBOX_USER, STORAGEBOX_HOST, and SSH key configuration."
  exit 1
fi
echo ""

# Create remote directory structure via SFTP
echo "--- Ensuring remote directory exists ---"
sftp_cmd "mkdir ${STORAGEBOX_PATH}" > /dev/null 2>&1 || true
echo "  Remote directory ready: ${STORAGEBOX_PATH}"
echo ""

if [[ "${DRY_RUN}" == true ]]; then
  echo "--- DRY RUN: Would sync ---"
  echo "  Local:  ${BACKUP_TO_SYNC}/"
  echo "  Remote: ${REMOTE_DEST}/${BACKUP_NAME}/"
  echo ""

  echo "--- DRY RUN: Files that would be transferred ---"
  rsync -avz --dry-run \
    -e "${RSYNC_RSH}" \
    "${BACKUP_TO_SYNC}/" \
    "${REMOTE_DEST}/${BACKUP_NAME}/" 2>&1 | sed 's/^/  /' || echo "  (rsync dry-run failed — check connectivity)"
  echo ""

  echo "--- DRY RUN: Current remote backups ---"
  remote_listing=$(sftp_cmd "ls ${STORAGEBOX_PATH}" 2>/dev/null || true)
  remote_count=$(echo "${remote_listing}" | grep -c '[0-9]\{8\}-[0-9]\{6\}' || echo "0")
  echo "  Remote backups: ${remote_count} (max retained: ${MAX_REMOTE_BACKUPS})"
  echo ""
  echo "=== DRY RUN COMPLETE — no data transferred ==="
  exit 0
fi

# Sync the backup via rsync
echo "--- Syncing backup to remote ---"
echo "  ${BACKUP_TO_SYNC}/ -> ${REMOTE_DEST}/${BACKUP_NAME}/"

if rsync -avz --progress \
  -e "${RSYNC_RSH}" \
  "${BACKUP_TO_SYNC}/" \
  "${REMOTE_DEST}/${BACKUP_NAME}/"; then
  echo ""
  echo "  Sync completed successfully"
else
  echo ""
  echo "  ERROR: rsync failed"
  exit 1
fi
echo ""

# Prune old remote backups via SFTP (keep last MAX_REMOTE_BACKUPS)
echo "--- Pruning old remote backups (keeping last ${MAX_REMOTE_BACKUPS}) ---"
# List backup directories (format: YYYYMMDD-HHMMSS)
remote_listing=$(sftp_cmd "ls ${STORAGEBOX_PATH}" 2>/dev/null || true)
remote_backups=$(echo "${remote_listing}" | grep -oE '[0-9]{8}-[0-9]{6}' | sort || true)

if [[ -n "${remote_backups}" ]]; then
  remote_count=$(echo "${remote_backups}" | wc -l | tr -d '[:space:]')
  echo "  Remote backups: ${remote_count}"

  if [[ ${remote_count} -gt ${MAX_REMOTE_BACKUPS} ]]; then
    prune_count=$((remote_count - MAX_REMOTE_BACKUPS))
    echo "  Pruning ${prune_count} old backup(s)..."
    echo "${remote_backups}" | head -n "${prune_count}" | while read -r old_name; do
      echo "    Removing: ${STORAGEBOX_PATH}/${old_name}"
      # SFTP rm is not recursive; use a batch of commands to remove contents then dir
      # rsync --delete with an empty dir is the most reliable way on storage boxes
      empty_dir=$(mktemp -d)
      rsync -a --delete \
        -e "${RSYNC_RSH}" \
        "${empty_dir}/" \
        "${REMOTE_DEST}/${old_name}/" 2>/dev/null || true
      sftp_cmd "rmdir ${STORAGEBOX_PATH}/${old_name}" > /dev/null 2>&1 || true
      rmdir "${empty_dir}" 2>/dev/null || true
    done
  else
    echo "  No pruning needed (${remote_count}/${MAX_REMOTE_BACKUPS})"
  fi
else
  echo "  No remote backups found (first sync)"
fi
echo ""

# Verify the upload via SFTP
echo "--- Verifying remote backup ---"
verify_output=$(sftp_cmd "ls -l ${STORAGEBOX_PATH}/${BACKUP_NAME}/" 2>/dev/null || echo "VERIFICATION FAILED")
echo "${verify_output}" | sed 's/^/  /'
echo ""

echo "=== REMOTE BACKUP SYNC COMPLETE ==="
echo "Backup ${BACKUP_NAME} synced to ${REMOTE_DEST}/${BACKUP_NAME}/"
