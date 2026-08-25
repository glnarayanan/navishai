# syntax=docker/dockerfile:1.7
FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
RUN apt-get update -qq && apt-get install --no-install-recommends -y ca-certificates curl \
  && rm -rf /var/lib/apt/lists/*
WORKDIR /opt/navishai
COPY script/install_supermemory script/install_supermemory
RUN script/install_supermemory \
  && useradd --uid 1000 --create-home --shell /usr/sbin/nologin supermemory \
  && mkdir -p /var/lib/supermemory \
  && chown -R supermemory:supermemory /var/lib/supermemory
USER 1000:1000
ENV SUPERMEMORY_DATA_DIR=/var/lib/supermemory SUPERMEMORY_DISABLE_TELEMETRY=1
EXPOSE 6767
ENTRYPOINT ["/opt/navishai/tmp/supermemory/bin/supermemory-server"]
