# Coroot CI/CD Pipeline Postmortem (incident #001)

**Date**: 2026-02-21

**Authors**: oldroot

**Status**: Complete, all action items resolved

**Summary**: Coroot auto-update CI/CD pipeline failed on first three test runs due to incorrect assumptions about Docker networking, health check timing, and bash output parsing. Production Coroot stack experienced two unnecessary rollbacks that each caused ~2.5 minutes of observability data gaps.

**Impact**: Coroot observability platform at `table.beerpub.dev` was unavailable or degraded for approximately 5 minutes total across two rollback cycles. Backup/restore cycles created ~5 minutes of gaps in Prometheus metrics and ClickHouse logs/traces. No external user-facing services were affected (Coroot is an internal observability tool). No data loss occurred — backups restored successfully each time.

**Root Causes**: Three distinct issues combined to cause repeated pipeline failures:

1. **Health check timing mismatch**: Coroot's Docker healthcheck takes >120s to report "healthy" on a fresh or recently-restarted instance (due to cache warming and initial Prometheus/ClickHouse data population). The pipeline assumed 120s was sufficient.

2. **Docker networking misconception**: The production `docker-compose.yml` uses `expose:` (container-internal only) rather than `ports:` (host-bound). Health probe scripts attempted `curl http://localhost:<port>` from the host, which returned connection refused. The external Caddy reverse proxy at `https://table.beerpub.dev` was the only working path to reach Coroot from outside the Docker network.

3. **Bash arithmetic parsing errors**: `grep -c "(healthy)"` returns its count on stdout, but when the command fails (0 matches), bash's `|| echo "0"` appended a second line. The resulting multi-line string caused `[[ ${health} -gt 0 ]]` to fail with `syntax error in expression`.

**Trigger**: First manual test run of the newly created CI/CD pipeline via `workflow_dispatch` with `force_deploy=true`.

**Resolution**: Three iterative fixes deployed across runs 2-4:
- Run 2: Fixed bash parsing, made HTTP probes authoritative over Docker healthcheck status, fixed rollback trigger condition.
- Run 3: Switched from host `curl` to `docker exec wget --spider` for internal probes.
- Run 4: Replaced internal probes entirely with external Caddy endpoint (`https://table.beerpub.dev`) as the sole authoritative health check. Pipeline passed all 6 jobs successfully.

**Detection**: Pipeline failures were observed directly during manual testing via `gh run watch`. No external monitoring detected the issue because the rollback scripts successfully restored service each time.

## Action Items

| Action Item | Type | Owner | Status |
|---|---|---|---|
| Validate health probe methodology against actual Docker compose networking before deploying new pipelines | prevent | oldroot | **DONE** |
| Use external Caddy endpoint as authoritative health check instead of internal probes | prevent | oldroot | **DONE** |
| Fix bash `grep -c` output sanitization in all scripts | prevent | oldroot | **DONE** |
| Rollback job should only trigger on `needs.deploy.result == 'failure'`, not on upstream staging failure | prevent | oldroot | **DONE** |
| Accept HTTP 200 as proof of health even when Docker healthcheck hasn't converged (Coroot startup >120s) | mitigate | oldroot | **DONE** |
| Add dry-run / smoke-test mode to pipeline that validates scripts without touching production | prevent | oldroot | **DONE** |
| Configure remote/off-site backups so rollback data survives VPS failure (Hetzner Storage Box) | prevent | oldroot | **DONE** |
| Add external uptime monitoring for `table.beerpub.dev` independent of the pipeline (GHA cron) | detect | oldroot | **DONE** |
| Document the Docker `expose:` vs `ports:` distinction and its implications for health checking in DEPLOY.md | process | oldroot | **DONE** |

## Lessons Learned

**What went well**

- Backup script worked correctly on every run — all 8 volumes backed up and restored without data loss
- Staging validation caught incompatible images before production deployment on runs 1-2, preventing unnecessary production churn
- Rollback mechanism worked as designed: volumes restored, configs restored, services restarted successfully
- The iterative fix-and-retest cycle was fast (~10 minutes per iteration) due to `skip_backup` option
- GitHub Actions workflow structure (sequential jobs with conditional rollback) handled failure propagation correctly after the trigger condition was fixed

**What went wrong**

- Scripts were written with assumptions about Docker networking that weren't validated against the actual production compose file — specifically, assuming services bind to host `localhost` when they only use `expose:`
- Coroot's Docker healthcheck timing was not profiled before setting the 120s timeout — the actual time to "healthy" on a cold start exceeds this consistently
- Bash scripts used `grep -c` without sanitizing output, a known footgun in shell scripting that was overlooked
- The rollback job's `if: failure()` condition in GitHub Actions evaluates to `true` when *any* upstream job fails, not just the immediate dependency — this caused rollback to run unnecessarily when staging (not production) failed
- Two unnecessary rollback cycles touched production data (stopped services, restored volumes) even though Coroot was actually running fine — the pipeline's health check was wrong, not the service

**Where we got lucky**

- Coroot's data volumes are relatively small (~330MB compressed) so backup/restore cycles completed in under 3 minutes, minimizing downtime
- No other services depend on the Coroot stack, so the repeated restarts had no cascading impact
- The external Caddy endpoint returned HTTP 200 consistently, providing a reliable fallback health check mechanism that was already in place
- All three test runs happened during a low-traffic period, so the brief observability gaps didn't coincide with any incidents in monitored services

## Timeline

2026-02-21 *(all times UTC)*

