# syntax=docker/dockerfile:1.7
FROM golang:1.27.1-bookworm@sha256:648f440f42a0958804efb24df176f806f9d353b41f1c0627f666428e40310f6b AS build
WORKDIR /src
RUN apt-get update -qq && apt-get install --no-install-recommends -y libreofficekit-dev \
  && rm -rf /var/lib/apt/lists/*
COPY go.mod ./
COPY runner runner
RUN go build -trimpath -o /out/navishai-runner ./runner/cmd/navishai-runner \
  && go build -trimpath -o /out/navishai-exec ./runner/cmd/navishai-exec \
  && cc -std=c11 -O2 -Wall -Wextra -Werror -o /out/navishai-netns-launch runner/cmd/navishai-netns-launch/main.c \
  && cc -O2 -Wall -Wextra -Werror -o /out/navishai-document runner/cmd/navishai-document/main.c -ldl

FROM debian:bookworm-slim@sha256:abd67ffcfa541b485a3dff59865ab629aa048a6c613e639d36e7456b0b229241
RUN apt-get update -qq && apt-get install --no-install-recommends -y ca-certificates libreoffice-writer \
  && test -x /usr/lib/libreoffice/program/soffice.bin \
  && mkdir -p /usr/share/navishai \
  && dpkg-query -W > /usr/share/navishai/runner-packages.txt \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --uid 1000 --create-home --shell /usr/sbin/nologin navishai
COPY --from=build /out/* /usr/local/bin/
COPY ops/runner/execution.example.json /etc/navishai/execution.json
RUN mkdir -p /var/lib/navishai /var/lib/navishai/runs && chown -R navishai:navishai /var/lib/navishai
USER 1000:1000
WORKDIR /var/lib/navishai
EXPOSE 8081
ENTRYPOINT ["/usr/local/bin/navishai-runner"]
