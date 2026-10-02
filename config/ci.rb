CI.run do
  step "Setup", "bin/setup --skip-server"
  step "Style: Ruby", "bin/rubocop"
  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Eager loading", "bin/rails zeitwerk:check"
  step "Tests: Rails", "bin/rails test"
  step "Tests: Rails system", "bin/rails test:system"
end
