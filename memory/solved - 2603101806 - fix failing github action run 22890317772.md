---
tldr: Fix failing GitHub Action run
category: utility
---

# Solved: Fix failing GitHub Action run

https://github.com/atvirokodosprendimai/coroot-cicd/actions/runs/22890317772

## Root cause
Prometheus OOM on cax11 (4GB RAM) — unbounded TSDB growth consumed all memory,
causing cascading OOM kills across the entire stack (35 downtime incidents over 10 days).

## Resolution
- Upgraded VPS: cax11 (2vCPU/4GB) → cax21 (4vCPU/8GB) — +3.27 EUR/mo
- Added Prometheus retention limits: 4GB size, 30d time
- Added retry logic to hetzner-prices script
- Fixed ssh-keyscan killing coroot-update pipeline
- Added VPS diagnostics workflow with Hetzner API reboot fallback
