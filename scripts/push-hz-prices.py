#!/usr/bin/env python3
"""Derive per-CPU and per-memory hourly pricing from Hetzner Cloud and
update Coroot's custom cloud pricing via its project API.

Fetches all active servers from the Hetzner API, sums their hourly costs and
resource totals, then splits the blended rate into per-CPU-core and
per-memory-GB values using the same CPU:memory ratio as Coroot's GCP baseline.
Authenticates to Coroot, auto-discovers the project name, then posts the
derived rates to /api/project/{project}/custom_cloud_pricing.

Required env:
  HETZNER_TOKEN    — Hetzner Cloud API token
  COROOT_EMAIL     — Coroot admin email
  COROOT_PASSWORD  — Coroot admin password

Optional env:
  COROOT_URL       — Coroot base URL (default: https://table.beerpub.dev)
  COROOT_PROJECT   — Project name override (auto-discovered from API if unset)
"""

import http.cookiejar
import json
import os
import sys
import urllib.error
import urllib.request

# --- Config ---

HETZNER_TOKEN = os.environ.get("HETZNER_TOKEN")
COROOT_EMAIL = os.environ.get("COROOT_EMAIL")
COROOT_PASSWORD = os.environ.get("COROOT_PASSWORD")

for var in ("HETZNER_TOKEN", "COROOT_EMAIL", "COROOT_PASSWORD"):
    if not os.environ.get(var):
        sys.exit(f"error: {var} not set")

COROOT_URL = os.environ.get("COROOT_URL", "https://table.beerpub.dev").rstrip("/")
COROOT_PROJECT = os.environ.get("COROOT_PROJECT", "")

# CPU:memory cost ratio — matches Coroot's GCP C4 baseline
# (0.03465 USD/vCPU/hr ÷ 0.003938 USD/GB/hr ≈ 8.8)
CPU_MEMORY_RATIO = 0.03465 / 0.003938


# --- Helpers ---

def hetzner_get(path: str) -> dict:
    req = urllib.request.Request(
        f"https://api.hetzner.cloud{path}",
        headers={"Authorization": f"Bearer {HETZNER_TOKEN}"},
    )
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())


# Coroot session — cookie jar persists the auth cookie across requests
_jar = http.cookiejar.CookieJar()
_opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(_jar))


def coroot_request(method: str, path: str, body: dict | None = None) -> dict | None:
    data = json.dumps(body).encode() if body is not None else None
    headers = {"Content-Type": "application/json"} if data else {}
    req = urllib.request.Request(
        f"{COROOT_URL}{path}",
        data=data,
        method=method,
        headers=headers,
    )
    try:
        with _opener.open(req, timeout=15) as resp:
            raw = resp.read()
            return json.loads(raw) if raw.strip() else None
    except urllib.error.HTTPError as e:
        body_text = e.read().decode(errors="replace").strip()
        raise RuntimeError(f"HTTP {e.code} {method} {path}: {body_text}") from e


# --- 1. Fetch Hetzner pricing ---

print("Fetching Hetzner pricing catalog...")
pricing = hetzner_get("/v1/pricing")["pricing"]

price_lookup: dict[str, dict[str, dict]] = {
    st["name"]: {
        p["location"]: {
            "hourly": float(p["price_hourly"]["net"]),
            "monthly": float(p["price_monthly"]["net"]),
        }
        for p in st["prices"]
    }
    for st in pricing["server_types"]
}

print("Fetching active servers...")
servers = hetzner_get("/v1/servers")["servers"]

if not servers:
    sys.exit("error: no active servers found in Hetzner account")

# --- 2. Aggregate cost and resources ---

total_hourly = 0.0
total_vcpus = 0
total_ram_gb = 0.0

print()
for server in servers:
    stype = server["server_type"]["name"]
    vcpus = server["server_type"]["cores"]
    ram_gb = server["server_type"]["memory"]
    location = server["datacenter"]["location"]["name"]
    prices = price_lookup.get(stype, {}).get(location)

    if not prices:
        print(f"  {server['name']}: no price found for {stype}@{location}, skipping")
        continue

    total_hourly += prices["hourly"]
    total_vcpus += vcpus
    total_ram_gb += ram_gb
    print(
        f"  {server['name']}: {stype} @ {location}"
        f" — {prices['monthly']:.4f} EUR/mo, {vcpus} vCPU, {ram_gb:.0f} GB RAM"
    )

if total_vcpus == 0:
    sys.exit("error: could not resolve pricing for any active server")

# --- 3. Derive per-CPU and per-memory rates ---
#
# Solve: per_cpu * vcpus + per_memory * ram = total_hourly
#        per_cpu = CPU_MEMORY_RATIO * per_memory
# =>     per_memory = total_hourly / (CPU_MEMORY_RATIO * vcpus + ram)

per_memory = total_hourly / (CPU_MEMORY_RATIO * total_vcpus + total_ram_gb)
per_cpu = CPU_MEMORY_RATIO * per_memory

print()
print(f"Blended rate  : {total_hourly:.6f} EUR/hr ({total_vcpus} vCPU, {total_ram_gb:.0f} GB)")
print(f"per_cpu_core  : {per_cpu:.6f} EUR/hr")
print(f"per_memory_gb : {per_memory:.6f} EUR/hr")

assert abs(per_cpu * total_vcpus + per_memory * total_ram_gb - total_hourly) < 1e-9

# --- 4. Authenticate to Coroot ---

print(f"\nLogging in to {COROOT_URL} ...")
coroot_request("POST", "/api/login", {"email": COROOT_EMAIL, "password": COROOT_PASSWORD})
print("Authenticated.")

# --- 5. Discover project name ---

if not COROOT_PROJECT:
    print("Discovering project name...")
    # Try the dedicated projects list endpoint first, fall back to probing "default"
    try:
        projects = coroot_request("GET", "/api/projects") or []
        if isinstance(projects, list) and projects:
            COROOT_PROJECT = projects[0].get("name") or projects[0].get("id", "default")
            print(f"  Found projects: {[p.get('name') or p.get('id') for p in projects]}")
            print(f"  Using: {COROOT_PROJECT}")
        else:
            raise ValueError("empty projects list")
    except Exception as e:
        print(f"  /api/projects unavailable ({e}), probing overview endpoints...")
        for candidate in ("default",):
            try:
                resp = coroot_request("GET", f"/api/project/{candidate}/overview")
                if resp is not None:
                    COROOT_PROJECT = candidate
                    print(f"  Using: {COROOT_PROJECT}")
                    break
            except RuntimeError:
                pass
        else:
            sys.exit(
                "error: could not auto-discover project name. "
                "Set COROOT_PROJECT env var explicitly."
            )

# --- 6. Update Coroot custom cloud pricing ---

endpoint = f"/api/project/{COROOT_PROJECT}/custom_cloud_pricing"
print(f"\nPosting rates to {COROOT_URL}{endpoint} ...")
coroot_request("POST", endpoint, {"per_cpu_core": per_cpu, "per_memory_gb": per_memory})
print("Done.")
