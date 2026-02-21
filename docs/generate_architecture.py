#!/usr/bin/env python3
"""Generate the webweb architecture diagram for the Coroot CI/CD system.

Outputs: docs/architecture.html
"""

from webweb import Web

# Nodes represent system components
# Groups: github (CI/CD), vps (server), external (storage/dns), coroot (stack)
nodes = {
    # GitHub infrastructure
    "GitHub Actions": {
        "group": "GitHub",
        "type": "ci",
    },
    "Secret Scan": {
        "group": "GitHub",
        "type": "ci",
    },
    "Uptime Monitor": {
        "group": "GitHub",
        "type": "ci",
    },
    "Git Repo": {
        "group": "GitHub",
        "type": "repo",
    },
    # VPS components
    "Hetzner VPS": {
        "group": "VPS",
        "type": "server",
    },
    "Docker Engine": {
        "group": "VPS",
        "type": "runtime",
    },
    "Caddy": {
        "group": "Coroot Stack",
        "type": "proxy",
    },
    "Coroot": {
        "group": "Coroot Stack",
        "type": "app",
    },
    "Prometheus": {
        "group": "Coroot Stack",
        "type": "datastore",
    },
    "ClickHouse": {
        "group": "Coroot Stack",
        "type": "datastore",
    },
    "Node Agent": {
        "group": "Coroot Stack",
        "type": "agent",
    },
    "Cluster Agent": {
        "group": "Coroot Stack",
        "type": "agent",
    },
    # Staging
    "Staging Stack": {
        "group": "VPS",
        "type": "staging",
    },
    # Local backups
    "Local Backups": {
        "group": "VPS",
        "type": "storage",
    },
    # External services
    "Storage Box": {
        "group": "External",
        "type": "storage",
    },
    "Cloudflare DNS": {
        "group": "External",
        "type": "dns",
    },
    "table.beerpub.dev": {
        "group": "External",
        "type": "endpoint",
    },
}

# Edges represent connections/data flow between components
edges = [
    # CI/CD flow
    ["Git Repo", "GitHub Actions"],
    ["Git Repo", "Secret Scan"],
    ["GitHub Actions", "Hetzner VPS"],
    # Uptime monitoring
    ["Uptime Monitor", "table.beerpub.dev"],
    # VPS internal
    ["Hetzner VPS", "Docker Engine"],
    ["Docker Engine", "Caddy"],
    ["Docker Engine", "Coroot"],
    ["Docker Engine", "Prometheus"],
    ["Docker Engine", "ClickHouse"],
    ["Docker Engine", "Node Agent"],
    ["Docker Engine", "Cluster Agent"],
    ["Docker Engine", "Staging Stack"],
    # Coroot stack internal
    ["Caddy", "Coroot"],
    ["Coroot", "Prometheus"],
    ["Coroot", "ClickHouse"],
    ["Node Agent", "Coroot"],
    ["Cluster Agent", "Prometheus"],
    # External access
    ["Cloudflare DNS", "table.beerpub.dev"],
    ["table.beerpub.dev", "Caddy"],
    # Backups
    ["Docker Engine", "Local Backups"],
    ["Local Backups", "Storage Box"],
    # GitHub Actions specific flows
    ["GitHub Actions", "Staging Stack"],
    ["GitHub Actions", "Local Backups"],
]

web = Web(
    adjacency=edges,
    title="Coroot CI/CD Architecture",
    display={
        "colorBy": "group",
        "sizeBy": "degree",
        "scaleLinkWidth": True,
        "scaleLinkOpacity": True,
        "linkLength": 60,
        "charge": 300,
        "gravity": 0.3,
        "nameBy": "name",
        "width": 1200,
        "height": 800,
    },
    nodes=nodes,
)

web.save("docs/architecture.html")
print("Generated docs/architecture.html")
