# syntax=docker/dockerfile:1.7
ARG RUBY_VERSION=3.4.10
FROM ruby:${RUBY_VERSION}-slim AS base

WORKDIR /rails
ENV RAILS_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_PATH=/usr/local/bundle BUNDLE_WITHOUT=development:test
RUN apt-get update -qq && apt-get install --no-install-recommends -y curl libpq5 libvips postgresql-client \
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
ENTRYPOINT ["/rails/bin/docker-entrypoint"]
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
