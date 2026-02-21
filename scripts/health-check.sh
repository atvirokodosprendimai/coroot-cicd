#!/usr/bin/env bash
# health-check.sh — Verify that a Coroot stack is healthy by probing
# HTTP endpoints for Coroot, Prometheus, and ClickHouse.
#
# Usage:
#   # Check production (default)
#   ssh root@VPS 'bash -s' < scripts/health-check.sh
#
#   # Check staging
#   ssh root@VPS 'bash -s -- --staging' < scripts/health-check.sh
#
#   # Check with custom timeout
#   ssh root@VPS 'bash -s -- --timeout 180' < scripts/health-check.sh
#
#   # Check external URL
#   ssh root@VPS 'bash -s -- --external https://table.beerpub.dev' < scripts/health-check.sh
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed

set -euo pipefail

# Defaults (production)
COROOT_URL="http://localhost:8080"
PROMETHEUS_URL="http://localhost:9090"
CLICKHOUSE_URL="http://localhost:8123"
EXTERNAL_URL=""
TIMEOUT=120
CHECK_INTERVAL=5
STACK_NAME="production"

DRY_RUN=false

# Parse arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staging)
      COROOT_URL="http://localhost:8081"
      PROMETHEUS_URL="http://localhost:9091"
      CLICKHOUSE_URL="http://localhost:8124"
      STACK_NAME="staging"
      shift
      ;;
    --timeout)
      TIMEOUT="$2"
      shift 2
      ;;
    --external)
      EXTERNAL_URL="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "=== Health Check: ${STACK_NAME} stack ==="
if [[ "${DRY_RUN}" == true ]]; then
  echo "MODE: DRY RUN (single probe per endpoint, no retries)"
fi
echo "Timeout: ${TIMEOUT}s"
echo ""

if [[ "${DRY_RUN}" == true ]]; then
  echo "--- DRY RUN: Probing endpoints once (no retries) ---"
  echo ""
  for name_url in "Coroot UI|${COROOT_URL}/" "Prometheus|${PROMETHEUS_URL}/-/healthy" "ClickHouse|${CLICKHOUSE_URL}/ping"; do
    name="${name_url%%|*}"
    url="${name_url#*|}"
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${url}" 2>/dev/null || echo "000")
    echo "  ${name} (${url}): HTTP ${code}"
  done
  if [[ -n "${EXTERNAL_URL}" ]]; then
    code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${EXTERNAL_URL}/" 2>/dev/null || echo "000")
    echo "  External (${EXTERNAL_URL}/): HTTP ${code}"
  fi
  echo ""

  echo "--- DRY RUN: Docker compose status ---"
  if [[ "${STACK_NAME}" == "staging" ]]; then
    docker compose -p coroot-staging ps 2>/dev/null || echo "  Staging not running"
  else
    docker compose -p coroot -f /opt/coroot/docker-compose.yml ps 2>/dev/null || echo "  Production not running"
  fi
  echo ""
  echo "=== DRY RUN COMPLETE ==="
  exit 0
fi

check_passed=true
checks_run=0
checks_failed=0

# Function to probe an HTTP endpoint with retries
probe_endpoint() {
  local name="$1"
  local url="$2"
  local expected_code="${3:-200}"
  local max_retries=$((TIMEOUT / CHECK_INTERVAL))
  local attempt=0

  echo "--- Checking: ${name} ---"
  echo "  URL: ${url}"
  echo "  Expected: HTTP ${expected_code}"

  while [[ ${attempt} -lt ${max_retries} ]]; do
    attempt=$((attempt + 1))
    http_code=$(curl -s -o /dev/null -w "%{http_code}" --connect-timeout 5 --max-time 10 "${url}" 2>/dev/null || echo "000")

    if [[ "${http_code}" == "${expected_code}" ]]; then
      echo "  Result: HTTP ${http_code} (attempt ${attempt}/${max_retries})"
      echo "  Status: PASS"
      echo ""
      checks_run=$((checks_run + 1))
      return 0
    fi

    if [[ ${attempt} -lt ${max_retries} ]]; then
      echo "  Attempt ${attempt}/${max_retries}: HTTP ${http_code}, retrying in ${CHECK_INTERVAL}s..."
      sleep "${CHECK_INTERVAL}"
    fi
  done

  echo "  Result: HTTP ${http_code} (after ${attempt} attempts)"
  echo "  Status: FAIL"
  echo ""
  checks_run=$((checks_run + 1))
  checks_failed=$((checks_failed + 1))
  check_passed=false
  return 1
}

# Run internal health checks
probe_endpoint "Coroot UI" "${COROOT_URL}/" || true
probe_endpoint "Prometheus" "${PROMETHEUS_URL}/-/healthy" || true
probe_endpoint "ClickHouse" "${CLICKHOUSE_URL}/ping" || true

# Run external health check if URL provided
if [[ -n "${EXTERNAL_URL}" ]]; then
  probe_endpoint "External (Coroot via Caddy)" "${EXTERNAL_URL}/" || true
fi

# Docker health status check (if on the host)
echo "--- Docker Compose Health Status ---"
if command -v docker &> /dev/null; then
  if [[ "${STACK_NAME}" == "staging" ]]; then
    docker compose -p coroot-staging ps 2>/dev/null || echo "  Could not query staging compose status"
  else
    docker compose -p coroot -f /opt/coroot/docker-compose.yml ps 2>/dev/null || echo "  Could not query compose status"
  fi
fi
echo ""

# Summary
echo "=== Health Check Summary ==="
echo "Stack:   ${STACK_NAME}"
echo "Checks:  ${checks_run} run, $((checks_run - checks_failed)) passed, ${checks_failed} failed"

if [[ "${check_passed}" == true ]]; then
  echo "Result:  ALL CHECKS PASSED"
  exit 0
else
  echo "Result:  CHECKS FAILED"
  exit 1
fi
