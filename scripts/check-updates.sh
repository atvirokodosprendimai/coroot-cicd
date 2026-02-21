#!/usr/bin/env bash
# check-updates.sh — Compare running image digests on the VPS against
# the latest remote digests. Outputs a machine-readable status and sets
# GitHub Actions outputs when running in CI.
#
# Usage:
#   ssh root@VPS 'bash -s' < scripts/check-updates.sh
#
# Exit codes:
#   0 — updates available (at least one image differs)
#   1 — error
#   2 — no updates available (all images match)

set -euo pipefail

DRY_RUN=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

COMPOSE_DIR="/opt/coroot"
COMPOSE_PROJECT="coroot"

# Images to check — only the Coroot stack images that use :latest
IMAGES=(
  "ghcr.io/coroot/coroot"
  "ghcr.io/coroot/coroot-node-agent"
  "ghcr.io/coroot/coroot-cluster-agent"
)

# Map images to their compose service names
declare -A IMAGE_SERVICE_MAP=(
  ["ghcr.io/coroot/coroot"]="coroot"
  ["ghcr.io/coroot/coroot-node-agent"]="node-agent"
  ["ghcr.io/coroot/coroot-cluster-agent"]="cluster-agent"
)

updates_found=false
update_summary=""
images_to_update=""

if [[ "${DRY_RUN}" == true ]]; then
  echo "=== DRY RUN: Checking for Coroot stack image updates ==="
  echo "(No changes will be made)"
else
  echo "=== Checking for Coroot stack image updates ==="
fi
echo ""

for image in "${IMAGES[@]}"; do
  service="${IMAGE_SERVICE_MAP[$image]}"
  echo "--- Checking: ${image} (service: ${service}) ---"

  # Get the digest of the currently running image
  running_digest=""
  container_id=$(docker compose -p "${COMPOSE_PROJECT}" -f "${COMPOSE_DIR}/docker-compose.yml" \
    ps -q "${service}" 2>/dev/null || true)

  if [[ -n "${container_id}" ]]; then
    # Get the RepoDigests of the image the container is running
    running_image=$(docker inspect --format='{{.Image}}' "${container_id}" 2>/dev/null || true)
    if [[ -n "${running_image}" ]]; then
      running_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${running_image}" 2>/dev/null || true)
      # Extract just the sha256 part
      running_digest=$(echo "${running_digest}" | grep -oP 'sha256:[a-f0-9]+' || true)
    fi
  fi

  if [[ -z "${running_digest}" ]]; then
    echo "  WARNING: Could not determine running digest for ${service}."
    echo "  Container may not be running. Will attempt update."
    updates_found=true
    images_to_update="${images_to_update}${image},"
    update_summary="${update_summary}  - ${image}: running=UNKNOWN, remote=PENDING_CHECK\n"
    echo ""
    continue
  fi

  echo "  Running digest: ${running_digest}"

  # Get the latest remote digest by pulling the manifest
  # Use docker manifest inspect (requires experimental CLI features)
  remote_digest=""
  remote_digest=$(docker manifest inspect "${image}:latest" 2>/dev/null \
    | grep -oP '"digest":\s*"(sha256:[a-f0-9]+)"' \
    | head -1 \
    | grep -oP 'sha256:[a-f0-9]+' || true)

  # Fallback: pull the image and compare
  if [[ -z "${remote_digest}" ]]; then
    echo "  Manifest inspect failed, pulling image to compare..."
    docker pull "${image}:latest" > /dev/null 2>&1
    remote_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${image}:latest" 2>/dev/null || true)
    remote_digest=$(echo "${remote_digest}" | grep -oP 'sha256:[a-f0-9]+' || true)
  fi

  if [[ -z "${remote_digest}" ]]; then
    echo "  ERROR: Could not determine remote digest for ${image}."
    echo ""
    continue
  fi

  echo "  Remote digest:  ${remote_digest}"

  if [[ "${running_digest}" != "${remote_digest}" ]]; then
    echo "  STATUS: UPDATE AVAILABLE"
    updates_found=true
    images_to_update="${images_to_update}${image},"
    update_summary="${update_summary}  - ${image}: ${running_digest:0:19}... -> ${remote_digest:0:19}...\n"
  else
    echo "  STATUS: Up to date"
  fi
  echo ""
done

echo "=== Summary ==="
if [[ "${updates_found}" == true ]]; then
  echo "Updates available for:"
  echo -e "${update_summary}"

  # Write outputs for GitHub Actions
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "updates_available=true" >> "${GITHUB_OUTPUT}"
    echo "images_to_update=${images_to_update%,}" >> "${GITHUB_OUTPUT}"
    {
      echo "update_summary<<EOF"
      echo -e "${update_summary}"
      echo "EOF"
    } >> "${GITHUB_OUTPUT}"
  fi

  exit 0
else
  echo "All Coroot stack images are up to date. No deployment needed."

  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "updates_available=false" >> "${GITHUB_OUTPUT}"
  fi

  exit 2
fi
