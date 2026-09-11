# Installer acceptance evidence

This record covers disposable orb resources only. It does not prove public ACME issuance, live provider use, real malware scanning, or a full application or schema upgrade.

## Candidate and image provenance

- Helper-only baseline candidate: `a474ec4ed93da7079ddea899b8c841959c1aec5538059d977d7f85e448f2b0e6`.
- Distinct helper-only upgrade target: `09242280218b1d3bc8d1ced5ee2d7a79be50add6c9ee6b9cd6319286cbfdc954`.
- Upgrade bootstrap delta: `99d2d92a75ed1488adfa4bcd751d370ad1d38c76fb3df4cf5d18c1bf3cc4f7e1`.
- Backup helper: `7e45a9ddcbe8f7c03235e5f041f21760aedb884691738f3158dd13cf057dac2e`.
- Restore helper: `6e8ce3a3d1f0eff3cab240466c19801336bc37f169c2afd24709da63444a8752`.
- Reused-image test provenance: Rails image `sha256:e872425bb71e3454f977cc872a728532f8b9baa83cef9120e08feb98378791cb`; runner image `sha256:25b6e69f4f2fabda2e5017aa36c83a17dd9699b848191f887ba450477b13ff33`. No application image rebuild was claimed for helper-only candidates.

## Fresh local-CA install

A clean disposable project used a test-only Caddy override with `admin off`, `tls internal`, and `reverse_proxy app-net:3000` on alternate ports. Setup exited 0 after the ownership fix. The runner stayed running with exit 0 and zero restarts; web and Postgres were healthy. The default runner config bind had digest `5f3fb443553e66f2fb2411e614671957f0b159cc254c5e03ab989ce73ab246d2`.

The inert holder ran as `65534:65534`, with all capabilities dropped and `no-new-privileges`. Generated runner key ownership was `1000:1000`, mode `0600`; the runner UID was 1000. This proves local-CA startup only, not public certificate issuance.

## Owner, deterministic run, and artifact

The local-CA browser flow completed first Owner and workspace setup: one user, organization, and workspace. The disposable screenshot is not retained as a portable project artifact.

Supported runtime discovery, test, approval, same-task handoff, and signed callback sequence produced an investigation artifact. The restored artifact had schema 2, contract state `complete`, task 3, run 8, body `Synthetic local investigation completed.`, and a `crew.artifact_published` audit event. This used a deterministic scripted harness, not a live provider.

## System mail

The fixed-path `navishai configure system-mail` command passed native fake-Docker tests. It accepts only protected owner-readable answer and password files, validates all five values before mutation, replaces only the system-mail settings, retains unrelated managed environment values, and leaves a valid replacement in place if the web/jobs restart fails so the same command can retry.

Cold-production tests prove a real application mailer message uses `NAVISHAI_SYSTEM_SMTP_FROM` when it has no explicit sender. Separate `Mail::SMTP` protocol tests prove a trusted connection upgrades with required STARTTLS before authentication and rejects a server without STARTTLS before sending `AUTH`. They prove transport negotiation and SMTP acceptance only. They do not prove an inbox received mail or use a live SMTP provider.

## Backup and restore

Pending-memory backup and strict verification both exited 0. The backup excluded the runner runtime bind subtree and preserved a disposable Supermemory sentinel while leaving Supermemory stopped.

An explicitly isolated `navishai-restore` project used separate root, project, volumes, bind roots, and ports. Restore exited 0. Restored checks included:

- artifact, contract, and publication audit present;
- runner admissions ledger present;
- Supermemory sentinel present and service stopped;
- a synthetic attachment with digest `5f17b70e0e7c356aa7910878d7a185c17790f60213233eeb2d61bfc555f89d6e`, 49 bytes, and draft association preserved;
- signed catalog for `codex_subscription` reported bounded mode, `configured=true`, and `secret_configured=true` after restore.

The attachment scanner was an explicit clean synthetic fixture, not ClamAV proof. The vault result proves encrypted configuration readability, not credential validity or provider readiness. No model lookup, provider test, or provider execution occurred.

A later managed-metadata restore with operator `4ce33cbb…` exited 0 after selecting the retained release and image archive recorded by the backup. Caddy and core services ran; web and PostgreSQL were healthy. A 37-byte attachment retained its digest and association, and the vault booleans remained readable. This proves the disposable managed restore path with reused images, not a changed-image, schema, provider, scanner, or public-HTTPS upgrade.

## Disposable upgrade

The isolated project upgraded with explicit confirmation using target `09242280…`; the operator exited 0. The installed bootstrap matched `99d2d92a…`. Web and Postgres were healthy; jobs, runner, Caddy, and holder were running. Artifact audit, attachment association and digest, and vault catalog state remained true.

This was a comment-only helper payload delta with reused images. It proves promotion mechanics and retained-state behavior only; it does not prove changed installer behavior, an application-image upgrade, database-schema compatibility, or a public release upgrade.

## Remaining limits

The latest vault/attachment roundtrip did not repeat every earlier artifact and runner-ledger query; those checks passed in prior restore evidence. Public ACME, live provider behavior, real scanner behavior, non-synthetic customer data, and a full application/schema upgrade remain unproved.
