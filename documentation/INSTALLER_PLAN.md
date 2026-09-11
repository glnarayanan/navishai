# Guided VPS installation plan

**Status:** Build contract; implementation state and evidence per slice are recorded in the guided-installer table of [STATUS.md](./STATUS.md)
**Date:** 10 September 2026
**Owner request:** Before live product tests, make deployment and setup simple enough that an IT admin can SSH into a VPS, run one command, and follow a guided setup. Execute this plan outside the planning thread.

This plan extends [PRODUCT.md](./PRODUCT.md). It does not mark the product gaps from the preceding review complete. [STATUS.md](./STATUS.md) remains the implementation record. A published installer, a passing host installation, and a live customer workflow are separate outcomes.

## 1. Outcome and boundaries

An admin with sudo access to a supported VPS runs one bootstrap command. NavishAI checks the host, explains required changes, installs a pinned Compose release, sets up HTTPS and private services, provisions secrets, starts the stack, and guides the admin into first-Owner and Workspace setup. Routine setup must not require Git, Ruby, Go, SQL, editing YAML or JSON, or assembling Docker commands.

The first supported path is a dedicated Linux x86-64 VPS, Docker Compose, local storage, and a public hostname. Prove Ubuntu 24.04 LTS and Debian 12 before advertising both. Treat 4 vCPU, 8 GiB RAM, and 60 GiB free disk as an initial test-host budget, not a supported minimum until measured. Do not download a large local inference model or assume a GPU.

The admin supplies only things NavishAI cannot create: host access, a hostname they control, any selected service credentials, and a backup destination they own. Explain DNS and cloud-firewall changes at the point they are needed. The installer cannot promise to change a VPS provider's firewall or public DNS without a separate approved integration.

The first guided AI path uses the existing built-in OpenAI or Anthropic HTTPS adapters. Connecting AI can be deferred. Subscription CLIs remain supported by the existing operator path but are not advertised as turnkey until installation, login, namespace policy, exact-executable approval, and restart behavior pass on supported hosts. Never enable host-trusted execution to make setup easier.

Out of scope: a general deployment platform, Kubernetes/Helm parity, S3, managed hosting, billing, new model or knowledge adapters, rewriting crew orchestration, automatic provider upgrades, autonomous customer sends, and production customer tests. Native Linux deployment remains supported separately; do not build a second guided installer for it in this slice.

## 2. Proposed admin journey

The public one-command URL is a release deliverable, not an existing endpoint. Publish its exact command only after hosting, artifact access, and release authority are settled. Offer a download/inspect/verify/run alternative alongside the convenient bootstrap command.

1. **Check this VPS.** Detect OS, architecture, root/sudo, disk and memory, clock, Docker/Compose, ports, existing installations, DNS, and access to required artifact hosts. Distinguish a missing dependency from an unsupported host. Check capabilities separately for API execution, DOC conversion, and subscription isolation.
2. **Choose the address.** Ask for a hostname. Show the required A/AAAA records and public ports. Check conflicting IPv6 records and port ownership. Offer bundled HTTPS as the normal path and an existing TLS reverse proxy as an advanced path. If DNS or certificate issuance fails, save progress and explain how to resume; do not expose an HTTP login as a fallback.
3. **Review and apply.** Show the selected release, packages, directories, services, ports, downloads, persistent data, and any expected downtime. Ask once before host changes; ask again only for a distinct destructive or external action. Never change SSH policy or replace an existing firewall or proxy implicitly.
4. **Install and start.** Pull verified images, generate private application/integration/vault secrets and runner TLS, prepare storage, provision memory, run the first migration, and start supervised services. Show named progress steps and actionable failures, not a wall of container logs.
5. **Create the first Owner.** Print the HTTPS setup address and reveal a short-lived bootstrap code only in the admin's interactive terminal. The browser asks for Owner credentials, Organisation, and Workspace through the existing bootstrap service. Do not put the code in a URL, shell arguments, normal logs, or a support report. Explain how to pass this step to a different application owner.
6. **Finish setup in the browser.** Show a small role-aware checklist linking to existing configuration surfaces: system email, AI provider, memory, search, optional shared inbox/Intercom/Notion, attachments, and backups. Preserve existing provider test and approval flows. Clearly distinguish skipped, configured, tested, blocked, and ready states.
7. **Show the result.** Print the application address, installed version, readiness by capability, remaining setup, and the commands for status, diagnosis, and resume. A running container is not a completed install.

