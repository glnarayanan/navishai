# syntax=docker/dockerfile:1.7
FROM golang:1.27.0-bookworm AS build
WORKDIR /src
COPY go.mod ./
COPY runner runner
RUN go build -trimpath -o /out/navishai-runner ./runner/cmd/navishai-runner \
  && go build -trimpath -o /out/navishai-exec ./runner/cmd/navishai-exec \
  && cc -std=c11 -O2 -Wall -Wextra -Werror -o /out/navishai-netns-launch runner/cmd/navishai-netns-launch/main.c

FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install --no-install-recommends -y ca-certificates \
  && rm -rf /var/lib/apt/lists/* \
  && useradd --uid 1000 --create-home --shell /usr/sbin/nologin navishai
COPY --from=build /out/* /usr/local/bin/
RUN mkdir -p /var/lib/navishai /var/lib/navishai/runs && chown -R navishai:navishai /var/lib/navishai
USER 1000:1000
WORKDIR /var/lib/navishai
EXPOSE 8081
ENTRYPOINT ["/usr/local/bin/navishai-runner"]
