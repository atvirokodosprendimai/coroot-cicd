---
title: "fix: Make Hetzner Price Push resilient to transient VPS unavailability"
type: fix
status: active
date: 2026-03-15
---

# fix: Make Hetzner Price Push resilient to transient VPS unavailability

## Overview

The daily "Hetzner Price Push" workflow (`hetzner-prices.yml`) fails intermittently when `table.beerpub.dev` (Coroot on Hetzner cax21) is temporarily unreachable.
The SSL handshake times out, all 3 retries exhaust, and the workflow shows red — generating noise for a non-critical daily price sync.

This is the same class of failure that triggered the [Prometheus OOM incident on March 10](../memory/session%20-%202603102158%20-%20fix%20failing%20action%20and%20prometheus%20oom%20rca.md).
The VPS was upgraded and retention limits added, but transient unreachability can still happen (network blips, container restarts, resource pressure).

**Failing run:** https://github.com/atvirokodosprendimai/coroot-cicd/actions/runs/23105216116

## Problem Statement

| Aspect | Detail |
|--------|--------|
| **What fails** | SSL handshake timeout to `https://table.beerpub.dev` from GitHub Actions runner |
| **Where** | `scripts/push-hz-prices.py:175` → `coroot_request("POST", "/api/login", ...)` |
| **Current mitigation** | 3 retries with 5/15/30s delays (`push-hz-prices.py:49-66`) |
| **Failure rate** | ~20% (1/5 runs since workflow was created on March 10) |
| **Impact** | Red workflow badge, noisy notifications, wasted attention — but **zero business impact** since prices change rarely |
| **Root cause class** | VPS temporarily unreachable (resource pressure, network blip, container restart cycle) |

## Proposed Solution

Three-layer resilience approach, ordered by impact:

### Layer 1: Workflow-level soft failure (highest impact, simplest)

Make the workflow tolerate failures gracefully — this is a non-critical sync.

- Add `continue-on-error: true` to the pricing step
- Add a follow-up step that reports the outcome (success/skip/failure) to the job summary
- Stale pricing for a day (or a few days) has zero impact — Coroot uses it for cost dashboards, not billing

### Layer 2: Health pre-check with early exit

Before running the full script, probe the VPS with a fast curl:

```yaml
- name: Check VPS reachability
  id: health
  run: |
    if curl -sf --connect-timeout 10 --max-time 15 "$COROOT_URL/" >/dev/null 2>&1; then
      echo "reachable=true" >> "$GITHUB_OUTPUT"
    else
      echo "::warning::VPS unreachable — skipping price push"
      echo "reachable=false" >> "$GITHUB_OUTPUT"
    fi
```

Skip the pricing step entirely if the VPS is down — no wasted retry cycles, clean exit.

### Layer 3: Improved retry strategy in the Python script

Current: 3 retries, fixed 5/15/30s delays (total ~50s window).
Problem: SSL handshake can take 30s to timeout × 3 retries = 90s+ before first retry even starts.

Improvements:
- Reduce SSL connect timeout from 30s to 10s (fail faster)
- Increase retries from 3 to 5
- Use exponential backoff with jitter: 5s, 10s, 20s, 40s, 60s (total ~135s retry window)
- Separate connect timeout from read timeout

## Technical Approach

### Files to modify

| File | Change |
|------|--------|
| `.github/workflows/hetzner-prices.yml` | Add health pre-check step, `continue-on-error`, summary step |
| `scripts/push-hz-prices.py` | Reduce connect timeout, add jitter, increase retry budget |

### Workflow changes (`hetzner-prices.yml`)

```yaml
jobs:
  push-prices:
    name: Push Hetzner Prices to Coroot
    runs-on: ubuntu-latest
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Check VPS reachability
        id: health
        env:
          COROOT_URL: https://table.beerpub.dev
        run: |
          if curl -sf --connect-timeout 10 --max-time 15 "$COROOT_URL/" >/dev/null 2>&1; then
            echo "reachable=true" >> "$GITHUB_OUTPUT"
          else
            echo "::warning::VPS unreachable — skipping price push"
            echo "reachable=false" >> "$GITHUB_OUTPUT"
          fi

      - name: Derive and push pricing
        if: steps.health.outputs.reachable == 'true'
        continue-on-error: true
        id: push
        env:
          HETZNER_TOKEN: ${{ secrets.HETZNER_TOKEN }}
          COROOT_EMAIL: ${{ secrets.COROOT_EMAIL }}
          COROOT_PASSWORD: ${{ secrets.COROOT_PASSWORD }}
          COROOT_URL: https://table.beerpub.dev
          COROOT_PROJECT: ${{ vars.COROOT_PROJECT }}
        run: python3 scripts/push-hz-prices.py

      - name: Summary
        if: always()
        run: |
          if [[ "${{ steps.health.outputs.reachable }}" != "true" ]]; then
            echo "### ⏭️ Hetzner Price Push Skipped" >> $GITHUB_STEP_SUMMARY
            echo "VPS unreachable — will retry tomorrow." >> $GITHUB_STEP_SUMMARY
          elif [[ "${{ steps.push.outcome }}" == "success" ]]; then
            echo "### ✅ Hetzner Prices Updated" >> $GITHUB_STEP_SUMMARY
            echo "Custom cloud pricing updated in Coroot." >> $GITHUB_STEP_SUMMARY
          else
            echo "### ⚠️ Hetzner Price Push Failed" >> $GITHUB_STEP_SUMMARY
            echo "Pricing step failed after retries — stale prices are acceptable for 1-2 days." >> $GITHUB_STEP_SUMMARY
            echo "Check VPS health if this persists." >> $GITHUB_STEP_SUMMARY
          fi
```

