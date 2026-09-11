# Dependency baseline

This inventory records the production dependencies approved for the repository bootstrap. `Gemfile.lock` is the exact Ruby dependency record. The Go runner uses only the standard library.

## Runtime pins

| Runtime | Version | Role |
|---|---:|---|
| Ruby | 4.0.6 | Rails control plane |
| Rails | 8.1.3.1 | Web, jobs, mail, storage, and application framework |
| PostgreSQL | 16 | Authoritative application, queue, cache, and cable state |
| pgvector | 0.8.6 | PostgreSQL vector type and search support |
| Go | 1.27.1 | Execution runner |

## Direct production gems

These gems come from the Rails 8.1 application generator and are approved by [PRODUCT.md](./PRODUCT.md) as Rails first-party or default dependencies, plus the owner-approved additions noted in the table.

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
| `pdf-reader` | Owner-approved on 6 September 2026 for knowledge PDF text extraction; pure Ruby, bounded by page and byte limits in `KnowledgeDocumentExtractor` |
| `bigdecimal` | Owner-approved on 11 September 2026 as a `>= 4.0` floor on an existing transitive dependency of Active Support and pdf-reader's `ttfunk`, keeping it on the maintained line; this holds `ttfunk` at 1.7.0 until a release accepts bigdecimal 4 |

## Services, images, and bundled assets

These non-gem production dependencies are pinned in the repository and approved by [PRODUCT.md](./PRODUCT.md). Each needs the same review as a gem before it changes.

| Dependency | Pin | Role |
|---|---|---|
| Supermemory Local server | 0.0.8 with per-platform SHA-256 in `script/install_supermemory` | Self-hosted memory index and retrieval engine |
| `pgvector/pgvector` image | `0.8.6-pg16` by digest in `compose.yaml`, `.github/workflows/ci.yml`, and the Compose tooling | PostgreSQL 16 with pgvector for Compose and CI |
| Container base images | SHA-256 digests in `Dockerfile` and `ops/docker/*.Dockerfile` | Rails, runner, and Supermemory images |
| LibreOffice Writer | Debian Bookworm security-maintained `libreoffice-writer` package; exact installed versions recorded in `/usr/share/navishai/runner-packages.txt` in the runner image | Owner-approved on 7 September 2026, bundled for isolated legacy DOC text extraction; `libreofficekit-dev` headers are build-only. The 9 September native check used package version `4:7.4.7-1+deb12u14` from source package `libreoffice`. |
| Caddy | `caddy:2.10.2-alpine` | Owner-approved on 10 September 2026 for guided Compose HTTPS. It is the sole public app ingress, retains ACME account and certificate state in named volumes, and has its admin API disabled. It keeps only `NET_BIND_SERVICE` so it can bind 80 and 443; the candidate path still needs digest pinning and renewal proof before release. |
| Geist and Geist Mono | Variable WOFF2 files under `app/assets/fonts` | Self-hosted interface type |

Optional deployment-run services are configured only when used and are not shipped by NavishAI: an S3-compatible object store, a SearXNG search origin, the hosted Exa or Tavily search APIs (API key held on the runner only), a ClamAV daemon for the reference attachment scanner, and the customer's own provider subscriptions or API keys. The runner's direct provider connections call the fixed OpenAI and Anthropic API hosts through the Go standard library; no provider SDK is bundled.

Development and test gems are isolated to their Bundler groups. GitHub Dependabot tracks the Bundler lockfile and Go modules. GitHub Actions updates are paused while repository workflows remain manual-only. `script/sbom` emits the locked production gem graph as CycloneDX 1.6 JSON. The release review and patch rules are in [RELEASE.md](./RELEASE.md). Any later direct production gem, Go module, browser pin, service, or package needs owner approval unless PRODUCT.md already approves it.
