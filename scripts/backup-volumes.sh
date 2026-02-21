#!/usr/bin/env bash
# backup-volumes.sh — Create compressed backups of all Docker volumes
# used by the Coroot production stack before performing updates.
#
# Usage:
#   ssh root@VPS 'bash -s' < scripts/backup-volumes.sh
#
# Backups are stored in /opt/coroot/backups/<timestamp>/
# Retains the last 3 backups, prunes older ones.
#
# Also saves a manifest of current image digests for rollback reference.

set -euo pipefail

COMPOSE_DIR="/opt/coroot"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
COMPOSE_PROJECT="coroot"
BACKUP_ROOT="/opt/coroot/backups"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_DIR="${BACKUP_ROOT}/${TIMESTAMP}"
MAX_BACKUPS=3

# All volumes to back up (must match docker-compose.yml volume names)
# Format: "volume_name:description"
VOLUMES=(
  "${COMPOSE_PROJECT}_coroot_data:Coroot application data"
  "${COMPOSE_PROJECT}_prometheus_data:Prometheus TSDB"
  "${COMPOSE_PROJECT}_clickhouse_data:ClickHouse data"
  "${COMPOSE_PROJECT}_clickhouse_logs:ClickHouse logs"
  "${COMPOSE_PROJECT}_node_agent_data:Node agent WAL"
  "${COMPOSE_PROJECT}_cluster_agent_data:Cluster agent WAL"
  "${COMPOSE_PROJECT}_caddy_data:Caddy TLS certificates"
  "${COMPOSE_PROJECT}_caddy_config:Caddy configuration"
)

# Services that should be stopped for consistent backups
# (data-writing services only; caddy can stay up to maintain TLS)
STOP_FOR_BACKUP=(
  "coroot"
  "prometheus"
  "clickhouse"
  "node-agent"
  "cluster-agent"
)

echo "=== Coroot Stack Volume Backup ==="
echo "Timestamp: ${TIMESTAMP}"
echo "Backup dir: ${BACKUP_DIR}"
echo ""

# Create backup directory
mkdir -p "${BACKUP_DIR}"

