# Threat model

This baseline records NavishAI's main assets, trust boundaries, threats, and current controls. Update it when a new data path, runtime, integration, or authority enters the product.

## Assets

- Workspace identity, membership, role, policy, and customer-operation data
- User sessions, password and invitation tokens, application secrets, and integration credentials
- Agent tasks, evidence, drafts, memory, runtime approvals, and execution records
- Append-only security, approval, and human-action audit events

## Trust boundaries

```text
┌─────────┐   HTTPS   ┌───────────────┐   SQL   ┌────────────┐
│ Browser │──────────▶│ Rails control │────────▶│ PostgreSQL │
└─────────┘           │ plane         │         └────────────┘
                      └───────┬───────┘
                              ▲
┌───────────────┐   signed    │
│ Email forward │─────────────┘
└───────────────┘   webhook
                              │ versioned protocol
                              ▼
                      ┌───────────────┐
                      │ Go runner     │
                      └───────┬───────┘
                              │ approved adapter
                              ▼
                      ┌───────────────┐
                      │ Agent runtime │
                      └───────────────┘
```

Browser input, mail and integration payloads, public web content, model output, runtime output, uploads, and retrieved memory are untrusted. Rails owns user and workspace authority. PostgreSQL owns durable business, policy, security, and audit state. Only the Go runner may start an agent runtime or arbitrary process.

## Baseline threats and controls

| Threat | Required control |
|---|---|
| Cross-workspace access or insecure object reference | Resolve records through the current user's membership and current workspace; fail closed; test another tenant's identifiers. |
| Credential guessing and account discovery | Generic failures, constant-work password checks, shared IP rate limits, short-lived signed tokens, and filtered logs. |
| Session theft, replay, or stale authority | Signed secure HTTP-only cookies, fixed expiry, server-side revocation, row-locked credential changes, and role revalidation. |
| Cross-site request, script, framing, or content injection | Rails CSRF protection, strict content security policy, frame denial, same-origin browser isolation, output escaping, and no runtime CDN. |
| Secret or personal-data disclosure through logs and audit | Parameter filtering plus structured audit metadata that rejects credential-like keys and has a strict size bound. |
| Audit tampering or ambiguous attribution | PostgreSQL rejects updates and deletes; events record actor kind, source, request, network address, subject, workspace, and stable action names. Direct database administration remains a privileged trust boundary. |
| Source identity poisoning or cross-workspace merge | Match only exact normalized email or domain keys inside one workspace; block conflicting roots for Manager-or-higher review; preserve source identity, candidate, and merge history. |
| Duplicate or reordered security actions | Database uniqueness, row locks, signed token state, idempotency keys where a protocol crosses processes, and transactional state-plus-audit writes. |
| Compromised model, tool, or runtime | Rails never starts runtimes; the runner admits only approved versioned requests and must enforce roots, time, process, credential, and egress bounds. |
| Unsafe external fetch or webhook | Authenticate webhooks; revalidate DNS and redirects; bound size and time; treat content as evidence, not instruction. These controls arrive with each integration. |
| Knowledge URL SSRF, DNS rebinding, or active HTML | Allow HTTPS without URL credentials; reject every private or reserved DNS answer; pin the validated address while retaining TLS hostname checks; revalidate redirects; bound time and decoded bytes; extract text and discard active markup. |
| Forged, replayed, or oversized inbound email | Use a per-inbox unguessable endpoint plus a deployment-held HMAC secret, reject stale timestamps and oversized bodies before parsing, suppress duplicate Message-IDs, retain a source digest, and render extracted body text without trusted HTML. |
| Unauthorised customer communication | No agent, job, or background trigger receives send authority. A current authenticated human must review and issue each send command. |

## Review rules

- Add an event and a denial test when a change adds authority, sensitive disclosure, or an external side effect.
- Never store passwords, tokens, secret values, raw credentials, or unrestricted request parameters in audit metadata.
- Mark planned controls as planned until executable tests prove them.
- Treat database, deployment host, backup, and operator access as privileged. Release hardening must document key handling, backup access, restore checks, and incident response.