- 08:00 Pipeline files created and pushed to `atvirokodosprendimai/coroot-cicd`
- 08:01 GitHub Actions secrets (`VPS_SSH_KEY`, `VPS_HOST`) configured
- 08:02 **RUN 1 BEGINS** — Manual trigger with `force_deploy=true`
- 08:02 Check for Image Updates job completes (15s) — no new images but force_deploy bypasses
- 08:03 Backup Volumes job starts — stops services, backs up all 8 volumes (~330MB total)
- 08:05 Backup complete, services restarted, staging deployment begins
- 08:05 Staging: images pulled, containers created, ClickHouse healthy in 5s, Prometheus healthy in 6s
- 08:05 Staging: Coroot container starts but Docker healthcheck remains "unhealthy" for >120s
- 08:07 Staging: All three HTTP probes (Coroot :8081, Prometheus :9091, ClickHouse :8124) return HTTP 200
- 08:07 **RUN 1 STAGING FAILS** — Script requires both Docker health AND HTTP probes to pass; Docker health shows 2/3
- 08:08 Rollback job triggers (incorrectly — staging failed, production was never touched)
- 08:08 Rollback: stops production services, restores all volumes from backup, restarts
- 08:08 Rollback: `grep -c "(healthy)"` returns multi-line output, causes `bash: [[: 0\n0: syntax error`
- 08:10 **RUN 1 ENDS** — Failed. Three bugs identified: health check logic, rollback trigger condition, bash parsing
- 08:10 Fix commit: accept HTTP probes as authoritative, fix `grep -c` sanitization, fix rollback condition to `needs.deploy.result == 'failure'`
- 08:11 Fix pushed to `main`
- 08:13 **RUN 2 BEGINS** — Manual trigger with `force_deploy=true`
- 08:16 Backup completes (2m46s)
- 08:18 Staging validation passes (2m30s) — HTTP probes accepted as authoritative
- 08:19 Production deploy starts, images pulled, compose up completes
- 08:19 Docker healthcheck: 2/3 healthy (Coroot never converges within 120s)
- 08:21 Production HTTP fallback probes: `curl http://localhost:8080/` returns `HTTP 000000` (connection refused)
- 08:21 Production external probe: `curl https://table.beerpub.dev/` returns `HTTP 200`
- 08:21 **RUN 2 DEPLOY FAILS** — Internal localhost probes fail because services use `expose:` not `ports:`
- 08:22 Rollback triggers (correctly this time — deploy job failed)
- 08:24 Rollback completes, same internal probe issue but rollback script also exits 1
- 08:25 **RUN 2 ENDS** — Failed. Root cause identified: Docker `expose:` vs `ports:` networking
- 08:26 Fix commit: switch internal probes to `docker exec wget --spider`
- 08:27 Fix pushed to `main`
- 08:28 **RUN 3 BEGINS** — Manual trigger with `force_deploy=true`, `skip_backup=true`
- 08:31 Backup skipped, staging passes (2m26s)
- 08:33 Production deploy: `docker exec coroot-coroot-1 wget --spider http://localhost:8080/` fails
- 08:33 Production external probe: `https://table.beerpub.dev/` returns `HTTP 200` (again)
- 08:33 **RUN 3 DEPLOY FAILS** — Coroot container's `wget --spider` does not behave as expected
- 08:33 Rollback triggers, same `docker exec` probe issue in rollback script
- 08:36 **RUN 3 ENDS** — Failed. Decision: use external Caddy endpoint as sole authoritative check
- 08:37 Fix commit: replace all internal probes with external `https://table.beerpub.dev` check with 3 retries
- 08:37 Fix pushed to `main`
- 08:38 **RUN 4 BEGINS** — Manual trigger with `force_deploy=true`, `skip_backup=true`
- 08:39 Check for updates (15s) — pass
- 08:41 Backup skipped — pass
- 08:44 Staging validation (2m26s) — pass
- 08:46 Production deploy: compose up, Docker healthcheck 2/3 within 120s
- 08:46 External probe: `https://table.beerpub.dev/` returns HTTP 200 on first attempt
- 08:46 **RUN 4 DEPLOY PASSES**
- 08:46 Rollback skipped (correctly — deploy succeeded)
- 08:47 Post-pipeline cleanup: staging torn down, dangling images pruned
- 08:47 **RUN 4 ENDS** — All 6 jobs passed. Pipeline fully operational.

## Supporting Information

- Repository: https://github.com/atvirokodosprendimai/coroot-cicd
- Run 1 (failed): https://github.com/atvirokodosprendimai/coroot-cicd/actions/runs/22253254730
- Run 2 (failed): https://github.com/atvirokodosprendimai/coroot-cicd/actions/runs/22253407780
- Run 3 (failed): https://github.com/atvirokodosprendimai/coroot-cicd/actions/runs/22253562508
- Run 4 (passed): https://github.com/atvirokodosprendimai/coroot-cicd/actions/runs/22253751226
- Production endpoint: https://table.beerpub.dev
- VPS: 91.99.74.36 (Hetzner, `/opt/coroot/`)
- Backup location: `/opt/coroot/backups/` on VPS

### 5 Whys Analysis

1. **Why did the pipeline fail?** Health probes reported services as unhealthy.
2. **Why did health probes fail?** They attempted to connect to `localhost:<port>` on the host, but services were not bound to the host network.
3. **Why weren't services bound to the host?** The `docker-compose.yml` uses `expose:` (container-internal) rather than `ports:` (host-bound) for security — only Caddy exposes ports 80/443.
4. **Why wasn't this caught during development?** The scripts were written based on the compose file documentation template (GUIDE.md) without testing against the actual running production compose configuration.
5. **Why wasn't there a test environment for the scripts?** The pipeline was newly created and this was the first test run; no dry-run mode existed to validate probe logic without touching production.
