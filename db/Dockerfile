# Official PostgreSQL 18 with refreshed Debian packages and a rebuilt gosu.
# Same Debian (glibc) image, UID/GID 999, PGDATA and entrypoint as upstream; never
# switch to Alpine: musl collation differs and would corrupt existing text indexes.
# Works with the classic builder too (no BuildKit-only syntax).

# Upstream gosu 1.20 ships built with Go 1.24.6 and golang.org/x/sys v0.1.0.
# Rebuild the same tagged source with a current toolchain and tagged modules.
FROM golang:1.27.3-trixie@sha256:af1bfc2614ebb1dbd31af514b78740fd678850e76498762b425ecee4c5c6ea80 AS gosu
ARG GOSU_VERSION=1.20
ARG GOSU_COMMIT=29b939aa5bd4dc588af765b8248f6e39150d2565
ENV CGO_ENABLED=0 GOTOOLCHAIN=local
WORKDIR /src/gosu
RUN set -eux; \
  git init -q .; \
  git fetch -q --depth 1 https://github.com/tianon/gosu.git "refs/tags/$GOSU_VERSION"; \
  git checkout -q FETCH_HEAD; \
  test "$(git rev-parse HEAD)" = "$GOSU_COMMIT"; \
  grep -qx "const Version = \"$GOSU_VERSION\"" version.go
RUN set -eux; \
  go get github.com/moby/sys/user@v0.5.0 golang.org/x/sys@v0.49.0; \
  go mod tidy; \
  go mod verify
# Upstream's flags: static, no DWARF, symbols kept so govulncheck/Trivy can read it.
RUN set -eux; \
  go build -v -trimpath -buildvcs=false -ldflags '-d -w' -o /out/gosu .; \
  go version -m /out/gosu; \
  /out/gosu --version; \
  /out/gosu nobody true

FROM postgres:18@sha256:e3d24f6906d0760bf4da0dae872415391ededefad23fd471c47dc53b0ddf3c42
# Debian fixes only. PostgreSQL packages stay at the official image's PG_VERSION;
# move them by changing the digest above, never through an apt upgrade here.
RUN set -eux; \
  dpkg-query -W -f '${Package}\n' | grep -E '^(postgresql|libpq)' | xargs apt-mark hold; \
  apt-get update; \
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y --no-install-recommends; \
  rm -rf /var/lib/apt/lists/*; \
  test "$(dpkg-query -W -f '${Version}' "postgresql-$PG_MAJOR")" = "$PG_VERSION"; \
  locale -a | grep -qx 'en_US.utf8'
# Same path, root:root 0755 and no setuid bit as the upstream binary, so
# docker-entrypoint.sh drops to the postgres user exactly as before.
COPY --from=gosu /out/gosu /usr/local/bin/gosu
RUN set -eux; \
  test "$(stat -c '%u:%g %a' /usr/local/bin/gosu)" = '0:0 755'; \
  gosu --version | grep -q '^1\.20 (go1\.27\.'; \
  gosu nobody true
