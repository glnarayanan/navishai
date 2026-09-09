# Run using bin/ci

CI.run do
  step "Setup", "bin/setup --skip-server"

  step "Style: Ruby", "bin/rubocop"
  step "Style: Go", "test -z \"$(gofmt -l runner)\""

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis", "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"
  step "Tests: Rails", "bin/rails test"
  step "Tests: Rails system", "bin/rails test:system"
  step "Tests: Runner", "go vet ./... && NAVISHAI_REQUIRE_ISOLATION_TESTS=1 go test ./... && go build -o tmp/navishai-runner ./runner/cmd/navishai-runner && go build -o tmp/navishai-exec ./runner/cmd/navishai-exec && cc -std=c11 -O2 -Wall -Wextra -Werror -o tmp/navishai-netns-launch runner/cmd/navishai-netns-launch/main.c"
  step "Tests: Rails and Go runner contract", "script/runner_contract"
  step "Tests: Legacy Word conversion", "NAVISHAI_TEST_DOC_FIXTURE=\"$PWD/test/fixtures/files/knowledge-legacy.doc\" NAVISHAI_TEST_EXEC_HELPER=\"$PWD/tmp/navishai-exec\" go test ./runner/internal/documents -run TestInstalledLibreOffice -count=1"
  step "Tests: Seeds", "env RAILS_ENV=test bin/rails db:seed:replant"
  step "Supply chain: SBOM", "script/sbom --check"

  # Optional: set a green GitHub commit status to unblock PR merge.
  # Requires the `gh` CLI and `gh extension install basecamp/gh-signoff`.
  # if success?
  #   step "Signoff: All systems go. Ready for merge and deploy.", "gh signoff"
  # else
  #   failure "Signoff: CI failed. Do not merge or deploy.", "Fix the issues and try again."
  # end
end
