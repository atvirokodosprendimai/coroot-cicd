# EdProof: A Layered Identity Protocol for Humans and Machines

```
Status:       Draft
Version:      0.1
Authors:      oldroot
Date:         2026-02-22
Supersedes:   RFC-PROVISIONING.md (v0.3)
```

## Abstract

EdProof is a layered identity protocol built on Ed25519 public key
cryptography. It defines how any entity — human or machine — proves
possession of a private key, receives a long-lived portable credential,
and presents that credential to verifiers who apply their own policy
independently. The protocol is indifferent to scale: it can run a
country, a football club, or a single autonomous agent. It is indifferent
to the physical backing of the key: file on disk, hardware token, TPM,
or threshold scheme. It is indifferent to what the verifier does with
the proof.

The protocol has five cleanly separated layers: proof, credential,
registry, policy, and backing. Each layer is independent and
interchangeable. No layer has authority over another.

This document specifies all five layers. A formally verified Tamarin
model covers the attestation exchange (Layers 1 and 2).

---

## Table of Contents

- [1. Introduction](#1-introduction)
  - [1.1. The Passport Model](#11-the-passport-model)
  - [1.2. Design Principles](#12-design-principles)
  - [1.3. Relationship to Existing Work](#13-relationship-to-existing-work)
- [2. Terminology](#2-terminology)
- [3. Architecture: Five Layers](#3-architecture-five-layers)
- [4. Layer 1 — Proof](#4-layer-1--proof)
  - [4.1. Key Generation](#41-key-generation)
  - [4.2. Attestation Exchange](#42-attestation-exchange)
  - [4.3. The EdProof HTTP Scheme](#43-the-edproof-http-scheme)
  - [4.4. SPIRE Integration](#44-spire-integration)
- [5. Layer 2 — Credential](#5-layer-2--credential)
  - [5.1. Credential Format](#51-credential-format)
  - [5.2. Lifetime and Offline Validity](#52-lifetime-and-offline-validity)
  - [5.3. The Bootstrap Ceremony](#53-the-bootstrap-ceremony)
- [6. Layer 3 — Registry](#6-layer-3--registry)
  - [6.1. Registry as Dataset](#61-registry-as-dataset)
  - [6.2. Registry Formats](#62-registry-formats)
  - [6.3. Consulting the Registry](#63-consulting-the-registry)
- [7. Layer 4 — Policy](#7-layer-4--policy)
  - [7.1. The Verifier Owns the Decision](#71-the-verifier-owns-the-decision)
  - [7.2. Policy Independence](#72-policy-independence)
  - [7.3. Federation](#73-federation)
- [8. Layer 5 — Backing](#8-layer-5--backing)
  - [8.1. Backing Transparency](#81-backing-transparency)
  - [8.2. Backing as Policy Input](#82-backing-as-policy-input)
- [9. Security Considerations](#9-security-considerations)
  - [9.1. Threat Model](#91-threat-model)
  - [9.2. Credential Lifetime vs Revocation](#92-credential-lifetime-vs-revocation)
  - [9.3. Registry Integrity](#93-registry-integrity)
- [10. Formal Verification](#10-formal-verification)
- [11. Relationship to Other Standards](#11-relationship-to-other-standards)
- [12. References](#12-references)
- [Appendix A. Supersession of RFC-PROVISIONING.md](#appendix-a-supersession-of-rfc-provisioningmd)
- [Appendix B. Coroot Backend Profile](#appendix-b-coroot-backend-profile)

---

## 1. Introduction

### 1.1. The Passport Model

A passport is a self-contained, cryptographically verifiable claim of
identity. It is issued once at a ceremony. It is carried by the holder.
It is verified locally by the border agent against the document's own
signatures — the issuer is not contacted. The border agent may consult
independent information sources (watchlists, visa records, intelligence)
but is not obligated to. The agent makes the final access decision. None
of this depends on the passport being recently used — a passport issued
ten years ago and carried unused for eight is as valid as one used
yesterday.

EdProof is this model, applied to digital identity for both humans and
machines.

The key insight that existing digital identity systems miss: **identity
proof, credential, policy information, and access decision are four
separate things**. Most systems conflate them. Short-lived tokens force
the issuer into every access decision. OAuth refresh cycles make the
authorization server a mandatory participant in every session. SVID
default TTLs turn a document into a heartbeat protocol.

EdProof separates them by design.

### 1.2. Design Principles

**1. Ceremony once, verify forever.**
The attestation exchange happens once at entity birth. The resulting
credential is long-lived. The issuer is not involved in subsequent
verifications.

**2. The credential is information, not a permission slip.**
A credential proves who you are. It does not grant access. The verifier
grants or denies access using its own policy. The credential is one
input to that policy, not the policy itself.

**3. Registries are datasets, not authorities.**
A registry — a list of known keys, banned keys, trusted keys — is
information a verifier may consult. Consulting is optional. No registry
has jurisdiction over a verifier's decision. A verifier may consult
zero registries, one, or many.

**4. The protocol is scale-neutral.**
The same protocol that provisions an observability tenant for an LLM
agent can, in principle, issue a national identity document. The
differences lie entirely in the registry, policy, and backing layers —
not in the protocol.

**5. Key backing is orthogonal.**
The protocol proves possession of a private key. What physically protects
that key — a file, a hardware token, a TPM, a threshold scheme — is a
separate concern. The protocol is indifferent to backing. Verifiers may
choose to care about it as a policy input.

**6. Peers, not hierarchy.**
Any entity that holds a key can be both prover and verifier
simultaneously. A node that received a credential can issue credentials
to others. There is no mandatory central authority.

### 1.3. Relationship to Existing Work

**SPIFFE/SPIRE**: EdProof is compatible with SPIFFE. The attestation
exchange (Layer 1) can be implemented as a SPIRE node attestor plugin,
with the SPIFFE SVID as the credential (Layer 2). EdProof specifies
what SPIRE leaves open: SSH-key-native attestation without
infrastructure dependency (no cloud metadata, no TPM, no join token).

**SSH Certificates**: OpenSSH certificates are a valid EdProof credential
format. They are long-lived, offline-verifiable, and widely tooled.
The EdProof attestation exchange can be used to authorize SSH certificate
issuance.

**W3C DID**: The SPIFFE ID produced by EdProof attestation
(`spiffe://domain/spire/agent/sshkey/SHA256:...`) is structurally a
decentralized identifier backed by a cryptographic key — equivalent to
`did:key`. EdProof provides the attestation ceremony that DID systems
typically leave to the application.

**RFC-PROVISIONING.md (superseded)**: The Coroot provisioning protocol
defined in RFC-PROVISIONING.md v0.3 is a specific application of
EdProof — the Coroot observability backend consuming an EdProof
credential. That document is superseded by this one. The Coroot-specific
behavior is now defined in Appendix B.

---

## 2. Terminology

The key words "MUST", "MUST NOT", "REQUIRED", "SHALL", "SHALL NOT",
"SHOULD", "SHOULD NOT", "RECOMMENDED", "NOT RECOMMENDED", "MAY", and
"OPTIONAL" in this document are to be interpreted as described in
BCP 14 [RFC 2119] [RFC 8174].

**Entity**: Any participant in the EdProof system — human, autonomous
agent, CI/CD pipeline, IoT device, mesh network node, or any other
party capable of holding an Ed25519 private key.

**Prover**: An entity presenting proof of key possession. An entity
may be a prover in one context and a verifier in another, or both
simultaneously.

**Verifier**: An entity validating a proof or credential and making an
access decision.

**Credential**: A signed document asserting the entity's identity,
issued at the attestation ceremony. Carried by the entity. Verified
locally by the verifier.

**Registry**: An information source a verifier may consult when making
an access decision. Not authoritative. Not mandatory.

**Policy**: The verifier's own rules for making access decisions. The
verifier owns policy entirely. No external party has authority over it.

**Backing**: The physical or logical mechanism protecting the entity's
private key. Orthogonal to the protocol.

**Ceremony**: The one-time attestation exchange between prover and
issuer that results in a credential.

**Trust Domain**: A namespace for SPIFFE IDs. An organization or
deployment that operates its own SPIRE Server. Multiple trust domains
may federate.

---

## 3. Architecture: Five Layers

```
┌─────────────────────────────────────────────────────────────┐
│  Layer 5 — Backing                                          │
│  What physically protects the private key                   │
│  File · YubiKey · TPM · Secure Enclave · Threshold · Chip  │
│  Orthogonal to all layers above. Protocol does not see it.  │
└──────────────────────────────┬──────────────────────────────┘
                               │ produces
┌──────────────────────────────▼──────────────────────────────┐
│  Layer 1 — Proof                                            │
│  Ed25519 challenge-response attestation exchange            │
│  Proves possession of private key. Math. Timeless.          │
│  Formally verified (Tamarin). Offline-capable.              │
└──────────────────────────────┬──────────────────────────────┘
                               │ authorizes issuance of
┌──────────────────────────────▼──────────────────────────────┐
│  Layer 2 — Credential                                       │
│  Signed document. Carried by entity. Long-lived.            │
│  SPIFFE SVID · SSH Certificate · Custom format              │
│  Verified locally. Issuer not contacted at verify time.     │
└──────────────────────────────┬──────────────────────────────┘
                               │ presented to verifier, who may consult
┌──────────────────────────────▼──────────────────────────────┐
│  Layer 3 — Registry                                         │
│  Dataset. Optional. Not authoritative.                      │
│  Allowed keys · Banned keys · Reputation feeds · Anything   │
│  Verifier chooses which registries to consult, if any.      │
└──────────────────────────────┬──────────────────────────────┘
                               │ informs
┌──────────────────────────────▼──────────────────────────────┐
│  Layer 4 — Policy                                           │
│  The verifier's judgment. Sovereign. Not delegatable.       │
│  Consults credential + zero or more registries.             │
│  Makes the access decision. Issues the downstream           │
│  credential (API key, token, permit, entry stamp).          │
└─────────────────────────────────────────────────────────────┘
```

Each layer is independently replaceable. A deployment may:

- Use any key backing (Layer 5) without changing the attestation protocol
- Use any credential format (Layer 2) without changing attestation
- Consult any registry (Layer 3) without changing credential format
- Apply any policy (Layer 4) without changing registries

The layers interact only through well-defined interfaces:
- Layer 5 → Layer 1: a signing oracle
- Layer 1 → Layer 2: an attestation result authorizing credential issuance
- Layer 2 → Layer 3/4: a credential presented for evaluation
- Layer 3 → Layer 4: information (not a decision)

---

## 4. Layer 1 — Proof

### 4.1. Key Generation

Every entity generates an Ed25519 key pair. The private key never
leaves the entity's control (modulo the backing layer). The public key
is the entity's stable identifier.

```bash
ssh-keygen -t ed25519 -f identity -C "entity@context"
```

The fingerprint of the public key — `SHA256:<base64>` in OpenSSH
format — is the entity's stable, globally unique identifier within
the EdProof system.

### 4.2. Attestation Exchange

The attestation exchange is a three-message challenge-response protocol:

```
Prover                                    Issuer
  │                                          │
  │── (1) payload ──────────────────────────►│
  │     { fingerprint, public_key }          │
  │                                          │── generate nonce
  │◄─────────────────────────── (2) challenge│
  │     { nonce }                            │
  │                                          │
  │── sign(nonce, namespace="edproof") ──    │
  │                                          │
  │── (3) challenge_response ───────────────►│
  │     { signature }                        │── verify signature
  │                                          │── apply policy
  │◄───────────────────────────── credential │
```

**Message 1 — Payload**

The prover sends its public key fingerprint and public key:

```json
{
  "fingerprint": "SHA256:jE4x...",
  "public_key": "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA..."
}
```

**Message 2 — Challenge**

The issuer generates a cryptographically random nonce (minimum 128 bits,
base64url-encoded) and returns it. The nonce MUST be single-use and
MUST NOT be reused.

```json
{ "nonce": "dGhpcyBpcyBhIHRlc3Qgbm9uY2U" }
```

**Message 3 — Challenge Response**

The prover signs the nonce using the SSH `sshsig` wire format with
namespace `edproof`:

```bash
echo -n "${NONCE}" > /tmp/msg
ssh-keygen -Y sign -f identity -n edproof /tmp/msg
```

The signature is base64-encoded and returned:

```json
{ "signature": "AAAAB3NzaC1lZDI1NTE5..." }
```

The issuer verifies the signature. If valid, it issues a credential
(Layer 2). The nonce is consumed and invalidated regardless of outcome.

### 4.3. The EdProof HTTP Scheme

When the attestation exchange is carried over HTTP, the `EdProof`
authentication scheme is used (defined in RFC-PROVISIONING.md v0.3,
inherited here):

```
Authorization: EdProof fingerprint="SHA256:...",
  nonce="...",
  signature="..."
```

The nonce acquisition uses the `Replay-Nonce` header pattern from
RFC 8555 (ACME) and RFC 9449 (DPoP):

```http
HTTP/1.1 401 Unauthorized
WWW-Authenticate: EdProof realm="edproof"
Replay-Nonce: <nonce>
```

### 4.4. SPIRE Integration

The attestation exchange maps directly onto the SPIRE node attestor
plugin interface. The prover is the SPIRE Agent (running the
`sshkey` plugin). The issuer is the SPIRE Server (running the
`sshkey` plugin).

```
SPIRE Agent plugin          SPIRE Server plugin
  AidAttestation()    →→→     Attest()
  payload: {fingerprint, pubkey}
  ← challenge: {nonce}
  challenge_response: {signature}
  → AgentAttributes:
      spiffe_id: spiffe://<domain>/spire/agent/sshkey/SHA256:<fp>
      selectors: [{ type: "sshkey", value: "fingerprint:SHA256:..." }]
```

The resulting SPIFFE ID encodes the fingerprint as a path component,
making it stable, unique, and inspectable by policy engines.

---

## 5. Layer 2 — Credential

### 5.1. Credential Format

EdProof is credential-format-agnostic. Any signed document that:

- Binds the entity's public key or fingerprint to an identity assertion
- Is verifiable offline against a known trust anchor
- Has a human-readable or machine-readable lifetime assertion

is a valid EdProof credential. Recommended formats:

**SPIFFE X.509 SVID** — issued by SPIRE after successful attestation.
Standard X.509 certificate with SPIFFE ID in the SAN. Verifiable
against the trust bundle. Suitable for mTLS.

**SSH Certificate** — issued by an SSH CA. Long-lived. Offline-verifiable.
Widely tooled. Suitable for SSH access, Git signing, and general-purpose
identity assertion.

```bash
ssh-keygen -s ca_key -I "entity-identity" \
  -n principals -V +3650d identity.pub
```

**Custom JSON document** — signed with the CA's Ed25519 key. Suitable
for lightweight deployments that do not need X.509 or SSH infrastructure.

### 5.2. Lifetime and Offline Validity

The credential SHOULD have a long lifetime. The recommended minimum is
one year. Ten years is appropriate for stable entities (humans, long-lived
infrastructure).

**Short credential lifetimes are an anti-pattern in EdProof.**

A short lifetime transforms the credential from a document into a
session token and reintroduces the online dependency that EdProof is
designed to eliminate. If the issuer must be contacted to renew the
credential, the issuer becomes a mandatory participant in every access
decision — which is exactly what the passport model avoids.

Revocation MUST NOT be implemented via credential expiry. Revocation
is a Layer 3/4 concern: the verifier checks a registry (if it chooses)
and applies policy. A valid credential presented by a revoked key is
rejected by policy, not by expiry. A dormant credential — one not
presented for years — is as valid as one presented yesterday.

**Credential dormancy is not invalidation.**

An entity that was attested, received a credential, and then was inactive
for eight years presents the same credential on return. The credential
is evaluated against current registries and policy. Its age and dormancy
are irrelevant to its cryptographic validity.

### 5.3. The Bootstrap Ceremony

Attestation and credential issuance happen once per entity lifetime,
or when the entity's key changes. This is the bootstrap ceremony.

The bootstrap ceremony is a point-in-time event, not a running service.
Implementations MAY:

- Run a SPIRE Server permanently (for large deployments with many
  entities being born continuously)
- Run an issuer service on-demand and tear it down after the ceremony
- Implement a CLI tool that performs attestation and issues a credential
  in a single invocation
- Use a GitHub Action or CI step as the ceremony for deployed agents

The ceremony infrastructure does not need to be highly available. It
needs to be available at entity birth. An entity with a valid credential
does not require issuer availability for any subsequent operation.

---

## 6. Layer 3 — Registry

### 6.1. Registry as Dataset

A registry is a source of information about keys. It is not an access
control system. It does not grant or deny access. It provides data that
a verifier may use when forming its policy decision.

A registry MAY contain:

```json
{
  "fingerprint": "SHA256:jE4x...",
  "enrolled_at": "2026-02-22T09:00:00Z",
  "enrolled_by": "operator@example.com",
  "tags": ["ci-pipeline", "trusted"],
  "notes": "Jenkins agent for repo foo",
  "last_seen": "2026-02-22T09:41:00Z"
}
```

Or it MAY be as simple as a flat file of public keys in OpenSSH
`authorized_keys` format — one key per line, comments allowed.

The schema is implementation-defined. EdProof does not mandate a
registry format or schema.

### 6.2. Registry Formats

Implementations SHOULD support at minimum:

- **OpenSSH `authorized_keys` format** — one public key per line.
  Compatible with `ssh-keygen -Y find-principals`. Widely understood.
- **JSON** — structured, extensible, suitable for programmatic access.
- **Git repository** — a registry stored in a Git repo benefits from
  audit history, pull request review, and distributed access.

### 6.3. Consulting the Registry

A verifier MAY:

- Consult zero registries (trust the credential alone)
- Consult one registry (typical case)
- Consult multiple registries and combine results
- Consult different registries for different entity types
- Cache registry data and refresh on a schedule
- Refuse to consult a registry that is unavailable (fail open or closed
  per local policy)

A verifier MUST NOT treat registry unavailability as a credential
failure. The credential is valid regardless of whether the registry
can be reached. Registry unavailability is a policy input, not a
cryptographic failure.

The registry lookup MUST return all available information about the
key. It MUST NOT return a boolean. The verifier's policy layer makes
the boolean decision.

---

## 7. Layer 4 — Policy

### 7.1. The Verifier Owns the Decision

The verifier makes the access decision. No external party — not the
issuer, not the registry operator, not the EdProof protocol — has
authority over this decision.

The credential proves identity. The registry provides context. The
verifier decides what both mean.

A verifier MAY:

- Accept any entity with a valid credential signature, regardless of
  registry status
- Reject any entity not found in its registry
- Accept entities on a banned list if local policy overrides it
  (e.g. diplomatic immunity)
- Apply time-based, context-based, or risk-based rules
- Issue a downstream credential (API key, access token, entry permit)
  as the outcome of a positive decision

### 7.2. Policy Independence

Policy is sovereign to each verifier. No verifier's policy has authority
over another's.

A football club's admission policy does not govern a country's border
policy. A country's border policy does not govern a private club's
admission policy. Both use EdProof credentials. Both consult their own
registries. Both make their own decisions.

Verifiers operating in different trust domains MAY establish explicit
trust relationships (federation) but are not required to. The absence
of a trust relationship simply means each party operates independently.

### 7.3. Federation

Two verifiers MAY establish federation: a formal agreement to accept
each other's credentials as evidence (not necessarily as sufficient
proof) of identity.

Federation in EdProof follows the SPIFFE federation model: each trust
domain publishes a bundle endpoint containing its CA certificates.
Federated trust domains fetch each other's bundles and can validate
credentials from the partner domain.

Federation is bilateral, explicit, and revocable. There is no global
root of trust. A credential from an unknown trust domain is simply
unknown — not trusted and not distrusted. The verifier's policy decides
what to do with it.

---

## 8. Layer 5 — Backing

### 8.1. Backing Transparency

The backing layer determines how well the private key is protected
against extraction or copying. The protocol does not observe the backing
layer. From the protocol's perspective, a signature from a key on disk
and a signature from a key in a hardware security module are identical.

Common backing mechanisms:

| Backing | Extractable | Suitable for |
|---------|-------------|--------------|
| File on disk | Yes | Development, low-risk agents |
| SSH agent | Session-scoped | Interactive human use |
| YubiKey / FIDO2 | No (PIN required) | High-assurance human identity |
| TPM | No | Server and device identity |
| Secure Enclave | No | Mobile and embedded |
| Cloud KMS | No (API-mediated) | Cloud-native agents |
| Threshold (k-of-n) | Only with collusion | High-value long-lived keys |
| Physical chip on card | Physically hard | Physical access cards |

### 8.2. Backing as Policy Input

A verifier MAY choose to care about backing. This is expressed as
policy (Layer 4), not as protocol.

If an issuer wishes to attest the backing type alongside the key, it
MAY include backing metadata in the credential. This is optional and
implementation-defined.

Example: a SPIRE server plugin that accepts only TPM-backed keys would
validate TPM attestation evidence in the payload before issuing an SVID.
This does not change the EdProof protocol — it adds a Layer 5 assertion
to the Layer 1 exchange.

---

## 9. Security Considerations

### 9.1. Threat Model

The attestation exchange (Layer 1) operates under the Dolev-Yao
adversary model: the attacker controls the network completely and can
intercept, inject, replay, and modify any message. The attacker cannot
forge Ed25519 signatures without the private key or break HMAC without
the key.

This is proven in the formal model (Section 10).

TLS provides transport confidentiality but the protocol is secure
even without it: an attacker who intercepts the exchange learns the
public key and fingerprint (already public) and cannot forge a signature.

### 9.2. Credential Lifetime vs Revocation

Long credential lifetimes do not weaken security. Revocation is
implemented at Layer 3/4, not by credential expiry.

The correct revocation path when a key is compromised:

1. Add the fingerprint to the verifier's revocation information
   (registry entry, banned list, or policy rule)
2. The verifier's policy rejects the key at the next crossing
3. The credential remains cryptographically valid but policy overrides

This is identical to passport revocation: the document is still a
valid document. The state's systems override it. The document is not
physically invalidated.

Key compromise scope is limited:

- The attacker can present the compromised key's credential
- The attacker CANNOT use other keys or access other entities' resources
- The attacker CANNOT forge credentials for other keys
- Revocation at the registry layer blocks the compromised key

### 9.3. Registry Integrity

Registries are datasets, not authoritative systems. Their integrity
matters to the verifiers that consult them.

Recommended registry integrity mechanisms:

- **Git repository with signed commits** — audit trail, tamper evidence
- **Signed registry documents** — the registry itself is signed by the
  operator's key
- **Append-only logs** — removals are recorded, not silently applied

Registry tampering (adding unauthorized keys) is a threat to verifiers
that rely on the registry. Verifiers SHOULD use integrity-protected
registry sources.

Registry unavailability MUST NOT be treated as a security failure. A
verifier whose registry is unreachable applies its local policy for
that case — which may be fail-open, fail-closed, or cached.

---

## 10. Formal Verification

The Layer 1 attestation exchange has a machine-checked formal model in
the Tamarin prover, located at `formal/provision.spthy` in the
RFC-PROVISIONING.md repository. A revised model scoped to the EdProof
attestation exchange (independent of the Coroot backend) will be
published with the EdProof implementation repository.

The model operates under the Dolev-Yao adversary and verifies:

| Lemma | Property |
|-------|----------|
| `authentication_injective` | Injective agreement: each acceptance maps to a unique send |
| `nonce_single_use` | A nonce is consumed at most once |
| `nonce_freshness` | Only issuer-generated nonces are accepted |
| `credential_secrecy` | Attacker cannot learn the issued credential |
| `entity_binding` | Credential is bound to exactly one fingerprint |
| `receiver_agreement` | Prover's received credential matches what issuer issued |
| `executability` | The protocol can complete successfully |

All seven lemmas were verified in 0.54s (Tamarin 1.10.0, Maude 3.5.1).

To verify:

```bash
tamarin-prover --prove formal/provision.spthy
```

---

## 11. Relationship to Other Standards

**RFC 8032** — EdDSA (Ed25519). The signature algorithm used in Layer 1.

**RFC 8555** — ACME. The `Replay-Nonce` pattern for nonce delivery is
adopted from ACME.

**RFC 9449** — DPoP. The error-then-retry nonce flow is adopted from
DPoP Section 8.

**RFC 7235** — HTTP Authentication. The `EdProof` HTTP scheme follows
RFC 7235.

**SSHSIG** — OpenSSH signature format. The challenge response uses
`sshsig` with namespace `edproof` for cross-protocol isolation.

**SPIFFE/SPIRE** — The Layer 1 attestation exchange is designed to
implement the SPIRE node attestor plugin interface. The Layer 2
credential may be a SPIFFE SVID.

**W3C DID** — The SPIFFE ID produced by EdProof attestation is
structurally equivalent to `did:key`. EdProof provides the attestation
ceremony for key-based DIDs.

**SSH Certificates** — A valid Layer 2 credential format. Widely
deployed, offline-verifiable, long-lived.

---

## 12. References

**[RFC 2119]** Bradner, S., "Key words for use in RFCs to Indicate
Requirement Levels", BCP 14, RFC 2119, March 1997.

**[RFC 7235]** Fielding, R. and J. Reschke, "HTTP/1.1: Authentication",
RFC 7235, June 2014.

**[RFC 7748]** Langley, A. et al., "Elliptic Curves for Security",
RFC 7748, January 2016.

**[RFC 8032]** Josefsson, S. and I. Liusvaara, "Edwards-Curve Digital
Signature Algorithm (EdDSA)", RFC 8032, January 2017.

**[RFC 8174]** Leiba, B., "Ambiguity of Uppercase vs Lowercase in RFC
2119 Key Words", BCP 14, RFC 8174, May 2017.

**[RFC 8555]** Barnes, R. et al., "Automatic Certificate Management
Environment (ACME)", RFC 8555, March 2019.

**[RFC 9449]** Fett, D. et al., "OAuth 2.0 Demonstrating Proof of
Possession (DPoP)", RFC 9449, September 2023.

**[SSHSIG]** OpenSSH, "SSHSIG — SSH Signature Format",
https://github.com/openssh/openssh-portable/blob/master/PROTOCOL.sshsig

**[SPIFFE]** SPIFFE Project, "Secure Production Identity Framework for
Everyone", https://spiffe.io/

**[SPIRE]** SPIFFE Project, "SPIRE — SPIFFE Runtime Environment",
https://github.com/spiffe/spire

**[TAMARIN]** Meier, S. et al., "The TAMARIN Prover for the Symbolic
Analysis of Security Protocols", CAV 2013.

**[W3C-DID]** Sporny, M. et al., "Decentralized Identifiers (DIDs) v1.0",
W3C Recommendation, July 2022.

---

## Appendix A. Supersession of RFC-PROVISIONING.md

RFC-PROVISIONING.md v0.3 defined the EdProof authentication scheme and
a two-phase HTTP provisioning protocol for Coroot observability tenants.

That document is superseded by this one. Specifically:

- The EdProof HTTP authentication scheme (Sections 5, 10 of
  RFC-PROVISIONING.md) is now defined in Section 4.3 of this document.
- The nonce mechanism is now defined in Section 4.2.
- The key management model is now Layer 3 (Section 6).
- The Coroot-specific provisioning flow is now a backend profile
  (Appendix B).
- The Tamarin formal model (`formal/provision.spthy`) covers the same
  attestation exchange with minor scope adjustment. It remains valid.

The RFC-PROVISIONING.md document is retained for historical reference.
Implementations targeting Coroot specifically SHOULD follow Appendix B
and MAY continue to reference RFC-PROVISIONING.md for Coroot-specific
details.

---

## Appendix B. Coroot Backend Profile

This appendix defines how a verifier implements the Coroot observability
backend on top of EdProof. This is a **profile** — a specific application
of the generic protocol. The protocol itself (Sections 4-8) is unchanged.

### B.1. What the Coroot Backend Does

After a successful Layer 1 attestation and Layer 2 credential issuance,
an entity may present its credential to a **coroot-bridge** service to
receive a Coroot project API key.

The coroot-bridge:

1. Validates the presented credential (SVID or SSH cert)
2. Extracts the entity fingerprint from the SPIFFE ID or certificate
3. Derives a deterministic project name: `HMAC(server_secret, fingerprint || service_name)`
4. Creates or retrieves the Coroot project via the Coroot admin API
5. Returns the project API key and OTLP endpoint URLs

### B.2. Project Name Derivation

```
project_name = hex(HMAC-SHA256(server_secret, fingerprint || service_name)[0:16])
```

This is deterministic (same inputs → same name), enumeration-resistant
(requires `server_secret`), and collision-resistant for expected scale.

### B.3. The coroot-bridge is a Ceremony Tool

Provisioning a Coroot tenant is a bootstrap event — typically once per
agent lifetime. The coroot-bridge is not a runtime service on the hot
path. It MAY be implemented as:

- A CLI tool invoked once at agent birth
- A one-shot container
- A GitHub Action step at deploy time
- A persistent service for environments with continuous agent creation

After provisioning, the agent uses its API key directly with Coroot's
OTLP endpoints. The EdProof infrastructure is not involved in telemetry.

### B.4. Relationship to RFC-PROVISIONING.md

RFC-PROVISIONING.md v0.3 defined the full two-phase HTTP protocol
including nonce acquisition and the `EdProof` authorization header.
That protocol is now Layer 1 of EdProof.

For deployments using SPIRE integration, the two-phase HTTP flow is
replaced by the SPIRE attestation exchange. The coroot-bridge validates
SVIDs rather than EdProof authorization headers. The security properties
are equivalent — proven by the same Tamarin model.

---

*End of document.*
