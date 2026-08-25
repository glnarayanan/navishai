# Release process

NavishAI has no published release yet. A local release candidate requires the full repository check set and release-specific records below. GitHub Actions stays manual-only and is not a release-candidate gate unless the Owner later approves its use.

The current source review boundary and known gaps are in [RELEASE_CANDIDATE.md](./RELEASE_CANDIDATE.md).

## Build record

Start from a clean, signed-off commit. Run `bin/ci`, the Compose upgrade preflight, and an isolated restore test. Build Rails, runner, and Supermemory images from the Dockerfiles. Their base image and downloaded Supermemory inputs use immutable SHA-256 values.

Create a CycloneDX inventory and a manifest for the files that will ship:

```sh
mkdir -p release
script/sbom release/navishai.cdx.json
script/release_manifest release/manifest.json release/navishai.cdx.json path/to/each/release-archive
```

Publish the source commit, image digests, SBOM, manifest, and release notes together. Sign each release archive and `manifest.json` with the project’s release identity when that identity has been set up. Record the signing tool, identity, verification command, and public certificate or transparency-log link in the release notes. Checksums detect changed bytes; a signature links those bytes to the release identity. Do not claim SLSA provenance or a signed release until the published records support that claim.

## Dependency review

Before a release, review:

- every direct and transitive production gem in `Gemfile.lock`;
- Go modules in `go.mod` and, when present, `vendor/modules.txt`;
- local browser pins in `config/importmap.rb`;
- every Docker base and service image digest;
- the Supermemory version and platform checksums in `script/install_supermemory`; and
- approved runtime CLI compatibility ranges in the Go adapters.

The release reviewer checks the upstream source, licence, maintenance state, published security notices, and the reason NavishAI needs each direct dependency. Record approved changes in `documentation/DEPENDENCIES.md`. Never update a runtime, image, CLI, database, or Memory service as an unreviewed side effect of an application release.

## Security patch policy

Dependabot reports available Bundler, Go, and GitHub Actions updates. Local `bin/ci` runs the gem advisory audit, Importmap audit, Brakeman, tests, and the SBOM check. GitHub Actions stays manual-only until the Owner approves release use.

Triage a known exploited or critical issue at once. Triage other security reports within three working days. Confirm whether the affected code or deployment path is present, choose the smallest supported update or mitigation, and run the full local check set plus the affected deployment checks. Publish the fixed version and a plain impact note as soon as the fix is verified. If no safe fix exists, state the affected versions and the tested mitigation. Do not hide a relevant advisory merely to make a check pass.

Supported releases receive security fixes until the release notes name an end date. Before the first public release, the project supports only the current unreleased main line.

## Release notes and rollback

State new behavior, breaking changes, migration and backup needs, dependency changes, known gaps, and the exact rollback boundary. Follow `documentation/OPERATIONS.md` for backup, preflight, restore, and post-upgrade checks. Never tell an operator to run old code against a schema unless that rollback path passed an upgrade test.