### Python script changes (`push-hz-prices.py`)

1. **Reduce connect timeout:** Change `timeout=30` to separate connect/read timeouts
2. **Add jitter:** Randomise retry delays ±30% to avoid thundering herd
3. **Increase retry budget:** 5 retries with exponential backoff (5, 10, 20, 40, 60s)

```python
import random

MAX_RETRIES = 5
BASE_DELAY = 5  # seconds
MAX_DELAY = 60  # seconds
CONNECT_TIMEOUT = 10  # seconds (was 30)
READ_TIMEOUT = 30  # seconds

def _retry(fn, description: str):
    for attempt in range(MAX_RETRIES):
        try:
            return fn()
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            if isinstance(exc, urllib.error.HTTPError):
                raise
            if attempt == MAX_RETRIES - 1:
                raise
            delay = min(BASE_DELAY * (2 ** attempt), MAX_DELAY)
            jitter = delay * random.uniform(-0.3, 0.3)
            actual_delay = max(1, delay + jitter)
            print(f"  Retry {attempt + 1}/{MAX_RETRIES} for {description} "
                  f"in {actual_delay:.0f}s ({exc})")
            time.sleep(actual_delay)
```

## Edge Cases Considered

| Scenario | Behavior |
|----------|----------|
| VPS down for hours | Health check skips run, retries tomorrow — acceptable |
| VPS down for days | Consecutive skips, stale pricing — no business impact, should trigger VPS diagnostics |
| Hetzner API down, VPS fine | Health check passes, script fails at Hetzner API call — `continue-on-error` catches it |
| Wrong credentials | HTTP 401/403 — not retried (HTTPError is propagated immediately), shown in summary |
| Prices unchanged | Still pushed — idempotent, no harm |
| Partial completion | Hetzner prices fetched but Coroot push fails — `continue-on-error` + summary handles it |
| Network blip during push (not login) | Retry logic covers all `coroot_request` calls, not just login |

## What This Does NOT Do

- **No alerting for consecutive failures** — if the VPS is down for days, the user should notice via uptime-monitor.yml or Grafana, not from this workflow
- **No automatic VPS reboot** — that's what `vps-diagnostics.yml` is for, triggered manually
- **No caching/skipping unchanged prices** — over-engineering for a daily curl that takes 2 seconds

## Acceptance Criteria

- [ ] Health pre-check skips run cleanly when VPS is unreachable (green workflow)
- [ ] Successful runs still show "Hetzner Prices Updated" in summary
- [ ] Failed runs after health check passes show warning (not error) in summary
- [ ] Python retry uses exponential backoff with jitter
- [ ] Connect timeout reduced to 10s for faster failure detection
- [ ] Workflow stays green when VPS has a transient blip

## MVP

### .github/workflows/hetzner-prices.yml

Full workflow replacement with health check, continue-on-error, and summary step (see Technical Approach above).

### scripts/push-hz-prices.py

Updated retry logic with exponential backoff, jitter, and separate connect/read timeouts (see Technical Approach above).

## Sources

- **Failing run:** https://github.com/atvirokodosprendimai/coroot-cicd/actions/runs/23105216116
- **Prior incident:** [session - 2603102158 - fix failing action and prometheus oom rca](../../memory/session%20-%202603102158%20-%20fix%20failing%20action%20and%20prometheus%20oom%20rca.md)
- **Current retry logic:** `scripts/push-hz-prices.py:49-66`
- **Current workflow:** `.github/workflows/hetzner-prices.yml`
- **VPS diagnostics:** `.github/workflows/vps-diagnostics.yml` (manual trigger for deeper issues)
