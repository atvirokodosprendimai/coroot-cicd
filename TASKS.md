need to launch coroot server on hz vps, using domain: table.beerpub.dev

- [x] Configure remote backups — Hetzner Storage Box sync via `scripts/sync-remote-backup.sh`, integrated into CI/CD pipeline
- [x] Add dry-run mode to all pipeline scripts (`--dry-run` flag + `dry_run` workflow input)
- [x] Add external uptime monitoring (`.github/workflows/uptime-monitor.yml` — GHA cron every 5 min, auto-creates/closes issues)
- [x] Document Docker `expose:` vs `ports:` implications in DEPLOY.md
- [x] Order Hetzner Storage Box and configure SSH key + `/etc/coroot-backup.conf` on VPS (see DEPLOY.md for setup instructions)
- [x] Split repos — RFC-EDPROOF.md and formal/edproof.spthy moved to https://github.com/atvirokodosprendimai/edproof
- [x] Fetch prices from Hetzner console and push them to Coroot
