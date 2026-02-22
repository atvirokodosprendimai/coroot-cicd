# Autonomous Agent Provisioning Protocol for Observability Tenants

```
Status:       Superseded
Version:      0.3
Authors:      oldroot
Date:         2026-02-21
Instance:     table.beerpub.dev
Superseded-By: https://github.com/atvirokodosprendimai/edproof
```

## Abstract

This document specifies a protocol by which autonomous agents — LLM coding
agents, CI/CD pipelines, IoT devices, mesh network nodes — can self-provision
observability tenants on a Coroot instance without human intervention. The
protocol uses Ed25519 public key cryptography to establish identity, a
challenge-response nonce mechanism to prevent replay attacks, and
HMAC-derived project names to resist enumeration. No secrets are transmitted
over the wire. The protocol is designed to operate safely over public
channels and to integrate with the wgmesh WireGuard mesh network ecosystem.

## Table of Contents

- [1. Introduction](#1-introduction)
  - [1.1. Problem Statement](#11-problem-statement)
  - [1.2. Design Goals](#12-design-goals)
- [2. Relationship to Existing Standards](#2-relationship-to-existing-standards)
- [3. Terminology](#3-terminology)
- [4. Protocol Overview](#4-protocol-overview)
- [5. The EdProof Authentication Scheme](#5-the-edproof-authentication-scheme)
  - [5.1. Scheme Definition](#51-scheme-definition)
  - [5.2. Parameters](#52-parameters)
  - [5.3. Signature Construction](#53-signature-construction)
- [6. Key Management](#6-key-management)
  - [6.1. Allowed Keys Registry](#61-allowed-keys-registry)
  - [6.1.1. Curve25519 Key Compatibility](#611-curve25519-key-compatibility)
- [7. Authorization Model](#7-authorization-model)
  - [7.1. Per-Key Authorization](#71-per-key-authorization)
  - [7.2. Shared-Secret Membership](#72-shared-secret-membership)
  - [7.3. Combined Mode](#73-combined-mode)
- [8. Provisioning Flow](#8-provisioning-flow)
  - [8.1. Nonce Acquisition](#81-nonce-acquisition)
  - [8.2. Authenticated Request](#82-authenticated-request)
  - [8.3. Idempotency](#83-idempotency)
  - [8.4. Project Name Derivation](#84-project-name-derivation)
- [9. Request and Response Formats](#9-request-and-response-formats)
  - [9.1. Request Body](#91-request-body)
  - [9.2. Success Response](#92-success-response)
  - [9.3. Error Responses](#93-error-responses)
- [10. Signature Construction](#10-signature-construction)
  - [10.1. SSH Signature Format](#101-ssh-signature-format)
  - [10.2. Raw Ed25519 Signature](#102-raw-ed25519-signature)
- [11. Deployment](#11-deployment)
  - [11.1. Standalone Deployment](#111-standalone-deployment)
  - [11.2. Mesh Network Deployment](#112-mesh-network-deployment)
- [12. Examples](#12-examples)
  - [12.1. Nonce Acquisition](#121-nonce-acquisition)
  - [12.2. SSH Signature Provisioning](#122-ssh-signature-provisioning)
  - [12.3. Raw Ed25519 Provisioning](#123-raw-ed25519-provisioning)
  - [12.4. wgmesh Node Provisioning](#124-wgmesh-node-provisioning)
- [13. Security Considerations](#13-security-considerations)
  - [13.1. Threat Model Summary](#131-threat-model-summary)
  - [13.2. Nonce Replay and Timing](#132-nonce-replay-and-timing)
  - [13.3. Key Compromise and Enumeration Resistance](#133-key-compromise-and-enumeration-resistance)
  - [13.4. Mesh Network Integration](#134-mesh-network-integration)
- [14. IANA Considerations](#14-iana-considerations)
- [15. References](#15-references)
  - [15.1. Normative References](#151-normative-references)
  - [15.2. Informative References](#152-informative-references)
- [Appendix A. Ecosystem: Mesh Network Integration](#appendix-a-ecosystem-mesh-network-integration)
  - [A.1. Structural Parallel](#a1-structural-parallel)
  - [A.2. Identity Bridging](#a2-identity-bridging)
  - [A.3. Deployment Models](#a3-deployment-models)
  - [A.4. Secret Derivation Chain](#a4-secret-derivation-chain)
  - [A.5. Lifecycle Binding](#a5-lifecycle-binding)
- [Appendix B. Formal Verification](#appendix-b-formal-verification)
  - [B.1. Model Overview](#b1-model-overview)
  - [B.2. Adversary Model](#b2-adversary-model)
  - [B.3. Security Lemmas](#b3-security-lemmas)
  - [B.4. Structural Guarantees](#b4-structural-guarantees)
  - [B.5. Running the Verification](#b5-running-the-verification)

---

## 1. Introduction

### 1.1. Problem Statement

Autonomous software agents increasingly need observability infrastructure.
An LLM coding agent spun up to work on a repository needs a place to send
traces. A CI/CD pipeline deploying to a new environment needs a monitoring
tenant. A mesh network node joining a cluster needs to report its health.

Today, creating an observability tenant requires human intervention: an
operator logs into a web console, clicks "New Project", copies an API key,
and pastes it into the agent's configuration. This process does not scale
to environments where agents are created and destroyed programmatically,
where no human is available at provisioning time, or where the provisioning
request must traverse an untrusted network.

The core challenge is: **how does an unknown agent prove it is authorized
to receive an observability tenant, without transmitting any secrets, and
without requiring a human to approve the request?**

### 1.2. Design Goals

The protocol is designed around these constraints, derived through
TRIZ/ARIZ analysis of the fundamental contradictions:

1. **No secrets on the wire.** The requestor proves identity by signing a
   challenge with a private key. Only the public key and signature are
   transmitted. An eavesdropper learns nothing useful.

2. **No human in the loop.** The entire flow — from nonce acquisition to
   API key retrieval — completes in two HTTP round-trips with no approval
   step, no email confirmation, no OAuth redirect.

3. **Safe over public channels.** The protocol assumes the network is
   hostile. TLS provides transport confidentiality, but the protocol is
   secure even if TLS is stripped (the attacker still cannot forge a
   signature).

4. **Idempotent.** The same agent requesting the same service gets back
   the same tenant. No duplicates are created. The agent can retry safely
   after network failures.

5. **Enumeration-resistant.** An attacker who compromises one agent's key
   cannot discover or guess other tenants' names. Project names are derived
   via HMAC with a server-side secret.

6. **Ecosystem-aware.** The protocol integrates with the wgmesh WireGuard
   mesh network, sharing the same identity and authorization primitives
   at the service layer that wgmesh provides at the network layer.

## 2. Relationship to Existing Standards

This protocol draws from several existing standards but is not a profile
of any single one. No existing standard covers the complete problem space
of SSH-key-based identity + HTTP challenge-response + automated service
provisioning + zero human intervention.

**RFC 8555 — Automatic Certificate Management Environment (ACME)**

The nonce mechanism in this protocol is modeled on ACME. ACME uses a
`Replay-Nonce` header returned by the server, which the client MUST
include in subsequent requests. This protocol adopts the same pattern:
the server returns a nonce in the `Replay-Nonce` header of a `401`
response, and the client includes it in the `Authorization` header of the
follow-up request. Unlike ACME, this protocol does not use JWS or require
an account registration step.

**RFC 9449 — OAuth 2.0 Demonstrating Proof of Possession (DPoP)**

DPoP introduces the pattern of a server providing a nonce via an error
response (Section 8): the authorization server returns a
`use_dpop_nonce` error with a `DPoP-Nonce` header, and the client
retries with the server-provided nonce. This protocol adopts the same
"error-then-retry" flow. Unlike DPoP, this protocol does not operate
within the OAuth 2.0 framework and does not use JWT.

**RFC 9421 — HTTP Message Signatures**

RFC 9421 defines a general framework for signing HTTP messages. This
protocol's `EdProof` scheme is simpler: it signs only the nonce and
optional service name, not arbitrary HTTP message components. The full
generality of RFC 9421 is unnecessary for a single-endpoint provisioning
protocol, and its complexity would hinder adoption by lightweight agents.

**RFC 7235 — Hypertext Transfer Protocol: Authentication**

The `EdProof` authentication scheme defined in Section 5 follows the
framework established by RFC 7235: schemes are registered with parameters,
carried in the `Authorization` header, and challenged via `401` responses
with `WWW-Authenticate` headers.

**RFC 8032 — Edwards-Curve Digital Signature Algorithm (EdDSA)**

Ed25519, the signature algorithm used by this protocol, is defined in
RFC 8032. The "raw Ed25519" signature format (Section 10.2) produces
signatures as specified in RFC 8032 Section 5.1.6.

**SSHSIG — SSH Signature Format**

The SSH signature format (Section 10.1) uses the `sshsig` wire format
as implemented by OpenSSH's `ssh-keygen -Y sign`. This format wraps an
Ed25519 signature with a namespace, allowing the same key to be used for
multiple purposes without cross-protocol attacks. The namespace for this
protocol is `coroot-provision`.

**wgmesh — WireGuard Mesh Network Builder**

wgmesh is a decentralized WireGuard mesh network tool in the same
ecosystem as this protocol. It solves the same fundamental problem — "how
does an unknown node prove it belongs?" — at the network layer, using a
shared secret and Curve25519 public keys. This protocol solves the
equivalent problem at the service layer using Ed25519 public keys. The
two systems share a structural parallel and can be integrated through
Curve25519-to-Ed25519 key conversion (see Section 6.1.1) and shared-secret
membership proofs (see Section 7.2). See Appendix A for a comprehensive
analysis of the ecosystem integration.

## 3. Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT",
"SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and
"OPTIONAL" in this document are to be interpreted as described in
BCP 14 [RFC 2119] [RFC 8174] when, and only when, they appear in all
capitals, as shown here.

**Provisioner**: The server-side service that handles provisioning
requests. It validates signatures, manages the Allowed Keys Registry,
communicates with the Coroot API to create projects, and returns API keys
to authorized requestors.

**Requestor**: The autonomous agent requesting a new observability tenant.
The requestor possesses an Ed25519 private key and can produce signatures.

**Allowed Keys Registry**: A server-side data store (typically a file on
disk) containing the set of Ed25519 public keys authorized to provision
tenants. The mechanism by which keys are added to or removed from this
registry is out of scope for this protocol.

**Tenant**: A Coroot project with an associated API key. Telemetry data
(traces, logs, metrics, profiles) sent with this API key is routed to
this project.

**Fingerprint**: The SHA-256 hash of the Ed25519 public key, encoded in
the format used by OpenSSH (e.g., `SHA256:abcdef...`). Used as the
stable identifier for a key across the protocol.

**Nonce**: A single-use, server-generated, base64url-encoded random value
bound to a provisioning attempt. Nonces MUST NOT be reused and SHOULD
expire after a short time window (RECOMMENDED: 300 seconds).

**Service Name**: An OPTIONAL client-provided label identifying the
logical service or workload requesting the tenant. When provided, the
service name is incorporated into both the signature input and the
project name derivation, allowing a single key to provision multiple
distinct tenants.

## 4. Protocol Overview

The protocol operates over a single HTTP endpoint and completes in two
round-trips:

```
Requestor                                          Provisioner
    |                                                    |
    |  1. POST /provision                                |
    |    (no Authorization header)                       |
    |--------------------------------------------------->|
    |                                                    |
    |  2. 401 Unauthorized                               |
    |    WWW-Authenticate: EdProof                       |
    |    Replay-Nonce: <nonce>                            |
    |<---------------------------------------------------|
    |                                                    |
    |  --- Requestor signs: nonce || service_name ---     |
    |                                                    |
    |  3. POST /provision                                |
    |    Authorization: EdProof fingerprint="...",        |
    |      nonce="...", signature="...",                  |
    |      service_name="..."                            |
    |    Body: { "service_name": "my-agent" }            |
    |--------------------------------------------------->|
    |                                                    |
    |  4. 201 Created                                    |
    |    { "project_id": "...",                           |
    |      "project_name": "...",                         |
    |      "api_key": "...",                              |
    |      "endpoints": { ... },                          |
    |      "key_binding": { ... } }                       |
    |<---------------------------------------------------|
    |                                                    |
    |  --- Requestor configures OTLP exporter ---        |
    |  --- with api_key and endpoints ---                |
```

**Phase 1 (steps 1-2):** The requestor sends an unauthenticated POST to
acquire a nonce. The server responds with `401 Unauthorized`, a
`WWW-Authenticate: EdProof` challenge header, and a `Replay-Nonce` header
containing a fresh nonce. This follows the DPoP Section 8 pattern of
server-provided nonces via error responses.

**Phase 2 (steps 3-4):** The requestor signs the nonce (concatenated with
the optional service name) using its Ed25519 private key, then sends a
second POST with the `Authorization: EdProof` header containing the
fingerprint, nonce, signature, and optional service name. If the
signature is valid and the key is authorized, the server creates (or
returns) a Coroot project and responds with the project details and
API key.

After provisioning, the requestor configures its OpenTelemetry exporter
with the returned API key and endpoint URLs. Subsequent telemetry data
flows directly to Coroot's collector endpoints using standard OTLP over
HTTP — the provisioning protocol is not involved in the data path.

## 5. The EdProof Authentication Scheme

### 5.1. Scheme Definition

`EdProof` is an HTTP authentication scheme per RFC 7235. It carries a
proof-of-possession of an Ed25519 private key, bound to a server-provided
nonce.

The scheme is used in the `Authorization` request header:

```
Authorization: EdProof fingerprint="<fingerprint>",
  nonce="<nonce>",
  signature="<signature>"
  [, service_name="<service_name>"]
```

The server challenges with the `WWW-Authenticate` response header:

```
WWW-Authenticate: EdProof realm="coroot-provision"
```

### 5.2. Parameters

| Parameter      | Required | Description |
|----------------|----------|-------------|
| `fingerprint`  | REQUIRED | SHA-256 fingerprint of the requestor's Ed25519 public key, in OpenSSH format (`SHA256:<base64>`). |
| `nonce`        | REQUIRED | The nonce value from the server's `Replay-Nonce` header, echoed verbatim. |
| `signature`    | REQUIRED | Base64-encoded signature over the canonical message (see Section 5.3). |
| `service_name` | OPTIONAL | The logical service name for the tenant. If present, it MUST match the `service_name` field in the request body. |

### 5.3. Signature Construction

The canonical message to be signed is constructed as follows:

- If `service_name` is present: `nonce || service_name` (byte concatenation,
  no delimiter)
- If `service_name` is absent: `nonce` (the nonce bytes alone)

Both the nonce and service_name are UTF-8 encoded before concatenation.

The signature MUST be produced using one of the two formats defined in
Section 10:

1. **SSH Signature Format** (Section 10.1) — RECOMMENDED. Uses the
   `sshsig` wire format with namespace `coroot-provision`.
2. **Raw Ed25519 Signature** (Section 10.2) — OPTIONAL fallback. Produces
   a 64-byte Ed25519 signature per RFC 8032.

The server MUST accept both formats. It SHOULD attempt SSH signature
verification first, then fall back to raw Ed25519 verification.

## 6. Key Management

### 6.1. Allowed Keys Registry

The Allowed Keys Registry is a file on the provisioner's filesystem
containing one OpenSSH-format Ed25519 public key per line:

```
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... agent-1@example.com
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... ci-pipeline@org
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... mesh-node-07
```

Lines beginning with `#` are comments. Empty lines are ignored.

The mechanism by which keys are added to or removed from the registry
is out of scope for this protocol. Implementations MAY support:

- Manual editing by an operator
- Automated sync from a Git repository
- API-driven key management
- Derivation from a mesh network's key set (see Section 6.1.1)

The provisioner MUST reload the registry on each request or watch the
file for changes. Stale reads (serving a request against an outdated
key list) MUST NOT persist for longer than 60 seconds.

The file format is deliberately compatible with OpenSSH's
`authorized_keys` format and with `ssh-keygen -Y find-principals`.

### 6.1.1. Curve25519 Key Compatibility

wgmesh nodes identify themselves with Curve25519 public keys (used for
WireGuard key exchange). Ed25519 and Curve25519 are related via a
birational map on the same underlying curve (Curve25519 and Edwards25519
are birationally equivalent).

A provisioner deployed alongside a wgmesh network MAY accept Curve25519
public keys by converting them to Ed25519 format before verification.
The conversion is defined by RFC 7748 Section 4.1 and implemented in
most cryptographic libraries (e.g., `crypto/ed25519` in Go via
`edwards25519.Point.BytesMontgomery`).

Important constraints:

1. The conversion is **one-way in practice**: converting Curve25519 → Ed25519
   is well-defined, but the resulting Ed25519 key has an ambiguous sign bit.
   The provisioner MUST try both sign possibilities when verifying.

2. A wgmesh node wishing to use this protocol SHOULD generate an Ed25519
   key pair and derive the Curve25519 key from it (the safe direction),
   rather than attempting to sign with a Curve25519 private key.

3. The Allowed Keys Registry SHOULD store Ed25519 public keys. If a
   deployment needs to authorize wgmesh nodes by their Curve25519 keys,
   the provisioner SHOULD maintain a mapping or perform conversion at
   lookup time.

## 7. Authorization Model

The provisioner supports three authorization modes, selectable by the
operator via configuration. The mode determines what a requestor must
present to be authorized.

### 7.1. Per-Key Authorization

**Mode: `key_only`** (DEFAULT)

The requestor's Ed25519 public key fingerprint MUST appear in the Allowed
Keys Registry. No additional proof is required.

This mode is appropriate when the operator has direct control over which
keys are enrolled — for example, when keys are provisioned as part of
agent deployment, or when an administrator manually adds keys after
vetting the requestor.

```
Authorization decision:
  fingerprint ∈ Allowed Keys Registry → AUTHORIZED
  fingerprint ∉ Allowed Keys Registry → 403 Forbidden
```

### 7.2. Shared-Secret Membership

**Mode: `secret_only`**

The requestor MUST present an HMAC proof derived from a shared secret,
demonstrating membership in a group (e.g., a wgmesh network). The Allowed
Keys Registry is not consulted.

The HMAC proof is included as an additional parameter in the
`Authorization` header:

```
Authorization: EdProof fingerprint="...", nonce="...",
  signature="...", membership_proof="<base64>"
```

The `membership_proof` is computed as:

```
membership_proof = HMAC-SHA256(shared_secret, "coroot-provision" || fingerprint || nonce)
```

Where `shared_secret` is a value known to both the provisioner and all
authorized requestors (e.g., the wgmesh network secret or a value derived
from it via HKDF).

This mode is appropriate for wgmesh deployments where any node that knows
the mesh secret is implicitly authorized. The provisioner derives the
HMAC key from the same secret (or a dedicated HKDF derivation) and
verifies the proof.

```
Authorization decision:
  valid membership_proof → AUTHORIZED
  invalid/missing membership_proof → 403 Forbidden
```

### 7.3. Combined Mode

**Mode: `key_and_secret`**

Both conditions MUST be met: the fingerprint MUST appear in the Allowed
Keys Registry AND the requestor MUST present a valid `membership_proof`.

This provides defense in depth: even if the shared secret leaks, only
pre-enrolled keys can provision tenants. Even if a key is compromised,
the attacker also needs the shared secret.

```
Authorization decision:
  fingerprint ∈ Registry AND valid membership_proof → AUTHORIZED
  OTHERWISE → 403 Forbidden
```

## 8. Provisioning Flow

### 8.1. Nonce Acquisition

The requestor initiates provisioning by sending a POST request to the
provisioning endpoint with no `Authorization` header:

```http
POST /provision HTTP/1.1
Host: table.beerpub.dev
Content-Length: 0
```

The server MUST respond with:

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: EdProof realm="coroot-provision"
Replay-Nonce: dGhpcyBpcyBhIG5vbmNl
Content-Type: application/json

{"error": "nonce_required", "detail": "POST again with Authorization: EdProof header including this nonce"}
```

The `Replay-Nonce` header contains a fresh, cryptographically random,
base64url-encoded nonce. The server MUST generate at least 128 bits of
randomness for each nonce.

The server MUST store the nonce and its creation timestamp. Nonces MUST
be single-use: once a nonce has been used in a successful or failed
authorization attempt, it MUST be invalidated. Nonces SHOULD expire
after 300 seconds (5 minutes).

### 8.2. Authenticated Request

The requestor constructs the canonical message (Section 5.3), signs it,
and sends a second POST:

```http
POST /provision HTTP/1.1
Host: table.beerpub.dev
Authorization: EdProof fingerprint="SHA256:jE4x...",
  nonce="dGhpcyBpcyBhIG5vbmNl",
  signature="AAAAB3NzaC1lZDI1NTE5...",
  service_name="my-agent"
Content-Type: application/json

{"service_name": "my-agent"}
```

The server performs the following checks in order:

1. **Nonce validity**: The nonce MUST exist in the server's nonce store,
   MUST NOT have been used before, and MUST NOT have expired. If invalid,
   respond with `401 Unauthorized` and a fresh `Replay-Nonce`.

2. **Fingerprint lookup**: Resolve the fingerprint to a public key. In
   `key_only` or `key_and_secret` mode, the key MUST appear in the
   Allowed Keys Registry. In `secret_only` mode, the server MUST be able
   to reconstruct the public key from the fingerprint (the requestor
   SHOULD include the full public key in the request body for this mode).

3. **Signature verification**: Verify the signature over the canonical
   message using the resolved public key. Try SSH signature format first,
   then raw Ed25519.

4. **Membership proof** (if `secret_only` or `key_and_secret` mode):
   Verify the `membership_proof` parameter.

5. **Service name consistency**: If `service_name` is present in the
   `Authorization` header, it MUST match the `service_name` in the
   request body.

If all checks pass, the server provisions the tenant (Section 8.3, 8.4)
and responds with `201 Created` (Section 9.2).

### 8.3. Idempotency

The provisioning operation MUST be idempotent with respect to the tuple
`(fingerprint, service_name)`:

- If a project already exists for the given `(fingerprint, service_name)`
  pair, the server MUST return the existing project's details. It MUST
  NOT create a duplicate project.

- The returned API key MUST be the same API key that was originally
  created for that project. The server MUST NOT rotate keys on
  idempotent requests.

- The response status code for an idempotent hit is `200 OK`, not
  `201 Created`. The response body format is identical.

This allows agents to safely retry provisioning after network failures,
restarts, or configuration resets without accumulating orphaned projects.

### 8.4. Project Name Derivation

Project names MUST be derived deterministically from the requestor's
fingerprint and service name, using a server-side secret to prevent
enumeration:

```
raw = HMAC-SHA256(server_secret, fingerprint || service_name)
project_name = hex(raw[0:16])  // first 16 bytes, hex-encoded = 32 chars
```

Where:

- `server_secret` is a persistent, cryptographically random value known
  only to the provisioner. It MUST be at least 256 bits and MUST NOT
  change after deployment (changing it would orphan existing projects).

- `fingerprint` is the full SHA-256 fingerprint string (e.g.,
  `SHA256:jE4x...`).

- `service_name` is the service name string, or the empty string if not
  provided.

- `||` denotes byte concatenation with no delimiter.

This construction ensures:

- **Determinism**: The same inputs always produce the same project name,
  enabling idempotency.

- **Enumeration resistance**: Without `server_secret`, an attacker cannot
  predict or brute-force project names even if they know the fingerprint
  and service name.

- **Collision resistance**: HMAC-SHA256 with 128-bit truncation provides
  adequate collision resistance for the expected number of projects
  (< 2^20).

## 9. Request and Response Formats

### 9.1. Request Body

The request body is a JSON object. All fields are OPTIONAL in the request
body (the `Authorization` header carries the required parameters):

```json
{
  "service_name": "my-agent",
  "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA... comment"
}
```

| Field         | Type   | Description |
|---------------|--------|-------------|
| `service_name` | string | Logical service name. If present, MUST match the `service_name` in the `Authorization` header. |
| `public_key`   | string | Full OpenSSH-format public key. REQUIRED in `secret_only` mode when the key is not in the registry. OPTIONAL otherwise (server resolves from fingerprint). |

The request body MAY be empty or absent for nonce acquisition (Phase 1).

### 9.2. Success Response

On successful provisioning, the server responds with `201 Created`
(new project) or `200 OK` (existing project):

```json
{
  "project_id": "abc123",
  "project_name": "7f3a8c1e9d4b2f06a1c3e5d7f9b2a4c6",
  "api_key": "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
  "endpoints": {
    "traces": "https://table.beerpub.dev/v1/traces",
    "logs": "https://table.beerpub.dev/v1/logs",
    "metrics": "https://table.beerpub.dev/v1/metrics",
    "profiles": "https://table.beerpub.dev/v1/profiles",
    "prometheus_remote_write": "https://table.beerpub.dev/api/v1/write"
  },
  "key_binding": {
    "fingerprint": "SHA256:jE4x...",
    "service_name": "my-agent"
  }
}
```

| Field          | Type   | Description |
|----------------|--------|-------------|
| `project_id`   | string | Coroot's internal project identifier. |
| `project_name` | string | HMAC-derived project name (Section 8.4). |
| `api_key`      | string | 32-character API key for routing telemetry to this project. Include as `X-API-Key` header in OTLP requests. |
| `endpoints`    | object | Full URLs for each telemetry endpoint. |
| `key_binding`  | object | The identity tuple that this project is bound to. Included for client-side verification and future Phase 2 key-bound token enforcement. |

### 9.3. Error Responses

All error responses use the following JSON format:

```json
{
  "error": "<error_code>",
  "detail": "<human-readable description>"
}
```

| Status | Error Code | Condition |
|--------|------------|-----------|
| `401`  | `nonce_required` | No `Authorization` header present. Response includes `Replay-Nonce`. |
| `401`  | `nonce_invalid` | Nonce expired, already used, or not recognized. Response includes fresh `Replay-Nonce`. |
| `401`  | `signature_invalid` | Signature verification failed for both SSH and raw Ed25519 formats. |
| `403`  | `key_not_authorized` | Fingerprint not found in Allowed Keys Registry (in `key_only` or `key_and_secret` mode). |
| `403`  | `membership_invalid` | Membership proof verification failed (in `secret_only` or `key_and_secret` mode). |
| `400`  | `service_name_mismatch` | `service_name` in Authorization header does not match request body. |
| `400`  | `invalid_request` | Malformed request (missing required fields, invalid base64, etc.). |
| `429`  | `rate_limited` | Too many provisioning requests. Response includes `Retry-After` header. |
| `500`  | `provisioning_failed` | Internal error during Coroot project creation. |

When the server responds with `401` for nonce-related errors, it MUST
include a fresh `Replay-Nonce` header, allowing the client to retry
immediately without an additional round-trip.

## 10. Signature Construction

### 10.1. SSH Signature Format

The RECOMMENDED signature format uses the SSH `sshsig` wire format, as
produced by OpenSSH's `ssh-keygen -Y sign` command.

**Namespace**: `coroot-provision`

**Message**: The canonical message as defined in Section 5.3.

**Construction using ssh-keygen**:

```bash
# Write the canonical message to a temporary file
echo -n "${NONCE}${SERVICE_NAME}" > /tmp/provision-message

# Sign with the Ed25519 private key
ssh-keygen -Y sign \
  -f ~/.ssh/id_ed25519 \
  -n coroot-provision \
  /tmp/provision-message
```

This produces a PEM-encoded signature:

```
-----BEGIN SSH SIGNATURE-----
U1NIU0lHAAAAAQAAADMAAAALc3NoLWVkMjU1MTkAAAAg...
-----END SSH SIGNATURE-----
```

The `signature` parameter in the `Authorization` header MUST contain the
base64-encoded content between the PEM markers (the raw `sshsig` wire
format), not the PEM-wrapped version.

**Server-side verification**:

The server reconstructs the canonical message from the `nonce` and
`service_name` parameters, then verifies the signature using the
`sshsig` verification procedure with namespace `coroot-provision`.

The SSH signature format provides:

- **Namespace isolation**: The `coroot-provision` namespace prevents
  cross-protocol signature reuse. A signature produced for SSH
  authentication or Git commit signing cannot be replayed against this
  protocol.

- **Algorithm agility**: The `sshsig` format encodes the key type,
  allowing future support for other algorithms without protocol changes.

- **Tooling compatibility**: Any system with `ssh-keygen` can produce
  valid signatures, requiring no additional cryptographic libraries.

### 10.2. Raw Ed25519 Signature

As a fallback for environments where `ssh-keygen` is not available, the
server MUST also accept raw Ed25519 signatures per RFC 8032 Section 5.1.6.

**Message**: The canonical message as defined in Section 5.3, encoded as
UTF-8 bytes.

**Signature**: A 64-byte Ed25519 signature, base64-encoded.

**Construction in Go**:

```go
message := []byte(nonce + serviceName)
signature := ed25519.Sign(privateKey, message)
encoded := base64.StdEncoding.EncodeToString(signature)
```

**Construction in Python**:

```python
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
import base64

message = (nonce + service_name).encode("utf-8")
signature = private_key.sign(message)
encoded = base64.b64encode(signature).decode("ascii")
```

The raw format provides simplicity at the cost of namespace isolation.
Implementations using raw Ed25519 signatures SHOULD ensure that the same
key is not used for other signing purposes, to prevent cross-protocol
attacks.

## 11. Deployment

### 11.1. Standalone Deployment

The provisioner runs as a Docker container alongside the Coroot stack.
It communicates with Coroot's API over the Docker network (container-to-
container) and is exposed to the internet through the Caddy reverse proxy.

**Docker Compose service**:

```yaml
services:
  provisioner:
    image: ghcr.io/your-org/coroot-provisioner:latest
    restart: always
    expose:
      - "8090"
    environment:
      - COROOT_URL=http://coroot:8080
      - COROOT_ADMIN_USER=admin@example.com
      - COROOT_ADMIN_PASSWORD=${COROOT_ADMIN_PASSWORD}
      - PROVISIONER_SECRET=${PROVISIONER_SECRET}
      - PROVISIONER_AUTH_MODE=key_only
      - ALLOWED_KEYS_FILE=/data/allowed_keys
    volumes:
      - provisioner_data:/data
    depends_on:
      - coroot
```

**Caddy route** (in Caddyfile):

```
table.beerpub.dev {
    handle /provision {
        reverse_proxy provisioner:8090
    }
    handle {
        reverse_proxy coroot:8080
    }
}
```

**Environment variables**:

| Variable | Required | Description |
|----------|----------|-------------|
| `COROOT_URL` | REQUIRED | Internal URL of the Coroot instance. |
| `COROOT_ADMIN_USER` | REQUIRED | Admin user email for Coroot API authentication. |
| `COROOT_ADMIN_PASSWORD` | REQUIRED | Admin user password. Container-to-container only; never exposed externally. |
| `PROVISIONER_SECRET` | REQUIRED | Server-side secret for HMAC project name derivation (Section 8.4). At least 256 bits, hex-encoded. |
| `PROVISIONER_AUTH_MODE` | OPTIONAL | Authorization mode: `key_only` (default), `secret_only`, `key_and_secret`. |
| `PROVISIONER_MESH_SECRET` | CONDITIONAL | Shared secret for membership proof verification. REQUIRED if auth mode includes `secret_only` or `key_and_secret`. |
| `ALLOWED_KEYS_FILE` | OPTIONAL | Path to the Allowed Keys Registry file. Default: `/data/allowed_keys`. |
| `NONCE_TTL` | OPTIONAL | Nonce time-to-live in seconds. Default: `300`. |

### 11.2. Mesh Network Deployment

When the provisioner is deployed alongside a wgmesh network, it can
leverage the mesh for both transport and authorization.

```
                     ┌─────────────────────────────┐
                     │        Hetzner VPS           │
                     │       91.99.74.36            │
                     │                              │
  Internet ─────┐   │  ┌───────┐    ┌──────────┐   │
                 │   │  │ Caddy ├───>│Provisioner│  │
                 ├──>│  │ :443  │    │  :8090    │   │
                 │   │  │       ├───>│           │   │
                 │   │  │       │    └─────┬─────┘   │
                 │   │  │       │          │          │
                 │   │  │       ├───>┌─────┴─────┐   │
                 │   │  └───────┘    │  Coroot   │   │
  wgmesh ───────┤   │               │  :8080    │   │
  (WireGuard)   │   │               └───────────┘   │
                │   │                              │
                │   │  ┌─────────┐                 │
                └──>│  │ wg-mesh │                 │
                    │  │ :51820  │                 │
                    │  └─────────┘                 │
                    └─────────────────────────────┘

  ┌─────────────┐         ┌─────────────┐
  │ Mesh Node A │         │ Mesh Node B │
  │ (CI runner) │         │ (LLM agent) │
  │             │         │             │
  │ Curve25519  │         │ Ed25519     │
  │ pubkey      │         │ keypair     │
  │      +      │         │      +      │
  │ mesh secret │         │ mesh secret │
  └──────┬──────┘         └──────┬──────┘
         │    WireGuard tunnel    │
         └────────────────────────┘
```

In this deployment:

1. **Mesh nodes reach the provisioner** either through the public Caddy
   endpoint (over the internet with TLS) or through the WireGuard mesh
   tunnel (encrypted at the network layer). The protocol is safe in both
   cases.

2. **Authorization uses `secret_only` or `key_and_secret` mode.** Mesh
   nodes prove membership by computing a `membership_proof` HMAC from the
   mesh secret. This eliminates the need to manually enroll each node's
   key in the Allowed Keys Registry.

3. **Key derivation**: The provisioner's `PROVISIONER_MESH_SECRET` is
   derived from the wgmesh network secret via HKDF:

   ```
   provisioner_mesh_secret = HKDF-SHA256(
     ikm = wgmesh_network_secret,
     salt = "coroot-provision",
     info = "membership-hmac-key",
     length = 32
   )
   ```

   This ensures the provisioner secret is cryptographically bound to the
   mesh identity but cannot be reversed to recover the mesh secret.

## 12. Examples

### 12.1. Nonce Acquisition

```bash
$ curl -s -D- -X POST https://table.beerpub.dev/provision

HTTP/2 401
www-authenticate: EdProof realm="coroot-provision"
replay-nonce: dGhpcyBpcyBhIHRlc3Qgbm9uY2U
content-type: application/json

{"error":"nonce_required","detail":"POST again with Authorization: EdProof header including this nonce"}
```

### 12.2. SSH Signature Provisioning

```bash
#!/bin/bash
# Full provisioning flow using ssh-keygen

ENDPOINT="https://table.beerpub.dev/provision"
KEY="$HOME/.ssh/id_ed25519"
SERVICE="my-ci-pipeline"

# Step 1: Get nonce
NONCE=$(curl -s -D- -X POST "$ENDPOINT" 2>&1 \
  | grep -i 'replay-nonce:' \
  | tr -d '\r' \
  | awk '{print $2}')

# Step 2: Compute fingerprint
FINGERPRINT=$(ssh-keygen -lf "${KEY}.pub" -E sha256 | awk '{print $2}')

# Step 3: Construct and sign the canonical message
MESSAGE="${NONCE}${SERVICE}"
echo -n "$MESSAGE" > /tmp/provision-msg

ssh-keygen -Y sign -f "$KEY" -n coroot-provision /tmp/provision-msg

# Step 4: Extract raw signature (strip PEM headers, join lines)
SIGNATURE=$(sed '1d;$d' /tmp/provision-msg.sig | tr -d '\n')

# Step 5: Send authenticated request
curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: EdProof fingerprint=\"${FINGERPRINT}\", nonce=\"${NONCE}\", signature=\"${SIGNATURE}\", service_name=\"${SERVICE}\"" \
  -d "{\"service_name\": \"${SERVICE}\"}" | jq .
```

Expected output:

```json
{
  "project_id": "abc123",
  "project_name": "7f3a8c1e9d4b2f06a1c3e5d7f9b2a4c6",
  "api_key": "xK9mP2nQ7rS4tU6vW8yA1bC3dE5fG7hJ",
  "endpoints": {
    "traces": "https://table.beerpub.dev/v1/traces",
    "logs": "https://table.beerpub.dev/v1/logs",
    "metrics": "https://table.beerpub.dev/v1/metrics",
    "profiles": "https://table.beerpub.dev/v1/profiles",
    "prometheus_remote_write": "https://table.beerpub.dev/api/v1/write"
  },
  "key_binding": {
    "fingerprint": "SHA256:jE4x...",
    "service_name": "my-ci-pipeline"
  }
}
```

### 12.3. Raw Ed25519 Provisioning

**Go**:

```go
package main

import (
    "crypto/ed25519"
    "encoding/base64"
    "encoding/json"
    "fmt"
    "io"
    "net/http"
    "os"
    "strings"

    "golang.org/x/crypto/ssh"
)

func main() {
    endpoint := "https://table.beerpub.dev/provision"
    serviceName := "my-go-agent"

    // Load Ed25519 private key
    keyBytes, _ := os.ReadFile(os.Getenv("HOME") + "/.ssh/id_ed25519")
    signer, _ := ssh.ParseRawPrivateKey(keyBytes)
    edKey := signer.(ed25519.PrivateKey)
    pubKey := edKey.Public().(ed25519.PublicKey)

    // Compute fingerprint
    sshPub, _ := ssh.NewPublicKey(pubKey)
    fingerprint := ssh.FingerprintSHA256(sshPub)

    // Step 1: Get nonce
    resp, _ := http.Post(endpoint, "", nil)
    nonce := resp.Header.Get("Replay-Nonce")
    resp.Body.Close()

    // Step 2: Sign canonical message (raw Ed25519)
    message := []byte(nonce + serviceName)
    signature := ed25519.Sign(edKey, message)
    sigB64 := base64.StdEncoding.EncodeToString(signature)

    // Step 3: Send authenticated request
    body := fmt.Sprintf(`{"service_name":"%s"}`, serviceName)
    req, _ := http.NewRequest("POST", endpoint, strings.NewReader(body))
    req.Header.Set("Content-Type", "application/json")
    req.Header.Set("Authorization", fmt.Sprintf(
        `EdProof fingerprint="%s", nonce="%s", signature="%s", service_name="%s"`,
        fingerprint, nonce, sigB64, serviceName,
    ))

    resp, _ = http.DefaultClient.Do(req)
    defer resp.Body.Close()
    result, _ := io.ReadAll(resp.Body)

    var out map[string]interface{}
    json.Unmarshal(result, &out)
    formatted, _ := json.MarshalIndent(out, "", "  ")
    fmt.Println(string(formatted))
}
```

**Python**:

```python
import base64
import json
import subprocess
import requests

ENDPOINT = "https://table.beerpub.dev/provision"
SERVICE_NAME = "my-python-agent"
KEY_PATH = "~/.ssh/id_ed25519"

# Step 1: Get nonce
resp = requests.post(ENDPOINT)
nonce = resp.headers["Replay-Nonce"]

# Step 2: Compute fingerprint
result = subprocess.run(
    ["ssh-keygen", "-lf", f"{KEY_PATH}.pub", "-E", "sha256"],
    capture_output=True, text=True,
)
fingerprint = result.stdout.split()[1]

# Step 3: Sign with raw Ed25519
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from cryptography.hazmat.primitives.serialization import (
    load_ssh_private_key,
)
import os

with open(os.path.expanduser(KEY_PATH), "rb") as f:
    private_key = load_ssh_private_key(f.read(), password=None)

message = (nonce + SERVICE_NAME).encode("utf-8")
signature = private_key.sign(message)
sig_b64 = base64.b64encode(signature).decode("ascii")

# Step 4: Send authenticated request
resp = requests.post(
    ENDPOINT,
    headers={
        "Content-Type": "application/json",
        "Authorization": (
            f'EdProof fingerprint="{fingerprint}", '
            f'nonce="{nonce}", '
            f'signature="{sig_b64}", '
            f'service_name="{SERVICE_NAME}"'
        ),
    },
    json={"service_name": SERVICE_NAME},
)

print(json.dumps(resp.json(), indent=2))
```

### 12.4. wgmesh Node Provisioning

A wgmesh node provisioning an observability tenant using the shared-secret
membership model:

```bash
#!/bin/bash
# Provisioning from a wgmesh node using membership proof
#
# Prerequisites:
#   - Node has an Ed25519 key pair (used to derive WireGuard Curve25519 key)
#   - Node knows the mesh secret (WGMESH_SECRET env var)
#   - Provisioner is in secret_only or key_and_secret mode

ENDPOINT="https://table.beerpub.dev/provision"
KEY="$HOME/.ssh/id_ed25519"
SERVICE="mesh-node-$(hostname)"
MESH_SECRET="${WGMESH_SECRET}"

# Step 1: Get nonce
NONCE=$(curl -s -D- -X POST "$ENDPOINT" 2>&1 \
  | grep -i 'replay-nonce:' \
  | tr -d '\r' \
  | awk '{print $2}')

# Step 2: Compute fingerprint
FINGERPRINT=$(ssh-keygen -lf "${KEY}.pub" -E sha256 | awk '{print $2}')

# Step 3: Derive membership proof via HKDF + HMAC
# First derive the provisioner-specific key from mesh secret
PROVISION_KEY=$(echo -n "$MESH_SECRET" | openssl dgst -sha256 \
  -mac HMAC -macopt hexkey:"$(echo -n 'coroot-provision' | xxd -p)" \
  -binary | xxd -p)

# Then compute the membership proof
PROOF_INPUT="coroot-provision${FINGERPRINT}${NONCE}"
MEMBERSHIP_PROOF=$(echo -n "$PROOF_INPUT" | openssl dgst -sha256 \
  -mac HMAC -macopt hexkey:"$PROVISION_KEY" \
  -binary | base64)

# Step 4: Sign canonical message
MESSAGE="${NONCE}${SERVICE}"
echo -n "$MESSAGE" > /tmp/provision-msg
ssh-keygen -Y sign -f "$KEY" -n coroot-provision /tmp/provision-msg
SIGNATURE=$(sed '1d;$d' /tmp/provision-msg.sig | tr -d '\n')

# Step 5: Send authenticated request with membership proof
curl -s -X POST "$ENDPOINT" \
  -H "Content-Type: application/json" \
  -H "Authorization: EdProof fingerprint=\"${FINGERPRINT}\", nonce=\"${NONCE}\", signature=\"${SIGNATURE}\", service_name=\"${SERVICE}\", membership_proof=\"${MEMBERSHIP_PROOF}\"" \
  -d "{\"service_name\": \"${SERVICE}\", \"public_key\": \"$(cat ${KEY}.pub)\"}" | jq .

# Clean up
rm -f /tmp/provision-msg /tmp/provision-msg.sig
```

## 13. Security Considerations

### 13.1. Threat Model Summary

The following threat analysis uses the STRIDE framework:

| Threat | Category | Mitigation |
|--------|----------|------------|
| Attacker forges provisioning request | **Spoofing** | Ed25519 signature verification. Attacker cannot sign without the private key. |
| Attacker modifies request in transit | **Tampering** | TLS provides transport integrity. Signature binds nonce and service_name, preventing parameter substitution. |
| Attacker denies sending request | **Repudiation** | Ed25519 signatures provide non-repudiation. Server logs fingerprint and timestamp. |
| Attacker discovers other tenants' names | **Information Disclosure** | HMAC-derived project names with server-side secret. Enumeration requires the secret. |
| Attacker provisions unauthorized tenants | **Elevation of Privilege** | Allowed Keys Registry and/or membership proof. Only authorized keys can provision. |
| Attacker floods provisioning endpoint | **Denial of Service** | Rate limiting (429 responses). Nonce generation is cheap; signature verification is the expensive operation and only occurs for authenticated requests. |
| Attacker replays captured request | **Spoofing** | Single-use nonces with TTL. Each nonce is invalidated after use. |
| Attacker uses signature from another protocol | **Spoofing** | SSH sshsig namespace `coroot-provision` prevents cross-protocol replay. |
| Attacker extracts API key from response | **Information Disclosure** | TLS encrypts the response. API key is a bearer token; the `key_binding` field enables future key-bound enforcement (Phase 2). |
| Compromised key provisions rogue tenants | **Elevation of Privilege** | Key revocation via Allowed Keys Registry removal. Combined mode (`key_and_secret`) requires both key and membership proof. |
| Attacker brute-forces project names | **Information Disclosure** | HMAC-SHA256 with 128-bit truncation. Brute-force requires 2^128 operations without the server secret. |
| Timing attack on signature verification | **Information Disclosure** | Use constant-time comparison for all cryptographic operations. Standard Ed25519 libraries provide this. |

### 13.2. Nonce Replay and Timing

**Nonce storage**: The server MUST maintain a set of valid nonces. This
MAY be an in-memory map (acceptable for single-instance deployments) or a
shared store (required for multi-instance deployments). Nonces MUST be
invalidated immediately after use, regardless of whether the request
succeeded or failed.

**Nonce entropy**: Each nonce MUST contain at least 128 bits of
cryptographically secure randomness. The base64url-encoded nonce SHOULD
be at least 22 characters.

**Time-to-live**: Nonces SHOULD expire after 300 seconds (5 minutes).
This window balances usability (the requestor needs time to compute the
signature) against replay risk (shorter windows reduce the attack surface).

**Clock considerations**: The server's clock is authoritative. The
requestor does not need a synchronized clock — it simply echoes the nonce
received from the server.

**Concurrent requests**: The server MUST handle concurrent nonce requests
safely. Two requestors obtaining nonces simultaneously MUST receive
distinct values. The nonce store MUST use atomic operations for insertion
and deletion.

### 13.3. Key Compromise and Enumeration Resistance

**Key compromise scope**: If a requestor's Ed25519 private key is
compromised, the attacker can:

- Provision new tenants for that key (bounded by rate limiting)
- Re-provision existing tenants for that key (idempotency returns the
  same API key — no new resources created)
- Send telemetry to that key's projects (using the returned API key)

The attacker CANNOT:

- Provision tenants for other keys
- Discover other keys' project names (HMAC derivation prevents this)
- Access other keys' telemetry data
- Modify the Allowed Keys Registry

**Key revocation**: To revoke a compromised key, the operator removes it
from the Allowed Keys Registry. The provisioner reloads the registry
within 60 seconds (Section 6.1). Existing projects are NOT deleted — the
API key remains valid for telemetry data. To fully revoke access, the
operator MUST also rotate the project's API key via Coroot's admin
interface.

**Enumeration resistance**: Project names are derived via HMAC with a
server-side secret (Section 8.4). An attacker who knows a requestor's
fingerprint and service name but not the server secret cannot compute the
project name. The server MUST NOT include project names in error responses
or logs accessible to unauthorized parties.

### 13.4. Mesh Network Integration

When the provisioner operates within a wgmesh deployment, additional
security considerations apply:

**Shared secret scope**: The `PROVISIONER_MESH_SECRET` is derived from
the wgmesh network secret via HKDF. Compromise of the provisioner secret
does not compromise the mesh secret (HKDF is one-way), but compromise of
the mesh secret allows derivation of the provisioner secret.

**Defense in depth**: The `key_and_secret` authorization mode provides
the strongest security for mesh deployments. Even if the mesh secret
leaks (compromising the membership proof), the attacker still needs a
private key enrolled in the Allowed Keys Registry. Even if a private key
leaks, the attacker still needs the mesh secret.

**Transport security**: Mesh nodes connecting through the WireGuard tunnel
already have network-layer encryption. TLS on the provisioning endpoint
provides defense in depth. The provisioner SHOULD NOT reduce security
requirements for requests arriving over the mesh tunnel — the protocol
is designed to be safe regardless of transport.

**Node lifecycle**: When a node leaves the mesh (its Curve25519 key is
removed from the mesh), the operator SHOULD also remove the corresponding
Ed25519 key from the Allowed Keys Registry. Automated lifecycle binding
(where mesh membership and provisioning authorization are linked) is
discussed in Appendix A.5.

## 14. IANA Considerations

This document defines the `EdProof` HTTP authentication scheme. In a
real-world deployment, this scheme would be registered in the IANA "HTTP
Authentication Scheme Registry" per RFC 7235 Section 5.1:

| Field | Value |
|-------|-------|
| Authentication Scheme Name | EdProof |
| Reference | This document |
| Notes | Proof-of-possession scheme for Ed25519 keys with server-provided nonce binding |

As this protocol is currently scoped to private deployments, formal IANA
registration is deferred to a future version.

## 15. References

### 15.1. Normative References

**[RFC 2119]** Bradner, S., "Key words for use in RFCs to Indicate
Requirement Levels", BCP 14, RFC 2119, DOI 10.17487/RFC2119, March 1997.

**[RFC 7235]** Fielding, R., Ed. and J. Reschke, Ed., "Hypertext Transfer
Protocol (HTTP/1.1): Authentication", RFC 7235, DOI 10.17487/RFC7235,
June 2014.

**[RFC 8032]** Josefsson, S. and I. Liusvaara, "Edwards-Curve Digital
Signature Algorithm (EdDSA)", RFC 8032, DOI 10.17487/RFC8032, January
2017.

**[RFC 8174]** Leiba, B., "Ambiguity of Uppercase vs Lowercase in RFC
2119 Key Words", BCP 14, RFC 8174, DOI 10.17487/RFC8174, May 2017.

**[RFC 8555]** Barnes, R., Hoffman-Andrews, J., McCarney, D., and J.
Kasten, "Automatic Certificate Management Environment (ACME)", RFC 8555,
DOI 10.17487/RFC8555, March 2019.

### 15.2. Informative References

**[RFC 7748]** Langley, A., Hamburg, M., and S. Turner, "Elliptic Curves
for Security", RFC 7748, DOI 10.17487/RFC7748, January 2016.

**[RFC 9449]** Fett, D., Campbell, B., Bradley, J., Lodderstedt, T.,
Jones, M., and D. Waite, "OAuth 2.0 Demonstrating Proof of Possession
(DPoP)", RFC 9449, DOI 10.17487/RFC9449, September 2023.

**[RFC 9421]** Backman, A., Richer, J., and M. Sporny, "HTTP Message
Signatures", RFC 9421, DOI 10.17487/RFC9421, February 2024.

**[SSHSIG]** OpenSSH, "SSHSIG — SSH Signature Format",
https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.sshsig

**[COROOT]** Coroot, Inc., "Coroot — Full-Stack Observability",
https://github.com/coroot/coroot

**[SPIFFE]** SPIFFE Project, "Secure Production Identity Framework for
Everyone", https://spiffe.io/

**[WGMESH]** wgmesh Project, "WireGuard Mesh Network Builder",
https://github.com/atvirokodosprendimai/wgmesh

**[RFC 7800]** Jones, M., Bradley, J., and H. Tschofenig, "Proof-of-
Possession Key Semantics for JSON Web Tokens (JWTs)", RFC 7800,
DOI 10.17487/RFC7800, April 2016.

**[RFC 9334]** Birkholz, H., Thaler, D., Richardson, M., Smith, N., and
W. Pan, "Remote ATtestation procedureS (RATS) Architecture", RFC 9334,
DOI 10.17487/RFC9334, January 2023.

**[PRIVACYPASS]** Davidson, A., Iyengar, J., and C. Wood, "Privacy Pass
Architecture", Internet-Draft, https://www.ietf.org/archive/id/draft-ietf-privacypass-architecture-16.html

---

## Appendix A. Ecosystem: Mesh Network Integration

This appendix describes how the provisioning protocol integrates with the
wgmesh WireGuard mesh network builder. While the protocol is designed to
operate independently, the two systems share structural parallels and can
be tightly integrated in deployments where both are present.

### A.1. Structural Parallel

wgmesh and this provisioning protocol solve the same fundamental problem
at different layers of the stack:

| Aspect | wgmesh (Network Layer) | Provisioning Protocol (Service Layer) |
|--------|------------------------|---------------------------------------|
| Core question | "How does an unknown node prove it belongs to the mesh?" | "How does an unknown agent prove it deserves an observability tenant?" |
| Identity primitive | Curve25519 public key | Ed25519 public key |
| Group membership | Shared secret (HKDF-derived) | Allowed Keys Registry and/or shared secret |
| Authorization outcome | WireGuard tunnel + mesh IP | Coroot project + API key |
| Transport | UDP (WireGuard) | HTTPS |
| Discovery | DHT → gossip → LAN multicast | Single well-known endpoint |

Both systems derive their security from the same mathematical foundation:
the Curve25519/Edwards25519 elliptic curve. A single key pair can serve
both systems (see Section A.2).

### A.2. Identity Bridging

Ed25519 and Curve25519 are birationally equivalent curves. A key pair
generated for one can be converted to the other:

```
Ed25519 private key (32 bytes)
    │
    ├──> Ed25519 public key (32 bytes)     → used by provisioning protocol
    │
    └──> Curve25519 private key (32 bytes)
             │
             └──> Curve25519 public key (32 bytes) → used by WireGuard/wgmesh
```

The recommended approach for dual-use keys:

1. Generate an Ed25519 key pair (e.g., `ssh-keygen -t ed25519`)
2. Derive the Curve25519 key for WireGuard (safe, well-defined direction)
3. Use the Ed25519 key for provisioning and the Curve25519 key for mesh

This is the **safe direction**. Going from Curve25519 → Ed25519 is
possible but introduces a sign ambiguity that complicates verification.

Libraries that support this conversion:

- **Go**: `filippo.io/edwards25519` — `Point.BytesMontgomery()`
- **Rust**: `curve25519-dalek` — `MontgomeryPoint::to_edwards()`
- **Python**: `pynacl` — `SigningKey` ↔ `PrivateKey` conversion
- **C**: `libsodium` — `crypto_sign_ed25519_pk_to_curve25519()`

### A.3. Deployment Models

Three deployment models are possible when wgmesh and the provisioning
protocol coexist:

**Model 1: Independent (Parallel)**

The mesh and provisioner operate independently. Mesh nodes have Curve25519
keys for WireGuard and separate Ed25519 keys for provisioning. No
cryptographic link between the two. Authorization uses `key_only` mode.

- Pros: Simplest. No coupling between systems.
- Cons: Two key sets to manage. Mesh membership doesn't imply provisioning
  authorization.

**Model 2: Shared Identity (Bridged)**

Mesh nodes generate Ed25519 keys and derive Curve25519 keys for WireGuard.
The same key pair serves both systems. Authorization uses `key_only` mode
with the Ed25519 keys enrolled in the Allowed Keys Registry.

- Pros: Single key pair. Mesh join and provisioning use the same identity.
- Cons: Key lifecycle is coupled — revoking the mesh key means revoking
  provisioning access and vice versa.

**Model 3: Shared Secret (Federated)**

Mesh nodes use the mesh secret to compute a `membership_proof` for
provisioning. Authorization uses `secret_only` or `key_and_secret` mode.
No key enrollment needed — any node that knows the mesh secret is
implicitly authorized.

- Pros: Zero enrollment friction. New mesh nodes can self-provision
  immediately.
- Cons: Mesh secret compromise grants provisioning access to anyone.
  Cannot revoke individual nodes without rotating the mesh secret.

### A.4. Secret Derivation Chain

In Model 3, the provisioner's HMAC key for membership verification is
derived from the wgmesh network secret through a chain of HKDF
derivations. This mirrors wgmesh's own internal derivation pattern:

```
wgmesh network secret (user-provided, >= 256 bits)
    │
    ├──> HKDF(salt="wgmesh-dht-v1",     info="network-id")     → DHT network ID
    ├──> HKDF(salt="wgmesh-gossip-v1",   info="encryption-key") → Gossip AES-256-GCM key
    ├──> HKDF(salt="wgmesh-wg-v1",       info="preshared-key")  → WireGuard PSK
    ├──> HKDF(salt="wgmesh-subnet-v1",   info="mesh-subnet")    → Mesh subnet
    │
    └──> HKDF(salt="coroot-provision",   info="membership-hmac-key") → Provisioner HMAC key
                                                                         (this protocol)
```

The provisioner HMAC key is a new leaf in wgmesh's existing derivation
tree. It is cryptographically independent of the other derived keys: knowing
the provisioner HMAC key reveals nothing about the DHT network ID, gossip
key, WireGuard PSK, or mesh subnet.

The provisioner MAY derive this key at startup from the raw mesh secret,
or an operator MAY pre-derive it and provide it via the
`PROVISIONER_MESH_SECRET` environment variable. The former is more
convenient; the latter avoids storing the raw mesh secret on the
provisioner host.

### A.5. Lifecycle Binding

In tightly integrated deployments (Models 2 and 3), the lifecycle of a
mesh node and its observability tenant can be bound:

**Node joins mesh** → Node provisions observability tenant → Node sends
telemetry → Node leaves mesh → Operator revokes provisioning access →
(Optionally) Operator deletes Coroot project

The protocol does not automate the "leaves mesh → revokes access" step.
This is deliberate: the provisioning protocol defines how authorization
is checked at request time, not how authorization state is managed. An
operator MAY implement lifecycle binding through:

1. **Webhook**: wgmesh emits an event when a node leaves. A webhook
   handler removes the key from the Allowed Keys Registry.

2. **Periodic sync**: A cron job compares the set of active mesh nodes
   (from wgmesh's peer list) against the Allowed Keys Registry and removes
   stale entries.

3. **Expiring authorization**: The Allowed Keys Registry entry includes a
   TTL. The node must re-enroll periodically. This is NOT defined in this
   protocol version but is identified as future work (Section 13.4 note).

Automated lifecycle binding is deferred to a future version of this
protocol, pending operational experience with the manual workflow.

---

## Appendix B. Formal Verification

This protocol has a machine-checkable formal model in the Tamarin prover.
The model is located at `formal/provision.spthy` in this repository.

Tamarin is a security protocol verification tool that operates in the
symbolic model (Dolev-Yao adversary). It uses multiset rewriting rules
to model protocol steps and first-order logic to state security
properties. Proofs are either found automatically or constructed
interactively using Tamarin's built-in proof strategy.

### B.1. Model Overview

The Tamarin model encodes the protocol's two-phase flow as multiset
rewriting rules:

| Rule | Protocol Step | Section |
|------|---------------|---------|
| `Provisioner_Setup` | Server generates long-term HMAC secret | 8.4 |
| `Agent_KeyGen` | Agent generates Ed25519 key pair; public key enrolled | 6.1 |
| `Requestor_NonceRequest` | Requestor sends unauthenticated POST | 8.1 |
| `Provisioner_NonceResponse` | Provisioner returns fresh nonce | 8.1 |
| `Requestor_AuthRequest` | Requestor signs nonce+service_name, sends EdProof | 8.2 |
| `Provisioner_ProcessRequest` | Provisioner verifies signature, provisions tenant | 8.2 |
| `Requestor_ReceiveResponse` | Requestor receives API key and project name | 9.2 |

Cryptographic primitives (Ed25519 signatures, HMAC-SHA256) are treated
as ideal — the model does not reason about their internal construction
but assumes they satisfy standard security definitions (existential
unforgeability under chosen-message attack for signatures, PRF security
for HMAC).

### B.2. Adversary Model

The model uses the standard Dolev-Yao adversary:

- The attacker controls the network completely: they can intercept,
  inject, replay, modify, and drop any message.
- The attacker can compute any function available to honest parties
  (sign, verify, hmac, hash) given the necessary inputs.
- The attacker **cannot** invert one-way functions, forge signatures
  without the private key, or break HMAC without the key.

This is strictly stronger than a passive eavesdropper. If the protocol
is secure under Dolev-Yao, it is secure against any realistic network
attacker.

TLS is modeled explicitly where needed (the API key response is
encrypted to the requestor) rather than assumed globally. This allows
the model to distinguish which properties depend on transport security
and which hold regardless.

### B.3. Security Lemmas

The model verifies seven properties:

**Lemma 1 — Authentication (Injective Agreement)**

If the provisioner accepts a request claiming to be from public key `pkA`
with nonce `N` and service name `S`, then the holder of `pkA` actually
sent a request with that exact `N` and `S`, and this mapping is
one-to-one (each acceptance corresponds to a unique send).

*Rules out*: forgery, parameter substitution, replay.

```
ProvisionerAccepted(pkA, N, S, ...) @ #i
  ==> RequestorSent(pkA, N, S) @ #j & #j < #i     // authenticity
      & unique(#i)                                   // injectivity
```

**Lemma 2 — Nonce Single-Use**

A nonce is consumed at most once. Two `NonceUsed` events for the same
nonce must be the same event.

*Structural guarantee*: enforced by Tamarin's linear fact semantics.
The `NonceStore(nonce)` fact is linear (not persistent) — it is created
once and consumed once. The multiset rewriting engine makes it
impossible for two rules to consume the same linear fact.

```
NonceUsed(N) @ #i & NonceUsed(N) @ #j ==> #i = #j
```

**Lemma 3 — Nonce Freshness**

Every nonce used in an accepted request was previously generated by the
provisioner. The attacker cannot invent valid nonces.

*Follows from*: `NonceStore` is only created in `Provisioner_NonceResponse`.

```
NonceUsed(N) @ #i ==> NonceGenerated(N) @ #j & #j < #i
```

**Lemma 4 — API Key Secrecy**

The attacker cannot learn an API key. This requires the secure channel
model (TLS on the response).

*Follows from*: the API key is a fresh value (`Fr(~api_key)`) that
only appears inside an encrypted term on the network.

```
SecretAPIKey(K, pkA, S) @ #i ==> not K(K)
```

**Lemma 5 — Tenant Binding**

If two tenants share the same project name, they must have been created
for the same public key and service name. This captures the collision
resistance of HMAC-SHA256 project name derivation (Section 8.4).

```
ProjectBound(P, pkA, S) @ #i & ProjectBound(P, pkB, S2) @ #j
  ==> pkA = pkB & S = S2
```

**Lemma 6 — Requestor-Provisioner Agreement**

If a requestor believes it received API key `K` for service `S`, then
the provisioner actually issued `K` for that key and service. Rules out
the attacker injecting a fake provisioning response.

```
RequestorReceived(pkA, N, S, K, P) @ #i
  ==> ProvisionerAccepted(pkA, N, S, K, P) @ #j & #j < #i
```

**Lemma 7 — Executability (Sanity Check)**

There exists a valid trace where the protocol completes successfully.
This ensures the model is not vacuously true (i.e., the rules are not
over-constrained to the point where no execution is possible).

```
exists-trace: RequestorReceived(pkA, N, S, K, P) @ #i
```

### B.4. Structural Guarantees

Some properties are guaranteed by the structure of the Tamarin model
itself, without requiring explicit lemmas:

**Nonce uniqueness at generation**: Each nonce is generated using
Tamarin's `Fr()` (fresh) fact, which produces globally unique values.
Two `Fr(~n)` facts never produce the same `~n`.

**Key isolation**: The private key `~sk` is generated by `Fr()` and
never placed on the network (`Out()`). Only `pk(~sk)` is output. The
Dolev-Yao attacker cannot derive `~sk` from `pk(~sk)`.

**Server secret isolation**: The `~server_secret` is generated by `Fr()`
and stored in a persistent fact `!ServerSecret()`. It is never output
to the network. HMAC values derived from it do not reveal it (PRF
assumption).

### B.5. Running the Verification

Install Tamarin (requires Haskell/GHC):

```bash
# macOS
brew install tamarin-prover

# Ubuntu/Debian
sudo apt-get install tamarin-prover

# From source
git clone https://github.com/tamarin-prover/tamarin-prover.git
cd tamarin-prover && stack install
```

Verify all lemmas:

```bash
tamarin-prover --prove formal/provision.spthy
```

Verified output (Tamarin 1.11.0, Maude 3.5, 2026-02-21):

```
analyzed: formal/provision.spthy

  processing time: 0.54s

  authentication_injective (all-traces): verified (10 steps)
  nonce_single_use         (all-traces): verified (14 steps)
  nonce_freshness          (all-traces): verified (3 steps)
  api_key_secrecy          (all-traces): verified (7 steps)
  tenant_binding           (all-traces): verified (2 steps)
  requestor_agreement      (all-traces): verified (5 steps)
  executability            (exists-trace): verified (8 steps)
```

Interactive exploration (opens web UI on `http://localhost:3001`):

```bash
tamarin-prover interactive formal/provision.spthy
```

The interactive mode allows exploring attack traces for failed lemmas,
inspecting proof trees, and understanding the protocol's state space.

---

*End of document.*
