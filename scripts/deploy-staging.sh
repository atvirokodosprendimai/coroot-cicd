#!/usr/bin/env bash
# deploy-staging.sh — Deploy the Coroot stack to a staging environment
# on the same VPS, run health checks, and report results.
#
# The staging stack uses separate volumes and ports so it doesn't
# interfere with production. It is torn down after validation.
#
# Usage:
#   # Copy compose file first, then run:
#   ssh root@VPS 'bash -s' < scripts/deploy-staging.sh
#
# Prerequisites:
#   - docker-compose.staging.yml must be present at /opt/coroot-staging/
#
# Exit codes:
#   0 — staging deployment and health checks passed
#   1 — staging deployment or health checks failed

set -euo pipefail

STAGING_DIR="/opt/coroot-staging"
COMPOSE_FILE="${STAGING_DIR}/docker-compose.staging.yml"
PROJECT_NAME="coroot-staging"
HEALTH_TIMEOUT=120
HEALTH_INTERVAL=5

echo "=== Staging Deployment ==="
echo "Directory: ${STAGING_DIR}"
echo "Project:   ${PROJECT_NAME}"
echo ""

# Ensure staging directory exists
mkdir -p "${STAGING_DIR}"

# Check that the compose file is present
if [[ ! -f "${COMPOSE_FILE}" ]]; then
  echo "ERROR: ${COMPOSE_FILE} not found."
  echo "Upload it before running this script."
  exit 1
fi

# Tear down any previous staging environment
echo "--- Cleaning up previous staging environment ---"
docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" down -v 2>/dev/null || true
echo "  Previous staging environment removed"
echo ""

# Pull latest images
echo "--- Pulling latest images ---"
docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" pull
echo "  Images pulled"
echo ""

# Start staging stack
echo "--- Starting staging stack ---"
docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" up -d
echo "  Staging stack started"
echo ""

# Wait for health checks
echo "--- Waiting for staging services to become healthy ---"
max_wait=${HEALTH_TIMEOUT}
elapsed=0
staging_healthy=false

while [[ ${elapsed} -lt ${max_wait} ]]; do
  sleep "${HEALTH_INTERVAL}"
  elapsed=$((elapsed + HEALTH_INTERVAL))

  # Check Docker Compose health status
  coroot_health=$(docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" \
    ps --format json 2>/dev/null | grep -o '"Health":"[^"]*"' | head -5 || echo "")

  healthy_count=$(echo "${coroot_health}" | grep -c '"healthy"' || echo "0")

  echo "  ${elapsed}s/${max_wait}s — ${healthy_count}/3 services healthy"

  # We need coroot, prometheus, clickhouse to be healthy (3 services)
  if [[ ${healthy_count} -ge 3 ]]; then
    staging_healthy=true
    echo "  All required services are healthy!"
    break
  fi
done

echo ""

# Run HTTP health probes against staging endpoints
echo "--- Running HTTP health probes ---"
staging_checks_passed=true

check_endpoint() {
  local name="$1"
  local url="$2"
  local code

  code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${url}" 2>/dev/null || echo "000")
  if [[ "${code}" == "200" ]]; then
    echo "  ${name}: HTTP ${code} — PASS"
    return 0
  else
    echo "  ${name}: HTTP ${code} — FAIL"
    staging_checks_passed=false
    return 1
  fi
}

check_endpoint "Coroot UI" "http://localhost:8081/" || true
check_endpoint "Prometheus" "http://localhost:9091/-/healthy" || true
check_endpoint "ClickHouse" "http://localhost:8124/ping" || true
echo ""

# Show container status
echo "--- Staging container status ---"
docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" ps
echo ""

# Determine result — HTTP probes are the authoritative check.
# Docker healthcheck for Coroot can take longer than the timeout on a fresh
# start (no cached data), so we accept HTTP 200 as proof of health.
if [[ "${staging_checks_passed}" == true ]]; then
  echo "=== STAGING VALIDATION PASSED ==="
  echo "All HTTP health probes passed."
  if [[ "${staging_healthy}" != true ]]; then
    echo "  Note: Docker healthcheck had not converged, but HTTP probes confirmed services are responding."
  fi

  # Tear down staging to free resources
  echo ""
  echo "--- Tearing down staging ---"
  docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" down -v
  echo "  Staging environment cleaned up"

  exit 0
else
  echo "=== STAGING VALIDATION FAILED ==="

  if [[ "${staging_healthy}" != true ]]; then
    echo "  - Docker health checks did not pass within ${HEALTH_TIMEOUT}s"
  fi
  if [[ "${staging_checks_passed}" != true ]]; then
    echo "  - HTTP endpoint checks failed"
  fi

  # Show logs for debugging
  echo ""
  echo "--- Service logs (last 50 lines each) ---"
  for service in coroot prometheus clickhouse; do
    echo ""
    echo ">>> ${service}:"
    docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" logs --tail 50 "${service}" 2>/dev/null || true
  done

  # Tear down staging
  echo ""
  echo "--- Tearing down failed staging ---"
  docker compose -p "${PROJECT_NAME}" -f "${COMPOSE_FILE}" down -v
  echo "  Staging environment cleaned up"

  exit 1
fi
