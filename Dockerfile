# syntax=docker/dockerfile:1.7
ARG RUBY_VERSION=4.0.7
FROM ruby:${RUBY_VERSION}-slim@sha256:38d10548b581179f1beb84d21554dbc0fffa668deb04338c67332f29f923f7e9 AS base

WORKDIR /rails
ENV RAILS_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_PATH=/usr/local/bundle BUNDLE_WITHOUT=development:test
# Debian trixie ships client 17, which cannot pg_dump a PostgreSQL 18 server. The
# PGDG repository key comes from Debian's signed postgresql-common package.
# Upgrade first so the base image's Debian packages (apt, zlib, ...) get current fixes.
RUN apt-get update -qq && apt-get upgrade -y --no-install-recommends \
  && apt-get install --no-install-recommends -y ca-certificates curl postgresql-common \
  && /usr/share/postgresql-common/pgdg/apt.postgresql.org.sh -y \
  && apt-get install --no-install-recommends -y libpq5 postgresql-client-18 \
  && rm -rf /var/lib/apt/lists/*
# Ruby bundles json 2.18.0 as a default gem, which has known advisories. Remove that
# copy; the build stage installs the locked json so bare `ruby -rjson` gets it too.
RUN ruby -rfileutils -e 'c = RbConfig::CONFIG; \
    paths = [ "#{c["rubylibdir"]}/json.rb", "#{c["rubylibdir"]}/json", "#{c["rubyarchdir"]}/json", *Dir["#{Gem.default_specifications_dir}/json-*.gemspec"] ]; \
    abort "Unexpected default json layout: #{paths}" unless paths.size == 4 && paths.all? { |path| File.exist?(path) }; \
    FileUtils.rm_r(paths)' \
  && ! ruby -e 'require "json"' 2>/dev/null

FROM base AS build
RUN apt-get update -qq && apt-get install --no-install-recommends -y build-essential git libpq-dev pkg-config \
  && rm -rf /var/lib/apt/lists/*
COPY Gemfile Gemfile.lock ./
# Bundler verifies each .gem against the Gemfile.lock checksums. Install that same
# json outside the bundle too, so Ruby without Bundler loads the locked version.
RUN bundle install \
  && gem install --local --no-document /usr/local/bundle/ruby/*/cache/json-[0-9]*.gem \
  && rm -rf /root/.bundle /usr/local/bundle/ruby/*/cache
COPY . .
RUN SECRET_KEY_BASE_DUMMY=1 NAVISHAI_APP_HOST=example.invalid bin/rails assets:precompile

FROM base
COPY --from=build /usr/local/bundle /usr/local/bundle
COPY --from=build /rails /rails
RUN json="$(ruby -rjson -e 'print JSON::VERSION')" && bundled="$(bundle exec ruby -rjson -e 'print JSON::VERSION')" \
  && test -n "$json" && test "$json" = "$bundled" \
  && groupadd --system --gid 1000 navishai && useradd --uid 1000 --gid 1000 --create-home --shell /bin/bash navishai \
  && chown -R navishai:navishai log storage tmp
USER 1000:1000
EXPOSE 3000
CMD ["bin/rails", "server", "-b", "0.0.0.0"]
