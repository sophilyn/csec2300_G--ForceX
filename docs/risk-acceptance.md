# Risk acceptance register

Findings the team has reviewed and chosen to accept for a limited time instead of fixing now.
Each entry is enforced in CI: the scanner ignores only the listed advisory ID, and the
`Dependency audit` job fails once the review date is reached. Closed entries are kept as a record:
their ignore flag is removed from CI and their "Review by" row is replaced by a "Closed" row.

**Current status (2026-11-18): one open risk acceptance, RA-003** (plain HTTP between containers on private
Docker networks). It is a design decision, not a scanner finding, so there is no `--ignore-vuln` flag, but CI
still enforces its review date. RA-001 and RA-002 were both closed by the `google-adk` 2.14.1 upgrade;
`pip-audit` reports no known vulnerabilities with no ignores.

## RA-003: unencrypted HTTP between containers (OPEN)

| Field | Value |
|---|---|
| Finding | Open WebUI → Ollama and ADK agent → Ollama use plain HTTP (`http://ollama:11434`), without TLS |
| Severity | Low (confidentiality of prompts and answers on a private Docker network) |
| Affected component | `docker-compose.yml`: `OLLAMA_BASE_URL`, `OLLAMA_API_BASE` |
| Found by | Team encryption testing, issue #23 (Control 6), 2026-11-05 |
| Fix | Not offered by Ollama itself: it has no built-in TLS. Would need a TLS proxy container per service and a private certificate authority |
| Decision | Proposed for team acceptance on 2026-11-18 (owner: G-ForceX team) |
| Review by | 2026-12-31 |

**What the risk is:** prompts, document text sent to the model, and model answers cross the Docker network
unencrypted. Something that could watch traffic on that network could read them.

**Why the risk is low here (compensating controls):**
- **The browser connection is encrypted.** Users reach Open WebUI only through the HTTPS proxy
  (TLS 1.3, `https://localhost:3443`). Plain HTTP on port 3000 only redirects. See `docs/encryption.md`.
- **The traffic never leaves this computer.** The containers talk over Docker's private networks inside one
  host. Ollama and the agent publish no ports, and the agent's network is `internal: true` (no internet).
  CI checks these rules on every pull request (Control 1, `docs/network-firewall.md`).
- **Segmentation limits who could listen.** The HTTPS proxy cannot reach Ollama or the agent, and
  Open WebUI cannot reach the agent. Reading the traffic would require control of the Docker host,
  and anyone with that control can already read the containers' data directly.
- **Data at rest is protected by host disk encryption** (Windows Device Encryption, issue #23).

**Why not fix now:** Ollama has no TLS option. Adding a TLS proxy in front of Ollama would mean another
container, a private certificate authority, and certificates trusted inside Open WebUI and the agent. That
adds complexity and new failure points without protecting against a realistic attacker in this
single-computer setup.

**Exit plan:** if the services are ever split across more than one computer, or the Docker network is
shared with untrusted containers, put a TLS proxy (for example Caddy) in front of Ollama and change
`OLLAMA_BASE_URL` and `OLLAMA_API_BASE` to `https://`. Re-assess this entry by the review date either way.

**Residual risk:** an attacker who already controls the Docker host could read prompts and answers in transit.

## RA-001: opentelemetry-api unbounded `tracestate` parsing (CLOSED)

| Field | Value |
|---|---|
| Advisory | [GHSA-xcq7-p3pf-p88h](https://github.com/advisories/GHSA-xcq7-p3pf-p88h) / CVE-2026-114603 |
| Severity | Medium (denial of service) |
| Affected component | `opentelemetry-api` 1.41.1, a dependency of `google-adk` 1.39.1 in the ADK agent image |
| Found by | `pip-audit` in the Security gates workflow, 2026-11-10 |
| Fixed version | 1.45.1, which `google-adk` 1.39.1 does not allow; only `google-adk` 2.x does |
| Decision | Accepted by the G-ForceX team (Karlie) on 2026-11-10 |
| Closed | 2026-11-13: fixed by upgrading to `google-adk` 2.14.1 with `opentelemetry-api` 1.45.2 pinned |

**What the vulnerability is:** a very long W3C `tracestate` HTTP header (about 100 KB of spaces or tabs)
makes the parser use quadratic CPU, blocking the server for about 6–12 seconds per request.
It affects availability only, not confidentiality or integrity.

**Why the risk is low here (compensating controls):**
- The agent's API server publishes **no host port**. Only containers on the internal Docker network
  can send it HTTP requests. CI checks this on every pull request.
- The project runs on a single local machine for a classroom demonstration, with no public exposure.
- Container hardening limits impact: read-only filesystem, all Linux capabilities dropped,
  `no-new-privileges`, non-root user, and `restart: unless-stopped` recovers a stuck service.

**Why not fix now:** the fix requires upgrading the agent from `google-adk` 1.x to 2.x, a major version
with API changes that would need re-implementation and re-testing three days before the
Milestone 3 deadline (2026-11-13).

**Exit plan:** upgrade to `google-adk` 2.x (2.14.0 resolves with `opentelemetry-api` 1.45.1), rerun the
unit and real Ollama integration tests, then remove `--ignore-vuln GHSA-xcq7-p3pf-p88h` from
`.github/workflows/security-gates.yml` and close this entry.

**Residual risk:** another container on the internal network, or a process given network access to it,
could make the agent unresponsive for seconds at a time. No data exposure.

## RA-002: opentelemetry-api quadratic-time `traceparent` parsing (CLOSED)

| Field | Value |
|---|---|
| Advisory | [GHSA-mf5v-w3w3-f6cg](https://github.com/advisories/GHSA-mf5v-w3w3-f6cg) / CVE-2026-126360 |
| Severity | Medium, CVSS 5.3 (denial of service) |
| Affected component | `opentelemetry-api` 1.41.1 (all versions up to 1.45.1), a dependency of `google-adk` 1.39.1 in the ADK agent image |
| Found by | `pip-audit` in the Security gates workflow on PR #41, 2026-11-13 (advisory published the same day) |
| Fixed version | 1.45.2, which `google-adk` 1.39.1 does not allow |
| Decision | Accepted by the G-ForceX team (Karlie) on 2026-11-13 |
| Closed | 2026-11-13: fixed by upgrading to `google-adk` 2.14.1 with `opentelemetry-api` 1.45.2 pinned |

**What the vulnerability is:** a crafted W3C `traceparent` HTTP header makes the parser use quadratic
CPU time, slowing or blocking the agent's API server. It affects availability only, not
confidentiality or integrity.

**Why the risk is low here (compensating controls):** the same as RA-001. The agent publishes no host
port (checked in CI), the project runs on one local machine with no public exposure, and the
container is hardened (read-only filesystem, all capabilities dropped, `no-new-privileges`,
non-root user, `restart: unless-stopped`).

**Why not fix now:** the same as RA-001: the fix needs the `google-adk` 2.x upgrade. Note that
`google-adk` 2.14.0 alone brings `opentelemetry-api` 1.45.1, which is **still affected** by this
advisory, so the upgrade must also require `opentelemetry-api>=1.45.2`.

**Exit plan:** do it together with RA-001: upgrade to `google-adk` 2.x, require
`opentelemetry-api>=1.45.2`, rerun the unit, integration, and prompt-injection tests, then remove
both `--ignore-vuln` flags from `.github/workflows/security-gates.yml` and close RA-001 and RA-002.

**Residual risk:** another container on the internal network could make the agent unresponsive.
No data exposure.
