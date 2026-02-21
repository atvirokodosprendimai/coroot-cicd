# Sending Data from Apps to Coroot

Coroot endpoint: `https://table.beerpub.dev`

Coroot accepts metrics, traces, logs, and profiles. There are two approaches:

1. **coroot-node-agent** (eBPF, zero-code) - automatically collects everything from all containers on a host
2. **OpenTelemetry SDK** (in-code instrumentation) - add to your app for detailed traces and custom spans

---

## 1. Install coroot-node-agent on a Remote Host

For any Linux server you want to monitor, run the node-agent as a Docker container:

```bash
docker run -d --name coroot-node-agent \
  --restart always \
  --privileged --pid host \
  -v /sys/kernel/tracing:/sys/kernel/tracing:rw \
  -v /sys/kernel/debug:/sys/kernel/debug:rw \
  -v /sys/fs/cgroup:/host/sys/fs/cgroup:ro \
  ghcr.io/coroot/coroot-node-agent \
  --cgroupfs-root=/host/sys/fs/cgroup \
  --collector-endpoint=https://table.beerpub.dev
```

This automatically collects:
- **Metrics**: CPU, memory, disk, network for all containers and the host
- **Traces**: eBPF-captured HTTP, gRPC, database, and Redis requests (no code changes)
- **Logs**: Container stdout/stderr logs
- **Profiles**: CPU profiles via eBPF

No code changes needed. All containers on the host are monitored automatically.

### Non-Docker Install (systemd)

```bash
curl -sfL https://raw.githubusercontent.com/coroot/coroot-node-agent/main/install.sh | \
  COLLECTOR_ENDPOINT=https://table.beerpub.dev \
  SCRAPE_INTERVAL=15s \
  sh -
```

---

## 2. OpenTelemetry Instrumentation (Traces)

For detailed application-level tracing, instrument your app with OpenTelemetry. Coroot accepts OTLP over HTTP.

### Endpoint

```
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://table.beerpub.dev/v1/traces
```

### Go

Install dependencies:

```bash
go get \
  go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp \
  go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp
```

Initialize the tracer in your app:

```go
package main

import (
    "context"
    "log"
    "net/http"

    "go.opentelemetry.io/contrib/instrumentation/net/http/otelhttp"
    "go.opentelemetry.io/otel"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace"
    "go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
    "go.opentelemetry.io/otel/propagation"
    "go.opentelemetry.io/otel/sdk/resource"
    sdktrace "go.opentelemetry.io/otel/sdk/trace"
)

func initTracer() {
    ctx := context.Background()
    client := otlptracehttp.NewClient()
    exporter, err := otlptrace.New(ctx, client)
    if err != nil {
        log.Fatalf("failed to initialize exporter: %e", err)
    }
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

Run with:

```bash
export OTEL_SERVICE_NAME="my-service"
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="https://table.beerpub.dev/v1/traces"
go run main.go
```

### Java

Use the OpenTelemetry Java Agent (zero-code):

```bash
export OTEL_SERVICE_NAME="my-java-app"
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="https://table.beerpub.dev/v1/traces"

java -javaagent:opentelemetry-javaagent.jar -jar my-app.jar
```

Download the agent: https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases

### Python

```bash
pip install opentelemetry-distro opentelemetry-exporter-otlp
opentelemetry-bootstrap -a install
```

Run with:

```bash
export OTEL_SERVICE_NAME="my-python-app"
export OTEL_EXPORTER_OTLP_TRACES_ENDPOINT="https://table.beerpub.dev/v1/traces"

opentelemetry-instrument python my_app.py
```

### Any Language (Docker Compose)

Add these environment variables to any service in your `docker-compose.yml`:

```yaml
environment:
  - OTEL_SERVICE_NAME=my-service
  - OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=https://table.beerpub.dev/v1/traces
```

---

## 3. Prometheus Remote Write

If you already have a Prometheus server, configure it to remote-write to Coroot:

```yaml
# prometheus.yml
remote_write:
  - url: https://table.beerpub.dev/api/v1/write
```

---

## 4. Sending Logs via OTLP

Applications can send logs using the OpenTelemetry protocol:

```
OTEL_EXPORTER_OTLP_LOGS_ENDPOINT=https://table.beerpub.dev/v1/logs
```

Note: coroot-node-agent already collects container stdout/stderr logs automatically. Use this only if you need structured application logs beyond what the agent captures.

---

## Summary

| Method               | What it collects                           | Code changes needed |
|----------------------|--------------------------------------------|---------------------|
| coroot-node-agent    | Metrics, traces, logs, profiles (all containers) | None          |
| OpenTelemetry SDK    | Detailed app traces with custom spans      | Yes                 |
| Prometheus remote write | Existing Prometheus metrics              | Config only         |
| OTLP logs            | Structured application logs                | Yes                 |
