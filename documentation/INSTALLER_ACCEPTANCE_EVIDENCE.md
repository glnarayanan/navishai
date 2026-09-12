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

## Bounded changed-image recovery

An isolated managed target built one Rails image from experimental operator source `0a44e1bcbdc04e4f43dcc598d63bcf4ce067d654`. The image digest was `sha256:16d9ea4f5d9b808c82b76d6e02f3c6552b4752eabbba11e1dfefdfd0e9412460`; runner and Supermemory images were reused. The candidate archive was `/tmp/navishai-pr102-changed-rails.tar`, SHA-256 `5e1e69db5acfa8cd68f7ba6c601adb795a36753f098016c5d9cb8b308be3d3e0`; its images archive SHA-256 was `fedef3b003ea487320909afa80f0136770b80e1f49c52f841be830df98bad33f`.

A temporary local-only web healthcheck failure stopped the upgrade after writers stopped. It recorded `upgrade_health_restore_required`, retained baseline current release `841617108534694a982ab02e030049866492633934918a16673a085953e823c2`, and never promoted candidate `487803ff3ad197a4159d26469bf084257dbe02b439e2429cc27ae33e2a89c00b`. Exact baseline-backup restore then exited 0 with `restore_completed`; web and core services were healthy. Read-only checks found one user, one workspace, a 37-byte attachment with its draft association, and a bounded signed vault catalog with configured and secret-configured values. The forced override was removed; no provider, email, or live service call occurred.

This proves the bounded failure-and-exact-restore sequence for the experimental operator only. It does not prove successful changed-image promotion, arbitrary schema compatibility, or relaxation of the current production changed-image guard.

## Remaining limits

The latest vault/attachment roundtrip did not repeat every earlier artifact and runner-ledger query; those checks passed in prior restore evidence. Public ACME, live provider behavior, real scanner behavior, non-synthetic customer data, and a full application/schema upgrade remain unproved.

Native fake-Docker tests now accept a changed application image when saved-image identity, topology, infrastructure pins, PostgreSQL major, and migrate-status checks pass. This check host has no Docker daemon, so the live procedure in [APPLICATION_IMAGE_UPGRADE_ACCEPTANCE.md](./APPLICATION_IMAGE_UPGRADE_ACCEPTANCE.md) was not executed. Do not treat fixture success as old/new digest proof.

## Cloud-agent check-host reconciliation, 12 September 2026

Host: Ubuntu 24.04.4, Linux 6.12.94+ x86-64, commit `baa0a96`. Docker Engine is not installed (`docker: command not found`). This is not a clean supported-host install of a published candidate.

Applicable procedures that **were** run here:

| Procedure | Result |
|---|---|
| Native installer suite `bin/rails test test/scripts/installer_test.rb` | 92 runs, 732 assertions, 0 failures. Includes identical-archive upgrades and the new application-image fixtures. |
| A1 memory verification fixtures | Implemented and tested on `cursor/memory-verification-efe6` (`bccf343`). Live engine not exercised. |

Named remaining procedures that **were not** run. Omissions are not passes.

| Procedure | Why omitted | Resume |
|---|---|---|
| Exact candidate on a supported clean Ubuntu 24.04 or Debian 12 host | This pod is not a fresh installer target and has no Docker | Operator-owned clean host + candidate |
| Reboot and SSH interruption | No managed install, no SSH service under test | Disposable install with operator access |
| Public DNS, ACME issuance/renewal, external ingress | No public hostname, no ACME account, no ingress | Public DNS and TLS operator |
| Live application-image digest upgrade | No Docker daemon (BLK-002) | [APPLICATION_IMAGE_UPGRADE_ACCEPTANCE.md](./APPLICATION_IMAGE_UPGRADE_ACCEPTANCE.md) |
| Live self-hosted memory round trip | No Supermemory service (BLK-001) | Isolated first-boot key + Owner checklist |
| Live ClamAV scanner | No clamd | Configured daemon + Owner test |
| Live SMTP send/receive | No mailbox credentials | Protected system-mail answers + inbox proof |
| Approved live provider or connector | No owner credentials | Existing connector/runtime test pages |
| Legacy DOC conversion in a **built** image | No Docker image build | Manual built-image smoke on a Docker host |
| Release signing and verification-key distribution | No signing identity | Owner-chosen identity; do not invent one |
| I5 admin who did not build the installer | Out of scope for this worker | Independent operator |

No credentials were invented. No customer messages were sent. No releases were published.