The terminal handles host setup; Rails handles users, Workspaces, roles, and provider approval. Do not make Rails run Docker, shell commands, or a model CLI. Do not rebuild all existing settings pages as a second wizard.

## 3. Implementation approach

### Thin bootstrap, existing tools underneath

- Use a small HTTPS-downloaded shell bootstrap for supported-host detection, artifact retrieval, and entry into the installer. Reuse the repository's Bash Compose scripts; introduce no new CLI framework or host Ruby/Go requirement. If structured coordination outgrows a small shell implementation, propose the smallest compiled command using the existing Go toolchain before adding another runtime.
- Install one `navishai` operator command. Separate terminal presentation from operations enough to test both, without creating a general plugin or workflow engine.
- Use prebuilt Rails, runner, and Supermemory images. Release archives carry the Compose configuration, scripts, source commit, image digests, compatibility data, and a manifest. Do not clone or build `main` on the VPS, use mutable image tags as identity, or install compilers there.
- Resolve a chosen release once and retain it across resume. Check integrity before extraction or execution; reject archive path escapes and symlink escapes. Document the initial bootstrap trust boundary. Checksums alone do not authenticate a publisher; use an approved signing identity for the distributed release and a separately trusted verification key.
- Support access to an approved private candidate artifact channel for pre-release host proof. Never print access tokens, require a GitHub token in shell arguments, or make public publication a prerequisite for local implementation tests.
- Keep the existing Compose topology as the source of truth. A generated deployment override may supply fixed image references, paths, and exposure settings; it must not become an independently maintained stack.

### Files, progress, and restart

Recommended managed layout: immutable release files under `/opt/navishai/releases/<version>`, configuration and private secrets under `/etc/navishai`, and installer state under `/var/lib/navishai`. Keep Compose volume identities stable across versions. Record exact paths so backup and recovery never depend on the caller's working directory.

- Separate secrets from the non-secret install record. Use private directories, least-required file permissions, atomic replacement, and an install lock. Test actual container UID access to mounted keys and data; neither world-readable keys nor unreadable private keys are acceptable.
- Record installer/release versions, image digests, selected options, completed steps, pending steps, and bounded failure codes. Do not copy application policy, tenant state, or credentials into this record.
- Re-running installation resumes the same installation. Validate each completed step's postcondition; a saved success flag alone is not evidence. Do not rotate existing secrets, recreate users, replace volumes, rerun a paid probe, or silently select a newer release.
- Handle Ctrl+C, SSH loss, reboot, network failure, and partial downloads. Services survive logout and reboot through Docker restart policy and its enabled system service. An interrupted migration requires inspection of actual migration state before continuation, not blind replay.
- Detect unmanaged or older installations and stop with guidance. Do not silently adopt, reset, or migrate them.

### Security and readiness

- Bind only the intended HTTPS entry point publicly. PostgreSQL, Supermemory, the runner, scanner, proxy administration, and direct Rails ports remain private. Verify from outside the host; local port listings are not sufficient.
- Prove outbound connectivity for the enabled typed HTTPS providers and search without granting general agent egress. Preserve the runner's isolation policies and the existing private Rails-to-runner trust boundary. In particular, do not solve the current internal-network routing problem by weakening isolation or enabling privileged containers, host networking, or the Docker socket.
- Use the existing first-Owner transaction and audit path. Add expiry and safe renewal for bootstrap authorization, prevent simultaneous claims, close setup after first use, and remove the deployment token once consumed. Never reset bootstrap on an existing installation. Host ownership authorizes installation; it does not become an unauthenticated persistent application-admin API.
- Collect passwords and keys without echo, never through command arguments. Preserve runner-only AI-provider key storage and Rails-encrypted connector credentials. Diagnostics must not dump `.env`, rendered Compose secrets, raw provider responses, or customer records.
- Install checks are synthetic and local by default. No provider generation, customer communication, historical backfill, or external account mutation happens without an explicit action naming the destination, data, and possible cost. A test email must target the admin's chosen address, not a customer.
- Report separate states: installed, reachable over HTTPS, Owner configured, background jobs working, memory ready, attachment scanning ready, AI configured/tested/approved, and integrations ready. Skipped setup is not green. Keep overall functional readiness distinct from optional capabilities.

