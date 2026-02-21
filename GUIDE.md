# Deploy Any Docker Image on Hetzner VPS with Coroot Observability

A complete guide to provisioning a Hetzner Cloud VPS, deploying any Docker image, exposing it via HTTPS, and wiring it into Coroot for full observability.

---

## Prerequisites

- [hcloud CLI](https://github.com/hetznercloud/cli) installed (`brew install hcloud`)
- A Hetzner Cloud API token
- A domain with DNS you can manage (e.g. Cloudflare)
- An SSH key pair (or generate one during setup)

---

## Step 1: Provision the VPS

### Generate an SSH key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/hetzner-<project> -N "" -C "<project>@yourdomain.com"
```

### Upload the key and create the server

```bash
export HCLOUD_TOKEN="<your-hcloud-token>"

hcloud ssh-key create --name <project> --public-key-from-file ~/.ssh/hetzner-<project>.pub

hcloud server create \
  --name <project> \
  --type cax11 \
  --image ubuntu-24.04 \
  --location nbg1 \
  --ssh-key <project>
```

Note the IP address from the output.

### Available server types

| Type   | CPU     | RAM    | Arch | ~Price/mo |
|--------|---------|--------|------|-----------|
| cax11  | 2 vCPU  | 4 GB   | ARM  | ~3.30 EUR |
| cax21  | 4 vCPU  | 8 GB   | ARM  | ~5.90 EUR |
| cpx11  | 2 vCPU  | 2 GB   | x86  | ~4.35 EUR |
| cpx21  | 3 vCPU  | 4 GB   | x86  | ~8.09 EUR |

Run `hcloud server-type list` for the full list.

---

## Step 2: Point DNS to the Server

Create an A record for your domain pointing to the server IP.

**Cloudflare example:**

```bash
curl -X POST "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records" \
  -H "Authorization: Bearer <CF_API_TOKEN>" \
  -H "Content-Type: application/json" \
  --data '{
    "type": "A",
    "name": "<subdomain>",
    "content": "<SERVER_IP>",
    "ttl": 1,
    "proxied": false
  }'
```

Set `proxied: false` so Caddy can obtain TLS certificates directly from Let's Encrypt.

---

## Step 3: Install Docker

```bash
ssh -i ~/.ssh/hetzner-<project> root@<SERVER_IP> \
  'apt-get update -qq && apt-get install -y -qq docker.io docker-compose-v2'
