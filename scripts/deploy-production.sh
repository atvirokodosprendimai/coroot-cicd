#!/usr/bin/env bash
# deploy-production.sh — Pull latest Coroot stack images and redeploy
# production with health checks. If health checks fail, triggers rollback.
#
# Expects backup-volumes.sh to have been run first.
#
# Usage:
#   ssh root@VPS 'bash -s' < scripts/deploy-production.sh
#
# Exit codes:
#   0 — deployment successful, all health checks passed
#   1 — deployment failed (rollback should be triggered by caller)

set -euo pipefail

COMPOSE_DIR="/opt/coroot"
COMPOSE_FILE="${COMPOSE_DIR}/docker-compose.yml"
COMPOSE_PROJECT="coroot"
HEALTH_TIMEOUT=120
HEALTH_INTERVAL=5
EXTERNAL_URL="https://table.beerpub.dev"

echo "=== Production Deployment ==="
echo "Compose dir:  ${COMPOSE_DIR}"
echo "External URL: ${EXTERNAL_URL}"
echo ""

# Save current image IDs before update (for potential rollback reference)
echo "--- Recording pre-update state ---"
pre_update_file="/tmp/coroot-pre-update-images.txt"
for service in coroot node-agent cluster-agent; do
  container_id=$(docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" \
    ps -q "${service}" 2>/dev/null || true)
  if [[ -n "${container_id}" ]]; then
    image=$(docker inspect --format='{{.Config.Image}}' "${container_id}" 2>/dev/null || echo "unknown")
    digest=$(docker inspect --format='{{.Image}}' "${container_id}" 2>/dev/null || echo "unknown")
    echo "${service}|${image}|${digest}" >> "${pre_update_file}"
    echo "  ${service}: ${image} (${digest:0:19}...)"
  fi
done
echo ""

# Pull latest images
echo "--- Pulling latest images ---"
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" pull
echo "  All images pulled"
echo ""

# Deploy with recreation of changed containers
echo "--- Deploying updated stack ---"
docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" up -d --remove-orphans
echo "  Compose up completed"
echo ""

# Wait for Docker health checks
echo "--- Waiting for services to become healthy ---"
elapsed=0
all_healthy=false

while [[ ${elapsed} -lt ${HEALTH_TIMEOUT} ]]; do
  sleep "${HEALTH_INTERVAL}"
  elapsed=$((elapsed + HEALTH_INTERVAL))

  # Count healthy services (coroot, prometheus, clickhouse have healthchecks)
  healthy_count=0
  for service in coroot prometheus clickhouse; do
    health=$(docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" \
      ps "${service}" 2>/dev/null | grep -c "(healthy)" || true)
    health=$(echo "${health}" | tr -d '[:space:]')
    if [[ -n "${health}" && "${health}" -gt 0 ]] 2>/dev/null; then
      healthy_count=$((healthy_count + 1))
    fi
  done

  echo "  ${elapsed}s/${HEALTH_TIMEOUT}s — ${healthy_count}/3 services healthy"

  if [[ ${healthy_count} -ge 3 ]]; then
    all_healthy=true
    echo "  All services report healthy!"
    break
  fi
done

echo ""

if [[ "${all_healthy}" != true ]]; then
  echo "  Docker healthchecks did not fully converge within ${HEALTH_TIMEOUT}s."
  echo "  Falling back to HTTP endpoint probes..."
fi

# HTTP endpoint probes
echo "--- Running HTTP health probes ---"
probes_passed=true

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
    probes_passed=false
    return 1
  fi
}

check_endpoint "Coroot (internal)" "http://localhost:8080/" || true
check_endpoint "Prometheus" "http://localhost:9090/-/healthy" || true
check_endpoint "ClickHouse" "http://localhost:8123/ping" || true

# External check via Caddy
echo ""
echo "--- External endpoint check ---"
check_endpoint "Coroot (external via Caddy)" "${EXTERNAL_URL}/" || true
echo ""

# Show post-update image info
echo "--- Post-update image versions ---"
for service in coroot node-agent cluster-agent; do
  container_id=$(docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" \
    ps -q "${service}" 2>/dev/null || true)
  if [[ -n "${container_id}" ]]; then
    image=$(docker inspect --format='{{.Config.Image}}' "${container_id}" 2>/dev/null || echo "unknown")
    digest=$(docker inspect --format='{{.Image}}' "${container_id}" 2>/dev/null || echo "unknown")
    echo "  ${service}: ${image} (${digest:0:19}...)"
  fi
done
echo ""

# Final result
if [[ "${probes_passed}" == true ]]; then
  echo "=== PRODUCTION DEPLOYMENT SUCCESSFUL ==="
  echo "All HTTP health probes passed. Stack is running with updated images."
  if [[ "${all_healthy}" != true ]]; then
    echo "  Note: Docker healthcheck had not converged, but HTTP probes confirmed services are responding."
  fi

  # Clean up pre-update state file
  rm -f "${pre_update_file}"

  exit 0
else
  echo "=== PRODUCTION DEPLOYMENT FAILED ==="
  echo "HTTP endpoint checks failed."
  echo ""
  echo "--- Current container status ---"
  docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" ps
  echo ""
  echo "--- Recent logs ---"
  for service in coroot prometheus clickhouse; do
    echo ""
    echo ">>> ${service}:"
    docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_FILE}" logs --tail 30 "${service}" 2>/dev/null || true
  done
  exit 1
fi
