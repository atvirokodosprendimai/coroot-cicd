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
echo "Restoring from: ${BACKUP_DIR}"
echo ""

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
      ps "${service}" 2>/dev/null | grep -c "(healthy)" || echo "0")
    if [[ ${health} -gt 0 ]]; then
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

# Verify with HTTP probes
echo "--- Post-rollback health probes ---"
probes_passed=true
for endpoint in "http://localhost:8080/:Coroot" "http://localhost:9090/-/healthy:Prometheus" "http://localhost:8123/ping:ClickHouse"; do
  url="${endpoint%%:*}:${endpoint#*:}"
  # Re-parse: URL is everything before the last colon-separated name
  url=$(echo "${endpoint}" | sed 's/:[^:]*$//')
  name=$(echo "${endpoint}" | grep -oP '[^:]+$')

  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${url}" 2>/dev/null || echo "000")
  if [[ "${code}" == "200" ]]; then
    echo "  ${name}: HTTP ${code} — PASS"
  else
    echo "  ${name}: HTTP ${code} — FAIL"
    probes_passed=false
  fi
done
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
elif [[ "${all_healthy}" != true || "${probes_passed}" != true ]]; then
  echo "=== ROLLBACK COMPLETED — SERVICES NOT FULLY HEALTHY ==="
  echo "Volumes were restored but services are not all responding."
  echo "Check logs: docker compose -f ${COMPOSE_FILE} logs"
  exit 1
else
  echo "=== ROLLBACK SUCCESSFUL ==="
  echo "Stack restored from backup: ${BACKUP_DIR}"
  echo "All services are healthy and responding."
  exit 0
fi
