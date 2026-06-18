#!/usr/bin/env bash
set -euo pipefail

# msg.sh — simplified message sender (auto-resolves team and from).
#
# Usage:
#   msg.sh <to> <message>
#   msg.sh --from <name> <to> <message>
#   msg.sh --channel <channel> <message>
#   msg.sh --type <type> <to> <message>
#   msg.sh --project <path> <to> <message>
#
# Eliminates the 4-positional-arg footgun of send.sh by resolving team
# and from-agent automatically from the project directory, agent type,
# and actas lock state.
#
# For REGISTERED agents only. Service identities (e.g. GM, gm-auto)
# that are not in teams/*/config.json must use send.sh directly.

MODE="direct"
PROJECT_PATH=""
AGENT_TYPE=""
FROM_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --project)  PROJECT_PATH="$2"; shift 2 ;;
    --type)     AGENT_TYPE="$2"; shift 2 ;;
    --from)     FROM_OVERRIDE="$2"; shift 2 ;;
    --channel)  MODE="channel"; shift ;;
    --)         shift; break ;;
    -*)         echo "Error: unknown flag '$1'" >&2
                echo "Usage: msg.sh [--from <name>] [--type <type>] [--project <path>] [--channel] <to> <message>" >&2
                exit 1 ;;
    *)          break ;;
  esac
done

TO="${1:?Usage: msg.sh <to> \"<message>\"}"
MESSAGE="${2:?Missing message body. Usage: msg.sh <to> \"<message>\"}"

