# Risk acceptance register

Findings the team has reviewed and chosen to accept for a limited time instead of fixing now.
Each entry is enforced in CI: the scanner ignores only the listed advisory ID, and the
`Dependency audit` job fails once the review date is reached.

## RA-001: opentelemetry-api unbounded `tracestate` parsing

| Field | Value |
|---|---|
| Advisory | [GHSA-xcq7-p3pf-p88h](https://github.com/advisories/GHSA-xcq7-p3pf-p88h) / CVE-2026-114603 |
| Severity | Medium (denial of service) |
| Affected component | `opentelemetry-api` 1.41.1, a dependency of `google-adk` 1.39.1 in the ADK agent image |
| Found by | `pip-audit` in the Security gates workflow, 2026-11-10 |
| Fixed version | 1.45.1, which `google-adk` 1.39.1 does not allow; only `google-adk` 2.x does |
| Decision | Accepted by the G-ForceX team (Karlie) on 2026-11-10 |
| Review by | 2026-11-25 |

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

## RA-002: opentelemetry-api quadratic-time `traceparent` parsing

| Field | Value |
|---|---|
| Advisory | [GHSA-mf5v-w3w3-f6cg](https://github.com/advisories/GHSA-mf5v-w3w3-f6cg) / CVE-2026-126360 |
| Severity | Medium, CVSS 5.3 (denial of service) |
| Affected component | `opentelemetry-api` 1.41.1 (all versions up to 1.45.1), a dependency of `google-adk` 1.39.1 in the ADK agent image |
| Found by | `pip-audit` in the Security gates workflow on PR #41, 2026-11-13 (advisory published the same day) |
| Fixed version | 1.45.2, which `google-adk` 1.39.1 does not allow |
| Decision | Accepted by the G-ForceX team (Karlie) on 2026-11-13 |
| Review by | 2026-11-25 |

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
