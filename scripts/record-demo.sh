#!/usr/bin/env bash
# Orchestrates one clean, paced run of beats 1-3 so you can screen-record
# it as the fallback video. Beat 4 is deliberately excluded -- it needs a
# real git commit/push mid-beat and is presenter-terminal throughout, not
# something to auto-run unattended. This script does NOT do the screen
# recording itself -- start QuickTime / OBS / `screencapture` first, with
# both the browser (storefront + Agentic Workflow panel) and this
# terminal visible, THEN run this script.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"

PAUSE="${PAUSE_SECONDS:-4}"
pause() { echo; sleep "$PAUSE"; }

log "resetting to a clean state"
"$REPO_ROOT/scripts/reset.sh"
pause

log "=== BEAT 1: standing access ==="
"$REPO_ROOT/scripts/demo-beat1.sh"
pause

log "=== BEAT 2: verified identity, no credential to steal ==="
"$REPO_ROOT/scripts/demo-beat2.sh"
pause

log "=== BEAT 3: policy on every call, and human intent ==="
"$REPO_ROOT/scripts/demo-beat3.sh" "${1:-}"

log "done -- stop the recording."
