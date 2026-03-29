#!/bin/bash
# Phase 1: Fetch content piece text and send to Josh for approval via Telegram.
# Usage: linkedin-stage-post.sh <content_piece_id>
#
# Reads CLEARPATH_API_TOKEN and CLEARPATH_BASE_URL from env.
# On success:
#   - Prints the post text to stdout
#   - Sends text to Josh via Telegram asking for approval
#   - Writes text to /tmp/linkedin-pending-<piece_id>.txt for Phase 2

set -euo pipefail

PIECE_ID="${1:-}"
if [ -z "$PIECE_ID" ]; then
  echo "Usage: $0 <content_piece_id>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_DIR="$(dirname "$SCRIPT_DIR")"
BUS_DIR="$(dirname "$(dirname "$AGENT_DIR")")/core/bus"
TELEGRAM="$BUS_DIR/send-telegram.sh"
CHAT_ID="6690120787"

# Load env from agent .env if present
ENV_FILE="$AGENT_DIR/.env"
if [ -f "$ENV_FILE" ]; then
  set -o allexport
  source "$ENV_FILE"
  set +o allexport
fi

BASE_URL="${CLEARPATH_BASE_URL:-https://clearpath-production-c86d.up.railway.app}"
API_TOKEN="${CLEARPATH_API_TOKEN:-}"

if [ -z "$API_TOKEN" ]; then
  echo "ERROR: CLEARPATH_API_TOKEN not set. Add it to $ENV_FILE" >&2
  bash "$TELEGRAM" "$CHAT_ID" "LinkedIn post flow failed: CLEARPATH_API_TOKEN not configured in clearpath-dev .env"
  exit 1
fi

# Call stage-post endpoint
RESPONSE=$(curl -s -w "\n%{http_code}" \
  -X POST "$BASE_URL/api/grow/linkedin/stage-post" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"contentPieceId\": $PIECE_ID}")

HTTP_CODE=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" != "200" ]; then
  ERROR=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('error','Unknown error'))" 2>/dev/null || echo "$BODY")
  echo "ERROR: API returned $HTTP_CODE — $ERROR" >&2
  bash "$TELEGRAM" "$CHAT_ID" "LinkedIn stage-post failed for piece $PIECE_ID: $ERROR"
  exit 1
fi

TITLE=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('title','Untitled'))" 2>/dev/null)
TEXT=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('text',''))" 2>/dev/null)
STAGE=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('stage','unknown'))" 2>/dev/null)
FLAGS=$(echo "$BODY" | python3 -c "import sys,json; d=json.load(sys.stdin); flags=d.get('humanizerFlags',[]); print(', '.join(flags) if flags else 'none')" 2>/dev/null)

# Save text for Phase 2
PENDING_FILE="/tmp/linkedin-pending-${PIECE_ID}.txt"
echo "$TEXT" > "$PENDING_FILE"

# Send to Josh for approval
bash "$TELEGRAM" "$CHAT_ID" "LinkedIn draft ready for review (piece #${PIECE_ID}: ${TITLE}, stage: ${STAGE}):"
bash "$TELEGRAM" "$CHAT_ID" "$TEXT"

if [ "$FLAGS" != "none" ]; then
  bash "$TELEGRAM" "$CHAT_ID" "Humanizer flags: $FLAGS — review before approving."
fi

bash "$TELEGRAM" "$CHAT_ID" "Reply APPROVED to post this to LinkedIn, or send edits."

# Output text to stdout (for Frank to capture)
echo "$TEXT"
