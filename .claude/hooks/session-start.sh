#!/bin/bash
# Claude Code on the web: prepare a fresh container so bin/ci and its evidence can run.
# Local sessions exit immediately; the repository-native script does the work.
set -euo pipefail

if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then
  exit 0
fi

cd "${CLAUDE_PROJECT_DIR:-$(pwd)}"
# The script appends browser-suite exports (CHROME_BIN, CHROMEDRIVER_BIN, CHROME_ARGS) to this file when it can.
NAVISHAI_CHECK_HOST_ENV="${CLAUDE_ENV_FILE:-}" script/prepare_check_host

ruby_prefix="/opt/ruby-$(tr -d '[:space:]' < .ruby-version)/bin"
if [ -d "$ruby_prefix" ] && [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  echo "export PATH=\"${ruby_prefix}:\$PATH\"" >> "$CLAUDE_ENV_FILE"
fi