## 4. Known prerequisites to resolve first

These are observed gaps in the current deployment path, not permission to hide incomplete setup behind a wizard.

| Area | Current evidence | Required outcome |
|---|---|---|
| First Owner | `FirstOwnerBootstrap` requires `NAVISHAI_BOOTSTRAP_TOKEN`; `compose.yaml` does not pass it. | A secure, expiring, once-only guided handoff that works in the deployed stack. |
| Memory | `ops/docker/supermemory.Dockerfile` starts pinned Local 0.0.8; current instructions require first-boot setup and its generated API key. | Prove the exact pinned binary's configuration, model needs, bearer-key provisioning, data persistence, and restart behavior. Do not assume current upstream docs describe that version. |
| Provider networking | Runner uses an internal Compose network; deployment instructions leave egress policy to the host. | A tested packaged route for the baseline bounded providers, with no broader agent access or manual JSON editing. |
| System email | Production Action Mailer SMTP settings remain commented; shared-inbox SMTP has a separate credential contract. | One guided, validated configuration for invitations/reset/notifications; distinguish it from customer-reply SMTP. No SMTP-server installation. |
| Public HTTPS | Current instructions require an external TLS proxy and publish Rails port 3000. | Bundle a small maintained TLS proxy or integrate an existing one, without leaving a bypass port public. |
| Artifacts | Current Compose builds local images; no published NavishAI release exists. | A reproducible candidate bundle and image set, then owner-authorized distribution of the installer and artifacts. |
| Attachments | ClamAV adapter exists; daemon is external and absent by default. | Offer guided scanner setup or an existing daemon, with quarantine retained until a clean result. Skipping scanning must visibly disable attachment use. |
| Recovery | Backup/preflight scripts assume release-root execution and separately held secrets. | Fixed-path operator commands that preserve the existing stopped-writer boundary and explain the separate secret backup requirement. |

For Supermemory, first prefer a supported noninteractive provisioning interface. If the pinned binary only prints its key, isolate first boot from ordinary container/service logs and evaluate a narrowly versioned private capture or an explicit one-time guided entry. Test format mismatch and interruption; never grep a shared log for credentials. If a safe path cannot be proven, stop that capability with a clear blocker and seek an owner decision. No managed-memory fallback, new local-model service, or new provider-key custody path is authorized by this plan.

## 5. Dependencies and owner decisions

Proposed default: a pinned Caddy container for HTTPS and certificate renewal. It avoids making each admin write reverse-proxy configuration. An existing proxy remains an advanced option. Caddy is a new production service and requires explicit owner approval before addition; record its maintenance, ACME network contact, persistent key storage, and security-update policy.

Bundling pinned ClamAV and optional SearXNG containers changes them from external services to packaged dependencies. Seek approval for each selected image and document its update/download behavior and resource needs. Start with an existing search endpoint or hosted provider if packaged search is not approved. Do not add a new LLM service merely to complete memory setup.

Also settle the distribution host/registry, artifact access, licence boundary, signing identity/tool, and supported-host matrix. Public publishing and shared-host changes require explicit authorization. A plan approval alone is not permission to publish a release or provision a real VPS.

## 6. Ordered implementation slices

Each slice should be a small reviewable PR or a short stack where necessary. Follow repository-native checks and one risk-based review; do not start extra implementation threads unless the owner asks.

### I0 — Prove the default installation path

On a disposable Docker-capable supported host, establish the exact pinned memory first boot, candidate-image startup, baseline provider network boundary, bootstrap-token wiring, and TLS approach. Measure disk/RAM/download needs. Record remaining dependency approvals and decisions before building the wizard around assumptions. No customer data or paid model call is needed for this proof; use local controlled fixtures where appropriate and disclose what they cannot prove.