if [ $# -gt 2 ]; then
  echo "Error: too many positional arguments ($# given, expected 2)." >&2
  echo "The message must be quoted as a single argument." >&2
  echo "  msg.sh $TO \"your message here\"" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
export SKILL_DIR
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/resolve-project.sh"

[ -z "$PROJECT_PATH" ] && PROJECT_PATH="$(pwd)"

# --- Auto-detect agent type ---
DETECTED_TYPE=""
if [ -z "$AGENT_TYPE" ]; then
  if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
    DETECTED_TYPE="claude-code"
  elif [ -n "${CODEX_SANDBOX:-}" ] || [ -n "${CODEX_THREAD_ID:-}" ]; then
    DETECTED_TYPE="codex"
  elif [ -n "${GOOGLE_GEMINI_CLI:-}" ]; then
    DETECTED_TYPE="gemini"
  else
    DETECTED_TYPE="claude-code"
  fi
  AGENT_TYPE="$DETECTED_TYPE"
fi

PROJECT_PATH="$(agmsg_resolve_project "$PROJECT_PATH" "$AGENT_TYPE")"

# --- Resolve identity ---
PAIRS="$("$SCRIPT_DIR/identities.sh" "$PROJECT_PATH" "$AGENT_TYPE" 2>/dev/null || true)"

# Fallback: if auto-detected type finds nothing, try all known types
if [ -z "$PAIRS" ] && [ -n "$DETECTED_TYPE" ]; then
  for try_type in claude-code codex antigravity gemini copilot; do
    [ "$try_type" = "$DETECTED_TYPE" ] && continue
    PAIRS="$("$SCRIPT_DIR/identities.sh" "$PROJECT_PATH" "$try_type" 2>/dev/null || true)"
    if [ -n "$PAIRS" ]; then
      AGENT_TYPE="$try_type"
      break
    fi
  done
fi

if [ -z "$PAIRS" ]; then
  echo "Error: no identity found for this project." >&2
  echo "Run whoami.sh first, then join.sh to register." >&2
  exit 1
fi

TEAM=""
FROM=""
TEAMS_DIR="$SCRIPT_DIR/../teams"

# Helper: check if an agent name is a member of a team's config.
_is_team_member() {
  local team="$1" name="$2" config
  config="$TEAMS_DIR/$team/config.json"
  [ -f "$config" ] || return 1
  local found
  found=$(sqlite3 :memory: ".param set :json '$(sed "s/'/''/g" "$config")'" \
    "SELECT 1 FROM json_each(json_extract(:json, '\$.agents')) WHERE key='$name' LIMIT 1;" 2>/dev/null | tr -d '\r')
  [ -n "$found" ]
}

# Helper: list members of a team.
_team_members() {
  local team="$1" config
  config="$TEAMS_DIR/$team/config.json"
  [ -f "$config" ] || return 0
  sqlite3 :memory: ".param set :json '$(sed "s/'/''/g" "$config")'" \
    "SELECT key FROM json_each(json_extract(:json, '\$.agents'));" 2>/dev/null | tr -d '\r'
}

# --from override: find the team where both FROM and TO coexist
if [ -n "$FROM_OVERRIDE" ]; then
  FROM_TEAMS=""
  while IFS=$'\t' read -r _team _agent; do
    [ -z "$_team" ] && continue
    [ "$_agent" = "$FROM_OVERRIDE" ] && FROM_TEAMS="${FROM_TEAMS:+$FROM_TEAMS$'\n'}$_team"
  done <<< "$PAIRS"
  if [ -z "$FROM_TEAMS" ]; then
    echo "Error: --from '$FROM_OVERRIDE' is not registered in any team for this project." >&2
    echo "Registered agents: $(printf '%s\n' "$PAIRS" | cut -f2 | paste -sd, -)" >&2
    echo "Service identities (GM, gm-auto, etc.) must use send.sh directly." >&2
    exit 1
  fi
  FROM="$FROM_OVERRIDE"
  TEAM=$(printf '%s\n' "$FROM_TEAMS" | head -1)
else
  AGENT_COUNT=$(printf '%s\n' "$PAIRS" | cut -f2 | sort -u | wc -l | tr -d ' ')

  if [ "$AGENT_COUNT" -eq 1 ]; then
    TEAM=$(printf '%s\n' "$PAIRS" | head -1 | cut -f1)
    FROM=$(printf '%s\n' "$PAIRS" | head -1 | cut -f2)
  else
    # Multiple identities — find the one locked to this session via actas
    SESSION_ID="${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-}}"
    FOUND=""
    if [ -n "$SESSION_ID" ]; then
      # shellcheck disable=SC1091
      source "$SCRIPT_DIR/lib/actas-lock.sh"
      while IFS=$'\t' read -r _team _agent; do
        [ -z "$_team" ] && continue
        state=$(actas_lock_state "$_team" "$_agent" "$SESSION_ID" 2>/dev/null || echo "free")
        if [ "$state" = "mine" ]; then
          FOUND="${_team}	${_agent}"
          break
        fi
      done <<< "$PAIRS"
    fi
    if [ -n "$FOUND" ]; then
      TEAM=$(printf '%s' "$FOUND" | cut -f1)
      FROM=$(printf '%s' "$FOUND" | cut -f2)
    else
      echo "Error: multiple identities registered — cannot auto-resolve sender." >&2
      echo "Registered: $(printf '%s\n' "$PAIRS" | cut -f2 | paste -sd, -)" >&2
      echo "Use: msg.sh --from <your_name> $TO \"...\"" >&2
      exit 1
    fi
  fi
fi

# --- Unified TO cross-resolution (direct mode only) ---
# Collects all teams where FROM is registered, then picks the one where
# TO is also a member. Handles single-team, multi-team, --from, and
# actas branches uniformly.
if [ "$MODE" = "direct" ] && [ -n "$FROM" ]; then
  ALL_FROM_TEAMS=""
  while IFS=$'\t' read -r _team _agent; do
    [ -z "$_team" ] && continue
    [ "$_agent" = "$FROM" ] && ALL_FROM_TEAMS="${ALL_FROM_TEAMS:+$ALL_FROM_TEAMS$'\n'}$_team"
  done <<< "$PAIRS"

  MATCHED_TEAM=""
  MATCHED_COUNT=0
  while IFS= read -r _try_team; do
    [ -z "$_try_team" ] && continue
    if _is_team_member "$_try_team" "$TO"; then
      MATCHED_TEAM="$_try_team"
      MATCHED_COUNT=$((MATCHED_COUNT + 1))
    fi
  done <<< "$ALL_FROM_TEAMS"

  case "$MATCHED_COUNT" in
    0)
      _members=$(_team_members "$TEAM")
      echo "Error: '$TO' is not a member of any team where '$FROM' is registered." >&2
      if [ -n "$_members" ]; then
        echo "Members of $TEAM: $(printf '%s\n' "$_members" | paste -sd, -)" >&2
      fi
      exit 1
      ;;
    1) TEAM="$MATCHED_TEAM" ;;
    *)
      echo "Error: '$FROM' and '$TO' share multiple teams. Ambiguous." >&2
      exit 1
      ;;
  esac
fi

# --- Delegate to send.sh ---
if [ "$MODE" = "channel" ]; then
  exec "$SCRIPT_DIR/send.sh" --channel "$TEAM" "$FROM" "$TO" "$MESSAGE"
else
  exec "$SCRIPT_DIR/send.sh" "$TEAM" "$FROM" "$TO" "$MESSAGE"
fi
