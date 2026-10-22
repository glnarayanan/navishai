# syntax=docker/dockerfile:1.7
ARG RUBY_VERSION=4.0.7
FROM ruby:${RUBY_VERSION}-slim@sha256:38d10548b581179f1beb84d21554dbc0fffa668deb04338c67332f29f923f7e9 AS base

WORKDIR /rails
ENV RAILS_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_PATH=/usr/local/bundle BUNDLE_WITHOUT=development:test
# Debian trixie ships client 17, which cannot pg_dump a PostgreSQL 18 server. The
# PGDG repository key comes from Debian's signed postgresql-common package.
RUN apt-get update -qq && apt-get install --no-install-recommends -y ca-certificates curl postgresql-common \
  && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
  && apt-get install --no-install-recommends -y libpq5 postgresql-client-18 \
  && rm -rf /var/lib/apt/lists/*

FROM base AS build
RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
RUN bundle install && rm -rf /root/.bundle /usr/local/bundle/ruby/*/cache
COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 NAVISHAI_APP_HOST=example.invalid bin/rails assets:precompile

FROM base
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails
RUN groupadd --system --gid 1000 navishai && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash navishai \
  && chown -R navishai:navishai log storage tmp
USER 1000:1000
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
