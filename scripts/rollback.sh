#!/usr/bin/env bash
# rollback.sh — Restore Coroot stack from the latest backup.
# Stops all services, restores volumes from backup archives, restores
# the previous docker-compose.yml/Caddyfile, and restarts services.
#
# Usage:
#   # Rollback to latest backup
#   ssh root@VPS 'bash -s' < scripts/rollback.sh
#
#   # Rollback to a specific backup
#   ssh root@VPS 'bash -s -- /opt/coroot/backups/20260220-040000' < scripts/rollback.sh
#
# Exit codes:
#   0 — rollback successful
#   1 — rollback failed

set -euo pipefail

DRY_RUN=false
POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) POSITIONAL_ARGS+=("$1"); shift ;;
  esac
done
set -- "${POSITIONAL_ARGS[@]+"${POSITIONAL_ARGS[@]}"}"

COMPOSE_DIR="/opt/coroot"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
COMPOSE_PROJECT="coroot"
BACKUP_ROOT="/opt/coroot/backups"

# Determine which backup to restore from
if [[ $# -ge 1 && -d "$1" ]]; then
  BACKUP_DIR="$1"
elif [[ -f "${BACKUP_ROOT}/latest" ]]; then
  BACKUP_DIR=$(cat "${BACKUP_ROOT}/latest")
else
  # Find the most recent backup directory
  BACKUP_DIR=$(ls -1d "${BACKUP_ROOT}"/[0-9]* 2>/dev/null | tail -1 || true)
fi

if [[ -z "${BACKUP_DIR}" || ! -d "${BACKUP_DIR}" ]]; then
  echo "ERROR: No backup found to restore from."
  echo "Checked: ${BACKUP_ROOT}/latest and ${BACKUP_ROOT}/[timestamp]/"
  exit 1
fi

echo "=== Coroot Stack Rollback ==="
if [[ "${DRY_RUN}" == true ]]; then
  echo "MODE: DRY RUN (no changes will be made)"
fi
echo "Restoring from: ${BACKUP_DIR}"
echo ""

if [[ "${DRY_RUN}" == true ]]; then
  echo "--- DRY RUN: Verifying backup contents ---"
  if [[ -f "${BACKUP_DIR}/image-manifest.txt" ]]; then
    echo "  image-manifest.txt: found"
    echo "  Contents:"
    cat "${BACKUP_DIR}/image-manifest.txt" | grep -v '^#' | grep -v '^$' | sed 's/^/    /'
  else
    echo "  image-manifest.txt: NOT FOUND"
  fi
  echo ""

  echo "--- DRY RUN: Volume archives in backup ---"
  if ls "${BACKUP_DIR}"/*.tar.gz > /dev/null 2>&1; then
    ls -lh "${BACKUP_DIR}"/*.tar.gz | awk '{print "  " $NF " (" $5 ")"}'
  else
    echo "  No .tar.gz archives found"
  fi
  echo ""

  echo "--- DRY RUN: Would perform these actions ---"
  echo "  1. Stop all services (docker compose down)"
  echo "  2. Restore docker-compose.yml and Caddyfile from backup"
  echo "  3. Remove and recreate each volume, restore from archive"
  echo "  4. Start services (docker compose up -d)"
  echo "  5. Wait up to 120s for health checks"
  echo "  6. Verify external endpoint: https://table.beerpub.dev"
  echo ""

  echo "--- DRY RUN: Current service status ---"
  docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" ps 2>/dev/null || echo "  (could not query)"
  echo ""
  echo "=== DRY RUN COMPLETE — no changes made ==="
  exit 0
fi

# Verify backup contents
echo "--- Verifying backup contents ---"
required_files=(
  "image-manifest.txt"
)
for f in "${required_files[@]}"; do
  if [[ ! -f "${BACKUP_DIR}/${f}" ]]; then
    echo "WARNING: ${f} not found in backup. Continuing anyway."
  else
    echo "  Found: ${f}"
  fi
done

# List available volume archives
archive_count=$(ls -1 "${BACKUP_DIR}"/*.tar.gz 2>/dev/null | wc -l || echo "0")
echo "  Volume archives found: ${archive_count}"
ls -lh "${BACKUP_DIR}"/*.tar.gz 2>/dev/null || true
echo ""

# Stop all services
echo "--- Stopping all services ---"
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" down 2>/dev/null || true
echo "  All services stopped"
echo ""

# Restore configuration files
echo "--- Restoring configuration files ---"
if [[ -f "${BACKUP_DIR}/docker-compose.yml" ]]; then
  cp "${BACKUP_DIR}/docker-compose.yml" "${COMPOSE_FILE}"
  echo "  Restored: docker-compose.yml"
fi
if [[ -f "${BACKUP_DIR}/Caddyfile" ]]; then
  cp "${BACKUP_DIR}/Caddyfile" "${COMPOSE_DIR}/Caddyfile"
  echo "  Restored: Caddyfile"
fi
echo ""

# Restore volumes
echo "--- Restoring volumes from backup ---"
restore_failed=false

# Map of archive filenames to volume names
# Archives are named <project>_<volume_name>.tar.gz
for archive in "${BACKUP_DIR}"/*.tar.gz; do
  if [[ ! -f "${archive}" ]]; then
    continue
  fi

  archive_basename=$(basename "${archive}" .tar.gz)
  vol_name="${archive_basename}"

  echo "  Restoring: ${vol_name}"

  # Remove existing volume data and recreate
  docker volume rm "${vol_name}" 2>/dev/null || true
  docker volume create "${vol_name}" > /dev/null 2>&1

  # Restore from archive
  if docker run --rm \
    -v "${vol_name}:/dest" \
    -v "${BACKUP_DIR}:/backup:ro" \
    alpine \
    sh -c "rm -rf /dest/* && tar xzf /backup/$(basename "${archive}") -C /dest" 2>/dev/null; then
    echo "    Done"
  else
    echo "    ERROR: Failed to restore ${vol_name}"
    restore_failed=true
  fi
done

echo ""

# Start services with restored data
echo "--- Starting services with restored data ---"
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" up -d
echo "  Services starting"
echo ""

# Wait for health checks
echo "--- Waiting for services to become healthy ---"
max_wait=120
elapsed=0
all_healthy=false

while [[ ${elapsed} -lt ${max_wait} ]]; do
  sleep 5
  elapsed=$((elapsed + 5))

  healthy_count=0
  for service in coroot prometheus clickhouse; do
    health=$(docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" \
      ps "${service}" 2>/dev/null | grep -c "(healthy)" || true)
    health=$(echo "${health}" | tr -d '[:space:]')
    if [[ -n "${health}" && "${health}" -gt 0 ]] 2>/dev/null; then
      healthy_count=$((healthy_count + 1))
    fi
  done

  echo "  ${elapsed}s/${max_wait}s — ${healthy_count}/3 services healthy"

  if [[ ${healthy_count} -ge 3 ]]; then
    all_healthy=true
    break
  fi
done

echo ""

# Verify via external Caddy endpoint (services use 'expose:', not 'ports:',
# so localhost probes from the host won't work)
echo "--- Post-rollback health probe ---"
probes_passed=true
EXTERNAL_URL="https://table.beerpub.dev"

ext_retries=3
ext_ok=false
for i in $(seq 1 ${ext_retries}); do
  ext_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 10 --max-time 15 "${EXTERNAL_URL}/" 2>/dev/null || echo "000")
  if [[ "${ext_code}" == "200" ]]; then
    echo "  Coroot (${EXTERNAL_URL}): HTTP ${ext_code} — PASS"
    ext_ok=true
    break
  else
    echo "  Attempt ${i}/${ext_retries}: HTTP ${ext_code}, retrying in 5s..."
    sleep 5
  fi
done
if [[ "${ext_ok}" != true ]]; then
  echo "  Coroot (${EXTERNAL_URL}): FAIL after ${ext_retries} attempts"
  probes_passed=false
fi
echo ""

# Show current container status
echo "--- Container status ---"
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" ps
echo ""

# Final result
if [[ "${restore_failed}" == true ]]; then
  echo "=== ROLLBACK COMPLETED WITH ERRORS ==="
  echo "Some volumes could not be restored. Manual intervention may be needed."
  exit 1
elif [[ "${probes_passed}" != true ]]; then
  echo "=== ROLLBACK COMPLETED — SERVICES NOT FULLY HEALTHY ==="
  echo "Volumes were restored but HTTP probes failed."
  echo "Check logs: docker compose -f ${COMPOSE_FILE} logs"
  exit 1
else
  echo "=== ROLLBACK SUCCESSFUL ==="
  echo "Stack restored from backup: ${BACKUP_DIR}"
  echo "All services are healthy and responding."
  exit 0
fi