**Done:** a concrete supported configuration and test record; no unknown core startup step hidden behind manual YAML, log scraping, or elevated runtime privileges. An unresolved prerequisite blocks the affected later claim, not unrelated safe work.

### I1 — Reproducible installation bundle

Add release assembly for prebuilt images, immutable references, manifest/signature verification, and the managed directory layout. Preserve existing backup compatibility and the source-commit record. Prepare publication workflows without running them unless authorized.

**Done:** a clean host can obtain and verify a candidate bundle; tampered, incomplete, incompatible, and path-escaping artifacts fail before execution. No application source build occurs on the host.

### I2 — Resumable terminal setup and HTTPS

Implement the bootstrap and `navishai setup`: preflight, guided choices, change summary/consent, prerequisite installation, persistent progress, secret/TLS generation, service start, and certificate readiness. Read interactive input from the controlling terminal even when the bootstrap comes from a pipe. Without a TTY, fail with instructions or accept a documented answer file with protected secret-file references; never guess destructive defaults.

**Done:** clean install, existing-Docker install, rerun, interrupted pull, reboot/resume, wrong DNS, occupied ports, low resources, and unsupported-host paths pass. Existing unrelated services and SSH access remain intact.

### I3 — Owner handoff and application setup

Complete bootstrap expiry/consumption and a small authenticated setup checklist. Reuse existing provider and connector settings. Add only missing deployment configuration needed for system mail, memory, selected search, and scanning; keep host operations out of Rails. Preserve original runtime tests, fingerprint approval, ownership, and role checks.

**Done:** a fresh admin reaches the Workspace without shell knowledge, another visitor cannot claim it, consumed/expired bootstrap credentials fail, and each skipped capability has an honest status. Browser checks cover desktop, mobile, keyboard, expired setup, validation errors, unavailable services, and resume; inspect rendered results.

### I4 — Day-two operator commands

Provide a small command set over existing operations:

| Command | Contract |
|---|---|
| `navishai setup` | Start or resume setup; preserve existing secrets and configured accounts. |
| `navishai status` | Show installed version, service state, and incomplete setup without secrets. |
| `navishai doctor` | Read-only diagnostics with precise recovery instructions; optional JSON output. No automatic repairs or paid probes. |
| `navishai backup <path>` | Explicitly confirmed stopped-writer backup and verification using current scripts; no claim that local storage is off-site protection. |
| `navishai upgrade <version>` | Verify target artifacts and backup, run preflight, show downtime/migration boundary, then require confirmation before applying. Never auto-upgrade. |
| `navishai restore <path>` | Verify the archive and matching secret/config set; require exact destructive target confirmation. Never overwrite another Compose project. |

Show failed service names and bounded failure codes rather than adding a broad raw-log support bundle. Do not add generic self-repair, uninstall/data deletion, or a new backup service in this slice. Never offer an image-only rollback after an incompatible migration; preserve the existing restore-required boundaries.

**Done:** commands work from any directory, reject incompatible versions and wrong targets, and retain original backup/restore safeguards. A failed upgrade never leaves a falsely healthy mixed-version stack. An isolated restore proves retained rows, attachment bytes, audit lineage, memory reconstruction/state, and provider-vault readability without invoking a live provider.

### I5 — Fresh-host acceptance and handoff

Run the complete install and recovery matrix below from the exact candidate artifacts. Give an IT admin who did not build the installer only the VPS prerequisites and single command. Record prompts, manual interventions, elapsed time, resource use, failures, and final state without recording secrets. Fix instructions or setup defects before calling the guided path complete.

**Done:** one-command installation is demonstrated, not inferred from mocked shell tests. Publish the supported-host table and evidence, update PRODUCT/STATUS/DEPLOYMENT/OPERATIONS/RELEASE/THREAT_MODEL/DEPENDENCIES only where truth changed, and replace stale manual steps for this supported path. Public release remains a separate authorized action.

## 7. Acceptance matrix