```

---

## Step 4: Create the Deployment

SSH into the server:

```bash
ssh -i ~/.ssh/hetzner-<project> root@<SERVER_IP>
```

Create the project directory:

```bash
mkdir -p /opt/<project>
```

### docker-compose.yml

Create `/opt/<project>/docker-compose.yml`:

```yaml
services:
  # === YOUR APP ===
  my-app:
    image: ghcr.io/your-org/your-app:latest
    restart: always
    pull_policy: always
    expose:
      - "3000"
    environment:
      - DATABASE_URL=postgres://user:pass@db:5432/mydb
      # OpenTelemetry (optional, for in-app tracing)
      - OTEL_SERVICE_NAME=my-app
      - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://coroot:8080/v1/traces
      - OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://coroot:8080/v1/logs
    depends_on:
      coroot:
        condition: service_healthy

  # === COROOT STACK ===
  coroot:
    restart: always
    image: ghcr.io/coroot/coroot
    pull_policy: always
    user: root
    volumes:
      - coroot_data:/data
    expose:
      - "8080"
    command:
      - "--data-dir=/data"
      - "--bootstrap-prometheus-url=http://prometheus:9090"
      - "--bootstrap-refresh-interval=15s"
      - "--bootstrap-clickhouse-address=clickhouse:9000"
    depends_on:
      clickhouse:
        condition: service_healthy
      prometheus:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8080/"]
      interval: 5s
      timeout: 5s
      retries: 10
      start_period: 15s

  node-agent:
    restart: always
    image: ghcr.io/coroot/coroot-node-agent
    pull_policy: always
    privileged: true
    pid: "host"
    volumes:
      - /sys/kernel/tracing:/sys/kernel/tracing
      - /sys/kernel/debug:/sys/kernel/debug
      - /sys/fs/cgroup:/host/sys/fs/cgroup
      - node_agent_data:/data
    command:
      - "--collector-endpoint=http://coroot:8080"
      - "--cgroupfs-root=/host/sys/fs/cgroup"
      - "--wal-dir=/data"

  cluster-agent:
    restart: always
    image: ghcr.io/coroot/coroot-cluster-agent
    pull_policy: always
    volumes:
      - cluster_agent_data:/data
    command:
      - "--coroot-url=http://coroot:8080"
      - "--metrics-scrape-interval=15s"
      - "--metrics-wal-dir=/data"
    depends_on:
      - coroot

  prometheus:
    restart: always
    image: prom/prometheus:v2.53.5
    volumes:
      - prometheus_data:/prometheus
    command:
      - "--config.file=/etc/prometheus/prometheus.yml"
      - "--storage.tsdb.path=/prometheus"
      - "--web.console.libraries=/usr/share/prometheus/console_libraries"
      - "--web.console.templates=/usr/share/prometheus/consoles"
      - "--web.enable-lifecycle"
      - "--web.enable-remote-write-receiver"
    expose:
      - "9090"
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:9090/-/healthy"]
      interval: 3s
      timeout: 5s
      retries: 5
      start_period: 10s

  clickhouse:
    restart: always
    image: clickhouse/clickhouse-server:24.3
    environment:
      CLICKHOUSE_SKIP_USER_SETUP: "1"
    volumes:
      - clickhouse_data:/var/lib/clickhouse
      - clickhouse_logs:/var/log/clickhouse-server
    expose:
      - "9000"
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
    configs:
      - source: clickhouse_logging
        target: /etc/clickhouse-server/config.d/logging_rules.xml
      - source: clickhouse_user_logging
        target: /etc/clickhouse-server/config.d/user_logging.xml
    healthcheck:
      test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:8123/ping"]
      interval: 3s
      timeout: 5s
      retries: 5
      start_period: 10s

  # === REVERSE PROXY ===
  caddy:
    image: caddy:2
    restart: always
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - caddy_data:/data
      - caddy_config:/config
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
    depends_on:
      - coroot
      - my-app

volumes:
  coroot_data:
  prometheus_data:
  clickhouse_data:
  clickhouse_logs:
  node_agent_data:
  cluster_agent_data:
  caddy_data:
  caddy_config:

configs:
  clickhouse_logging:
    content: |
      <clickhouse>
        <logger>
            <level>warning</level>
            <console>true</console>
        </logger>
        <query_thread_log remove="remove"/>
        <query_log remove="remove"/>
        <text_log remove="remove"/>
        <trace_log remove="remove"/>
        <metric_log remove="remove"/>
        <asynchronous_metric_log remove="remove"/>
        <session_log remove="remove"/>
        <part_log remove="remove"/>
        <latency_log remove="remove"/>
        <processors_profile_log remove="remove"/>
      </clickhouse>
  clickhouse_user_logging:
    content: |
      <clickhouse>
        <profiles>
          <default>
            <log_queries>0</log_queries>
            <log_query_threads>0</log_query_threads>
            <log_processors_profiles>0</log_processors_profiles>
          </default>
        </profiles>
      </clickhouse>
```

### Caddyfile

Create `/opt/<project>/Caddyfile`:

```
# Your app
my-app.yourdomain.com {
    reverse_proxy my-app:3000
}

# Coroot dashboard
coroot.yourdomain.com {
    reverse_proxy coroot:8080
}
```

Each domain block gets automatic HTTPS via Let's Encrypt. Make sure DNS A records exist for each domain before deploying.

---

## Step 5: Deploy

```bash
cd /opt/<project>
docker compose up -d
```

Wait for health checks to pass:

```bash
docker compose ps
```

All services should show `Up` (with `(healthy)` for coroot, prometheus, clickhouse).

---

## Step 6: Verify

- Open `https://my-app.yourdomain.com` — your app
- Open `https://coroot.yourdomain.com` — Coroot dashboard

Within 2-3 minutes, Coroot will auto-discover your app and show:
- CPU, memory, disk, network metrics
- eBPF-captured HTTP/gRPC/DB traces
- Container logs
- CPU profiles

---

