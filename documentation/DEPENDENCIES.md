# Dependency baseline

This inventory records the production dependencies approved for the repository bootstrap. `Gemfile.lock` is the exact Ruby dependency record. The Go runner uses only the standard library.

## Runtime pins

| Runtime | Version | Role |
|---|---:|---|
| Ruby | 4.0.6 | Rails control plane |
| Rails | 8.1.3.1 | Web, jobs, mail, storage, and application framework |
| PostgreSQL | 15 | Authoritative application, queue, cache, and cable state |
| pgvector | 0.8.1 | PostgreSQL vector type and search support |
| Go | 1.27.0 | Execution runner |

## Direct production gems

These gems come from the Rails 8.1 application generator and are approved by the build brief as Rails first-party or default dependencies.

| Gem | Role |
|---|---|
| `rails` | Rails framework |
| `propshaft` | Asset pipeline |
| `pg` | PostgreSQL driver |
| `puma` | Web server |
| `importmap-rails` | Pinned browser modules without a Node build step |
| `turbo-rails` | Hotwire navigation and updates |
| `stimulus-rails` | Small browser interactions |
| `bcrypt` | Password hashing for local authentication |
| `tzinfo-data` | Time-zone data on platforms that lack it |
| `solid_cache` | PostgreSQL-backed cache |
| `solid_queue` | PostgreSQL-backed jobs |
| `solid_cable` | PostgreSQL-backed Action Cable |
| `bootsnap` | Ruby boot cache |
| `image_processing` | Active Storage image variants |
| `ruby-vips` | Vips backend for Active Storage image variants |

Development and test gems are isolated to their Bundler groups. GitHub Dependabot tracks the Bundler lockfile and Go modules. GitHub Actions updates are paused while repository workflows remain manual-only. `script/sbom` emits the locked production gem graph as CycloneDX 1.6 JSON. The release review and patch rules are in [RELEASE.md](./RELEASE.md). Any later direct production gem, Go module, browser pin, service, or package needs owner approval unless the build brief already approves it.
