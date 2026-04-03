#!/bin/bash
# Phase 2: Read pending LinkedIn post text (set by linkedin-stage-post.sh) and output it.
# The AGENT (not this script) handles Playwright — this script just retrieves the approved text.
#
# Usage: linkedin-fill-composer.sh <content_piece_id>
# Outputs: the post text to stdout, for the agent to paste into LinkedIn via Playwright MCP.

set -euo pipefail

PIECE_ID="${1:-}"
if [ -z "$PIECE_ID" ]; then
  echo "Usage: $0 <content_piece_id>" >&2
  exit 1
fi

PENDING_FILE="/tmp/linkedin-pending-${PIECE_ID}.txt"

if [ ! -f "$PENDING_FILE" ]; then
  echo "ERROR: No pending post found for piece $PIECE_ID. Run linkedin-stage-post.sh first." >&2
  exit 1
fi

cat "$PENDING_FILE"
