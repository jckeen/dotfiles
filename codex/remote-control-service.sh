#!/usr/bin/env bash
# Foreground server for codex-remote-control.service; never manage native daemons.
# Verification: python3 codex/tests/test_remote_control_service.py
set -eo pipefail

codex_state="${CODEX_HOME:-$HOME/.codex}"
if ! jq -e '.remoteControlEnabled == true' \
    "$codex_state/app-server-daemon/settings.json" >/dev/null 2>&1; then
  echo "Codex Remote Control is not enabled in $codex_state/app-server-daemon/settings.json" >&2
  exit 78
fi

# User services do not source interactive shell startup files. Include the
# usual user tools and let NVM resolve its current default rather than pinning
# a Node release that will disappear on the next upgrade.
export PATH="$HOME/.local/bin:$HOME/.bun/bin:$HOME/.cargo/bin:$PATH"
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
if [ -s "$NVM_DIR/nvm.sh" ]; then
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
fi

# The standalone CLI is authoritative even when PATH contains an older npm CLI.
# Native socket binding refuses an existing listener and recovers stale sockets.
exec "$HOME/.local/bin/codex" app-server --remote-control --listen unix://