- **Hosts:** clean supported OS images with and without Docker; non-root sudo and root entry; unsupported architecture; real reboot. Reject unsupported combinations early. Report untested distributions, private networking, proxy arrangements, and subscription modes rather than implying support.
- **Network:** correct and incorrect A/AAAA records, occupied 80/443, certificate failure/renewal, lost artifact connectivity, and controlled provider reachability. From another host verify only intended ingress is reachable; runner/database/memory/direct Rails access must fail.
- **State:** repeated setup, concurrent setup, Ctrl+C, SSH disconnect, partial downloads, interrupted provisioning, container restart, full reboot, and failed migration. Existing passwords, tokens, Owner, volume identities, and data must survive unchanged.
- **Secrets:** hidden entry; permissions correct for actual service users; no secret in process arguments, ordinary logs, URLs, install record, manifest, or diagnostics. Verify attempted injection through hostname, paths, answers, and release metadata cannot become shell code.
- **Application:** first Owner, authenticated Workspace access, real queued synthetic job completion, scoped memory index/search after restart, and scanner clean/quarantine behavior. Failures must name the capability and next action. A health HTTP redirect is not proof of job processing, memory recall, or certificate validity.
- **Optional services:** deferred AI/SMTP/search/connectors do not block infrastructure install, but remain incomplete in functional readiness. Test fixtures prove configuration and policy contracts. Separate explicitly authorized live validation from the no-credential install proof.
- **Recovery:** verified backup and isolated restore, sufficient disk before upgrade, wrong archive/secret/version rejection, pending irreversible migration disclosure, and failure without data deletion or unrelated-service changes.
- **Usability:** no YAML/JSON, SQL, compiler installation, or manual Docker command needed on the supported path. Prompts have safe defaults, Back/Retry/Skip where valid, plain errors, and no reliance on color or terminal animation. Browser handoff covers current design and accessibility requirements.
- **Checks:** extend `test/scripts/compose_operations_test.rb` patterns for fast failure injection; add focused Rails/bootstrap/configuration tests and Go checks only where code changes. Run native formatting, audits, security checks, focused suites, and `bin/ci` as appropriate. Mocked Docker tests do not substitute for I5.

Performance acceptance is measured, not promised in advance. After I0, publish a host minimum and a typical cold-install time with image/model download size and network conditions. The admin must always see which step is waiting and how to resume.

## 8. Execution handoff

> Implement documentation/INSTALLER_PLAN.md in the glnarayanan/navishai repository. Read current AGENTS.md, PRODUCT.md, STATUS.md, and deployment/operations guidance first. Recheck current main and preserve unrelated work. Own I0–I5 in order, starting with the actual Compose first-boot and security prerequisites rather than a cosmetic wizard. Reuse existing domain services and operator scripts; do not weaken isolation, tenant authority, secret custody, or human-only sending. Obtain the named production-dependency and distribution approvals before adding or publishing them. Use disposable hosts and synthetic data for installation proof; do not consume live credentials or run customer tests without explicit permission. Do not create additional threads unless the owner asks. Deliver small reviewed changes with exact test and fresh-host evidence, unresolved boundaries, and a clear distinction between implemented, tested, published, deployed, and live-validated. This prompt authorizes in-scope implementation, not remote pushes, release publication, shared-host changes, or deletion of non-disposable data.

## 9. Reference patterns

- [OpenClaw onboarding](https://docs.openclaw.ai/start/wizard): guided setup, explicit provider selection, resume, and browser handoff. Borrow the short journey, not its access defaults or technology stack.
- [Hermes installer](https://github.com/NousResearch/hermes-agent/blob/main/scripts/install.sh): bootstrap/setup separation and named stages with structured results. NavishAI must preserve local state rather than copy checkout-reset behavior.
- [Hermes installation guide](https://github.com/NousResearch/hermes-agent/blob/main/website/docs/getting-started/installation.md): headless operation and persistent service setup.
- [Supermemory configuration](https://github.com/supermemoryai/supermemory/blob/main/apps/docs/self-hosting/configuration.mdx) and [first boot](https://github.com/supermemoryai/supermemory/blob/main/apps/docs/self-hosting/quickstart.mdx): research starting points only; verify against NavishAI's pinned Local 0.0.8 before relying on a provisioning contract.
