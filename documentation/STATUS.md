# Rebuild status

Updated 30 September 2026. The [new product authority](./PRODUCT.md) supersedes every old implementation milestone. Git history preserves the earlier helpdesk and its evidence; those checks do not establish a working evaluation lab.

## Current state

- Product, architecture, domain, and rebuild plan written before application changes.
- Existing subsystems inventoried and classified in [ARCHITECTURE.md](./ARCHITECTURE.md).
- Demolition not yet implemented. Corpus/scenario foundations, compiler, calibration, target execution, and regression workflow are not built.
- No release, deployment, live-provider use, customer dataset, or customer validation in this rebuild.

## Delivery and boundaries

Use stacked PRs for the authority reset, demolition, corpus/scenario foundation, compiler/calibration, and runner/regression slices. Continuous evaluation follows P0 proof. Classifiers remain gated on enough labels and measured need.

The checkout started on `main` with a user-owned Bundler checksum addition in `Gemfile.lock`; retain it outside rebuild commits. Preserve existing databases unless the owner explicitly chooses a disposable reset. Use a fresh database for baseline checks.

Next: remove the obsolete product and prove retained authentication, isolation, fresh schema, and the replacement shell.
