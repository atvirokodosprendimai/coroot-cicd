# Next — 2602281014

## Actionable Items

1 - Branch work ready to commit (task/hz-prices-to-coroot)
  - 1.1 - Commit + push: scripts/push-hz-prices.py, hetzner-prices.yml,
          copy-secrets-coroot.yml, DEPLOY.md, TASKS.md
  - 1.2 - Merge/PR task/hz-prices-to-coroot → main

## Notes

- All TASKS.md items are [x] — no remaining todos
- New untracked files: scripts/push-hz-prices.py, .github/workflows/hetzner-prices.yml,
  .github/workflows/copy-secrets-coroot.yml, memory/
- Modified: DEPLOY.md (new Hetzner Price Metrics section), TASKS.md (task checked off)
- Implementation derives per-CPU/per-memory hourly rates from Hetzner API,
  posts to Coroot custom cloud pricing endpoint — runs daily via GHA cron
