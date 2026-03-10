---
tldr: Fixed failing GitHub Action, diagnosed Prometheus OOM as root cause, upgraded VPS, added retention limits
category: session
---

# Session: Fix failing action and Prometheus OOM RCA

## What happened

GitHub Action run #22890317772 failed due to SSL timeout in `push-hz-prices.py`.
Investigation revealed the SSL timeout was a symptom of a deeper problem:
Prometheus TSDB grew unbounded on a 4GB RAM VPS, causing cascading OOM kills across the entire Coroot stack.

## Root cause

Prometheus had no retention limits.
TSDB grew to 5.8GB, loaded fully into memory on restart (~2.1GiB in 40s).
On a cax11 (4GB RAM, no swap), this triggered OOM kills for all containers.
Docker `restart: always` caused immediate restarts, repeating the cycle.
35 downtime incidents over 10 days, uptime shrinking from hours to 15 minutes.

## Fixes applied

1. **VPS upgrade**: cax11 (2vCPU/4GB) → cax21 (4vCPU/8GB) — +3.27 EUR/mo
2. **Prometheus retention**: `--storage.tsdb.retention.size=4GB`, `--storage.tsdb.retention.time=30d`
3. **Retry logic**: Added to `push-hz-prices.py` for transient network errors
4. **ssh-keyscan fix**: Appended `|| true` to 6 instances in `coroot-update.yml`
5. **VPS diagnostics workflow**: Created `vps-diagnostics.yml` with Hetzner API reboot fallback
6. **Cleanup**: Removed one-off `apply-prometheus-limits.yml` after use

## PRs merged

#39–#45

## Decision: ClickHouse replacing Prometheus

Investigated whether ClickHouse could replace Prometheus.
Finding: **not possible** — Coroot requires Prometheus for metrics, ClickHouse handles traces/logs/profiles only.
Current setup with cax21 is stable (35% memory usage, 65% headroom).
User decided current setup is good enough.

## Final state

- VPS: cax21, server ID 121658153
- Endpoint: https://table.beerpub.dev — healthy
- Memory: ~2.7GiB / 7.5GB (35%)
- All workflows passing
