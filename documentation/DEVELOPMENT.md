# Development

NavishAI uses Ruby 3.4.10, Rails 8.1.3.1, PostgreSQL 15 with pgvector 0.8.6, and Go 1.27.0.

## First setup

Install the pinned Ruby and Go versions, PostgreSQL 15, and pgvector 0.8.6. Create `navishai_development` and `navishai_test`, then run:

```sh
bin/setup --skip-server
```

The Amp orb setup script installs these system tools and prepares both databases.

## Checks

Run the full local check suite with:

```sh
bin/ci
```

The suite checks Ruby and Go formatting, audits Ruby and import-map dependencies, scans Rails code, runs Rails tests, vets the Go runner, and runs Go tests.

Run focused checks while working:

```sh
bin/rails test
go test ./...
```

The Rails control plane exposes `GET /up`. The runner skeleton exposes `GET /livez` and `GET /readyz` on port 8081 by default. Set `NAVISHAI_RUNNER_ADDRESS` to change the runner bind address.
