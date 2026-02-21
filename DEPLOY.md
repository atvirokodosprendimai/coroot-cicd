# Deploying Docker Images to the Hetzner VPS

## Server Details

- **Host**: 91.99.74.36
- **SSH**: `ssh -i ~/.ssh/coroot-table root@91.99.74.36`
- **Domain**: https://table.beerpub.dev
- **Stack location**: `/opt/coroot/`

## Adding a New Service

1. SSH into the server:

```bash
ssh -i ~/.ssh/coroot-table root@91.99.74.36
```

2. Edit the compose file:

```bash
nano /opt/coroot/docker-compose.yml
```

3. Add your service under the `services:` section. Example:

```yaml
  my-app:
    image: ghcr.io/your-org/your-app:latest
    restart: always
    pull_policy: always
    expose:
      - "3000"
    environment:
      - DATABASE_URL=postgres://...
    depends_on:
      - coroot
```

4. If the service needs to be publicly accessible, add a route in the Caddyfile:

```bash
nano /opt/coroot/Caddyfile
```

Example Caddyfile entry:

```
my-app.beerpub.dev {
    reverse_proxy my-app:3000
}
```

5. Deploy:

```bash
cd /opt/coroot
docker compose up -d
```

## Updating an Existing Service

Pull the latest image and recreate the container:

```bash
cd /opt/coroot
docker compose pull <service-name>
docker compose up -d <service-name>
```

## Viewing Logs

```bash
# All services
docker compose -f /opt/coroot/docker-compose.yml logs -f

# Specific service
docker compose -f /opt/coroot/docker-compose.yml logs -f <service-name>

# Last 100 lines
docker compose -f /opt/coroot/docker-compose.yml logs --tail 100 <service-name>
```

## Restarting Services

```bash
cd /opt/coroot

# Restart a single service
docker compose restart <service-name>

# Restart everything
docker compose down && docker compose up -d
```

## Current Stack

| Service         | Image                                 | Purpose                        |
|-----------------|---------------------------------------|--------------------------------|
| coroot          | ghcr.io/coroot/coroot                 | Observability platform         |
| prometheus      | prom/prometheus:v2.53.5               | Metrics storage                |
| clickhouse      | clickhouse/clickhouse-server:24.3     | Logs/traces/profiles storage   |
| node-agent      | ghcr.io/coroot/coroot-node-agent      | eBPF host metrics collector    |
| cluster-agent   | ghcr.io/coroot/coroot-cluster-agent   | Metrics scraper                |
| caddy           | caddy:2                               | Reverse proxy with auto TLS    |

## CI/CD Auto-Update Pipeline

The Coroot stack is kept up to date automatically via a GitHub Actions workflow.

### How It Works

```
Schedule (Monday 04:00 UTC) or Manual Trigger
  |
  1. Check for new image digests (coroot, node-agent, cluster-agent)
  |  -> Exit early if all images are current
  |
  2. Back up ALL Docker volumes to /opt/coroot/backups/<timestamp>/
  |  -> Saves image manifest, docker-compose.yml, Caddyfile
  |  -> Retains last 3 backups
  |
  3. Deploy to staging stack (/opt/coroot-staging/)
  |  -> Separate volumes, internal ports only
  |  -> Health check: Coroot, Prometheus, ClickHouse
  |  -> Abort if staging fails (production untouched)
  |
  4. Deploy to production
  |  -> docker compose pull && up -d
  |  -> Wait for Docker health checks (120s timeout)
  |  -> HTTP probes: internal + external (https://table.beerpub.dev)
  |
  5. On failure: automatic rollback
  |  -> Stop services, restore volumes from backup
  |  -> Restart with previous images, verify health
  |
  6. Cleanup: tear down staging, prune dangling images
```

### Required GitHub Secrets

| Secret | Value |
|--------|-------|
| `VPS_SSH_KEY` | Private key contents (`~/.ssh/coroot-table`) |
| `VPS_HOST` | `91.99.74.36` |

### Manual Trigger Options

The workflow can be triggered manually from GitHub Actions with options:

- **Force deploy** — deploy even if no image updates are detected
- **Skip staging** — bypass staging validation (use with caution)
- **Skip backup** — bypass volume backup (use with caution)

### Scripts

| Script | Purpose |
|--------|---------|
| `scripts/check-updates.sh` | Compare running vs remote image digests |
| `scripts/backup-volumes.sh` | Snapshot all Docker volumes |
| `scripts/deploy-staging.sh` | Deploy staging stack & validate |
| `scripts/deploy-production.sh` | Pull, deploy, health check production |
| `scripts/health-check.sh` | Reusable HTTP health probe tool |
| `scripts/rollback.sh` | Restore volumes from backup |

### Running Scripts Manually

```bash
# Check for updates
ssh -i ~/.ssh/coroot-table root@91.99.74.36 'bash -s' < scripts/check-updates.sh

# Back up volumes
ssh -i ~/.ssh/coroot-table root@91.99.74.36 'bash -s' < scripts/backup-volumes.sh

# Health check production
ssh -i ~/.ssh/coroot-table root@91.99.74.36 'bash -s' < scripts/health-check.sh

# Health check staging
ssh -i ~/.ssh/coroot-table root@91.99.74.36 'bash -s -- --staging' < scripts/health-check.sh

# Manual rollback to latest backup
ssh -i ~/.ssh/coroot-table root@91.99.74.36 'bash -s' < scripts/rollback.sh

# Manual rollback to specific backup
ssh -i ~/.ssh/coroot-table root@91.99.74.36 'bash -s -- /opt/coroot/backups/20260220-040000' < scripts/rollback.sh
```

### Changing the Schedule

Edit `.github/workflows/coroot-update.yml` and change the cron expression:

```yaml
on:
  schedule:
    - cron: "0 4 * * 1"  # Every Monday at 04:00 UTC
```

### Backup Location

Backups are stored on the VPS at `/opt/coroot/backups/<timestamp>/`:

```
/opt/coroot/backups/20260221-040000/
├── image-manifest.txt              # Image digests for rollback
├── docker-compose.yml              # Config snapshot
├── Caddyfile                       # Config snapshot
├── coroot_coroot_data.tar.gz       # Coroot app data
├── coroot_prometheus_data.tar.gz   # Prometheus TSDB
├── coroot_clickhouse_data.tar.gz   # ClickHouse data
├── coroot_clickhouse_logs.tar.gz   # ClickHouse logs
├── coroot_node_agent_data.tar.gz   # Node agent WAL
├── coroot_cluster_agent_data.tar.gz # Cluster agent WAL
├── coroot_caddy_data.tar.gz        # TLS certificates
└── coroot_caddy_config.tar.gz      # Caddy config
```

Last 3 backups are retained; older ones are pruned automatically.

## DNS

DNS is managed via Cloudflare (zone: `beerpub.dev`). To add a new subdomain:

```bash
curl -X POST "https://api.cloudflare.com/client/v4/zones/99dd7fb187fb6f0d08127a7899b92bed/dns_records" \
  -H "Authorization: Bearer <CF_API_TOKEN>" \
  -H "Content-Type: application/json" \
  --data '{"type":"A","name":"<subdomain>","content":"91.99.74.36","ttl":1,"proxied":false}'
```