# Save current image digests manifest (for rollback reference)
echo "--- Saving image digest manifest ---"
MANIFEST_FILE="${BACKUP_DIR}/image-manifest.txt"
{
  echo "# Image digest manifest — ${TIMESTAMP}"
  echo "# Used by rollback.sh to restore exact image versions"
  echo ""
  for service in coroot node-agent cluster-agent prometheus clickhouse caddy; do
    container_id=$(docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" \
      ps -q "${service}" 2>/dev/null || true)
    if [[ -n "${container_id}" ]]; then
      image_info=$(docker inspect --format='{{.Config.Image}}' "${container_id}" 2>/dev/null || echo "unknown")
      repo_digest=$(docker inspect --format='{{index .Image}}' "${container_id}" 2>/dev/null || echo "unknown")
      echo "${service}|${image_info}|${repo_digest}"
    else
      echo "${service}|unknown|unknown"
    fi
  done
} > "${MANIFEST_FILE}"
echo "  Saved to ${MANIFEST_FILE}"
echo ""

# Save the current docker-compose.yml and Caddyfile
echo "--- Saving configuration files ---"
cp "${COMPOSE_FILE}" "${BACKUP_DIR}/docker-compose.yml"
if [[ -f "${COMPOSE_DIR}/Caddyfile" ]]; then
  cp "${COMPOSE_DIR}/Caddyfile" "${BACKUP_DIR}/Caddyfile"
fi
echo "  Configuration files saved"
echo ""

# Stop services for consistent backup
echo "--- Stopping services for consistent backup ---"
for service in "${STOP_FOR_BACKUP[@]}"; do
  echo "  Stopping ${service}..."
  docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" stop "${service}" 2>/dev/null || true
done
echo "  All data services stopped"
echo ""

# Back up each volume
echo "--- Backing up volumes ---"
backup_failed=false
total_size=0

for vol_entry in "${VOLUMES[@]}"; do
  vol_name="${vol_entry%%:*}"
  vol_desc="${vol_entry#*:}"
  archive_name="${vol_name}.tar.gz"

  echo "  Backing up: ${vol_name} (${vol_desc})"

  # Check if volume exists
  if ! docker volume inspect "${vol_name}" > /dev/null 2>&1; then
    echo "    WARNING: Volume ${vol_name} does not exist, skipping"
    continue
  fi

  # Create compressed backup using an alpine container
  if docker run --rm \
    -v "${vol_name}:/source:ro" \
    -v "${BACKUP_DIR}:/backup" \
    alpine \
    tar czf "/backup/${archive_name}" -C /source . 2>/dev/null; then
    size=$(du -sh "${BACKUP_DIR}/${archive_name}" | cut -f1)
    echo "    Done: ${archive_name} (${size})"
    total_size=$((total_size + $(stat -c%s "${BACKUP_DIR}/${archive_name}" 2>/dev/null || stat -f%z "${BACKUP_DIR}/${archive_name}" 2>/dev/null || echo 0)))
  else
    echo "    ERROR: Failed to back up ${vol_name}"
    backup_failed=true
  fi
done

echo ""
echo "  Total backup size: $(numfmt --to=iec ${total_size} 2>/dev/null || echo "${total_size} bytes")"
echo ""

# Restart services
echo "--- Restarting services ---"
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" up -d
echo "  Services restarting"
echo ""

# Wait for health checks
echo "--- Waiting for services to become healthy ---"
max_wait=120
elapsed=0
while [[ ${elapsed} -lt ${max_wait} ]]; do
  healthy_count=$(docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" \
    ps --format json 2>/dev/null | grep -c '"healthy"' || echo "0")
  # coroot, prometheus, clickhouse should be healthy (3 services)
  if [[ ${healthy_count} -ge 3 ]]; then
    echo "  All services healthy after ${elapsed}s"
    break
  fi
  sleep 5
  elapsed=$((elapsed + 5))
  echo "  Waiting... (${elapsed}s/${max_wait}s, ${healthy_count}/3 healthy)"
done

if [[ ${elapsed} -ge ${max_wait} ]]; then
  echo "  WARNING: Not all services became healthy within ${max_wait}s"
  echo "  Continuing anyway — services may still be starting"
fi
echo ""

# Prune old backups (keep last MAX_BACKUPS)
echo "--- Pruning old backups (keeping last ${MAX_BACKUPS}) ---"
backup_count=$(ls -1d "${BACKUP_ROOT}"/[0-9]* 2>/dev/null | wc -l)
if [[ ${backup_count} -gt ${MAX_BACKUPS} ]]; then
  prune_count=$((backup_count - MAX_BACKUPS))
  ls -1d "${BACKUP_ROOT}"/[0-9]* | head -n "${prune_count}" | while read -r old_backup; do
    echo "  Removing: ${old_backup}"
    rm -rf "${old_backup}"
  done
  echo "  Pruned ${prune_count} old backup(s)"
else
  echo "  No pruning needed (${backup_count}/${MAX_BACKUPS} backups)"
fi
echo ""

# Final status
if [[ "${backup_failed}" == true ]]; then
  echo "=== BACKUP COMPLETED WITH ERRORS ==="
  echo "Some volumes failed to back up. Check output above."
  exit 1
else
  echo "=== BACKUP COMPLETED SUCCESSFULLY ==="
  echo "Backup location: ${BACKUP_DIR}"
  ls -lh "${BACKUP_DIR}/"

  # Write backup path for use by other scripts
  echo "${BACKUP_DIR}" > "${BACKUP_ROOT}/latest"
  echo ""
  echo "Latest backup pointer: ${BACKUP_ROOT}/latest"
fi
