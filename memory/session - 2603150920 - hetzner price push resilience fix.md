---
tldr: Made Hetzner Price Push workflow resilient to transient VPS unavailability — health pre-check, continue-on-error, exponential backoff, retryable HTTP codes
category: session
---

# Session: Hetzner Price Push Resilience Fix

## Trigger

User flagged recurring failure: https://github.com/atvirokodosprendimai/coroot-cicd/actions/runs/23105216116
SSL handshake timeout to `table.beerpub.dev` — same class of failure as the March 10 Prometheus OOM incident.

## What was done

### Planning

- Created plan: `docs/plans/2026-03-15-001-fix-hetzner-price-push-resilience-plan.md`
- Ran repo research, learnings research, and SpecFlow analysis in parallel
- SpecFlow analysis caught a bug: HTTP 429/5xx responses were never retried

### Implementation (PR #53)

Branch: `task/hz-prices-resilience` (3 commits)

1. **`d06799a`** fix: make hetzner price push resilient to transient VPS unavailability
   - Added health pre-check (curl VPS before running script)
   - Added `continue-on-error: true` on pricing step
   - Added three-way summary step (skipped/success/failed)
   - Upgraded retry: 5 attempts, exponential backoff with ±30% jitter
   - Reduced Coroot socket timeout from 30s to 15s

2. **`601ced8`** fix: retry HTTP 429 and 5xx errors in push-hz-prices
   - Added `RETRYABLE_HTTP_CODES = {429, 500, 502, 503, 504}`
   - Coroot 502 during container restart now retried instead of permanent failure
   - `_is_retryable()` helper for clean separation of retry logic

3. **`5957f99`** fix: honest timeout naming and update plan per PR review
   - Renamed `CONNECT_TIMEOUT`/`READ_TIMEOUT` to `HETZNER_TIMEOUT`/`COROOT_TIMEOUT`
   - urllib's `timeout=` is a single per-socket-operation value, not separate connect/read
   - Updated plan to match actual implementation, removed stale line numbers

### Verification

- Triggered workflow manually twice on the branch — both passed (9s each)
- Python syntax verified
- YAML structure verified

### PR Review

Addressed 4 review comments about misleading timeout naming and plan/code drift.

## Files changed

- `.github/workflows/hetzner-prices.yml` — health pre-check, continue-on-error, summary
- `scripts/push-hz-prices.py` — retry logic, timeout naming, retryable HTTP codes
- `docs/plans/2026-03-15-001-fix-hetzner-price-push-resilience-plan.md` — implementation plan

## Key decisions

- **No VPS reboot from this workflow** — keep security boundary clean, reboot is for `vps-diagnostics.yml`
- **No consecutive failure alerting** — uptime-monitor.yml already covers VPS availability
- **No price change detection** — idempotent push is cheap, not worth the complexity
- **15s Coroot timeout** — balance between failing fast and giving the VPS time to respond