## Integrating Coroot into Your Docker Image

There are two levels of observability — pick one or both:

### Level 1: Zero-code (automatic via node-agent)

Already included in the compose file above. The `node-agent` service uses eBPF to automatically collect metrics, traces, logs, and profiles from **all containers** on the host. No changes to your app needed.

What you get for free:
- HTTP/gRPC request latency and error rates
- TCP connection tracking and service map
- Container resource usage
- Log pattern detection
- CPU profiling

### Level 2: OpenTelemetry SDK (in-app instrumentation)

For richer traces with custom spans, add OpenTelemetry to your app. The OTEL environment variables in the compose file point to Coroot's OTLP receiver.

**Environment variables** (already set in the compose example above):

```yaml
environment:
  - OTEL_SERVICE_NAME=my-app
  - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://coroot:8080/v1/traces
  - OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=http://coroot:8080/v1/logs
```

Use `http://coroot:8080` (not the public URL) since the app is on the same Docker network.

#### Go Dockerfile example

```dockerfile
FROM golang:1.22-alpine AS builder
WORKDIR /app
COPY go.mod go.sum ./
RUN go get \
    go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp \
    go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
RUN go mod download
COPY . .
RUN CGO_ENABLED=0 go build -o /app/server .

FROM alpine:3.20
COPY --from=builder /app/server /server
EXPOSE 3000
CMD ["/server"]
```

In your Go code, initialize the tracer:

```go
func initTracer() {
    ctx := context.Background()
    client := otlptracehttp.NewClient()
    exporter, _ := otlptrace.New(ctx, client)
    res, _ := resource.New(ctx)
    tp := sdktrace.NewTracerProvider(
        sdktrace.WithBatcher(exporter),
        sdktrace.WithResource(res),
    )
    otel.SetTracerProvider(tp)
    otel.SetTextMapPropagator(
        propagation.NewCompositeTextMapPropagator(
            propagation.TraceContext{},
            propagation.Baggage{},
        ),
    )
}
```

#### Java Dockerfile example

```dockerfile
FROM eclipse-temurin:21-jre
WORKDIR /app
ADD https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/latest/download/opentelemetry-javaagent.jar /app/otel-agent.jar
COPY target/my-app.jar /app/my-app.jar
EXPOSE 8080
CMD ["java", "-javaagent:/app/otel-agent.jar", "-jar", "/app/my-app.jar"]
```

No code changes needed — the Java agent auto-instruments.

#### Python Dockerfile example

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
    opentelemetry-distro opentelemetry-exporter-otlp
RUN opentelemetry-bootstrap -a install
COPY . .
EXPOSE 8000
CMD ["opentelemetry-instrument", "python", "app.py"]
```

No code changes needed — `opentelemetry-instrument` wraps your app.

#### Node.js Dockerfile example

```dockerfile
FROM node:20-alpine
WORKDIR /app
COPY package*.json ./
RUN npm install
RUN npm install @opentelemetry/auto-instrumentations-node @opentelemetry/exporter-trace-otlp-http
COPY . .
EXPOSE 3000
ENV NODE_OPTIONS="--require @opentelemetry/auto-instrumentations-node/register"
CMD ["node", "server.js"]
```

---

## Operations

### Update your app

```bash
cd /opt/<project>
docker compose pull my-app
docker compose up -d my-app
```

### View logs

```bash
docker compose logs -f my-app        # your app
docker compose logs -f coroot         # coroot
docker compose logs --tail 50 my-app  # last 50 lines
```

### Restart

```bash
docker compose restart my-app   # single service
docker compose down && docker compose up -d  # everything
```

### Add another service

1. Add the service to `docker-compose.yml`
2. Add a domain block to `Caddyfile`
3. Create the DNS A record
4. Run `docker compose up -d`

---

## Architecture Overview

```
Internet
  |
  v
[Caddy :443] -- auto TLS via Let's Encrypt
  |
  +--> my-app:3000          (your application)
  +--> coroot:8080           (observability dashboard)
         |
         +--> prometheus:9090  (metrics storage)
         +--> clickhouse:9000  (logs/traces/profiles)
         |
[node-agent]                 (eBPF collector, monitors all containers)
[cluster-agent]              (metrics scraper)
```
