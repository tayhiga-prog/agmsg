#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   send.sh <team> <from> <to> <message>
#   send.sh --channel <team> <from> <channel> <message>

MODE="direct"
if [ "${1:-}" = "--channel" ]; then
  MODE="channel"
  shift
fi

TEAM="${1:?Usage: send.sh [--channel] <team> <from> <to|channel> <message>}"
FROM="${2:?Missing from agent}"
TO="${3:?Missing to agent or channel}"
BODY="${4:?Missing message body}"

if [ $# -gt 4 ]; then
  echo "Error: too many arguments ($# given, expected 4 after flags)." >&2
  echo "  The message must be a single quoted argument." >&2
  echo "  send.sh <team> <from> <to> \"your message here\"" >&2
  echo "  Simpler:  msg.sh <to> \"<message>\"" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/storage.sh"
DB="$(agmsg_db_path)"

# --- Argument validation (catch common swap/misuse errors) ---
TEAMS_DIR="$SCRIPT_DIR/../teams"

_smells_like_path() { case "$1" in */*|*\\*) return 0 ;; esac; return 1; }
_smells_like_session_id() {
  case "$1" in
    ????????-????-????-????-????????????) return 0 ;;
  esac
  return 1
}

if [ ! -d "$TEAMS_DIR/$TEAM" ]; then
  echo "Error: team '$TEAM' does not exist." >&2
  if _smells_like_session_id "$TEAM" || _smells_like_path "$TEAM"; then
    echo "  It looks like a session ID or path was passed as the team name." >&2
    echo "  Arguments may be in the wrong order." >&2
  fi
  echo "" >&2
  echo "  Correct:  send.sh <team> <from> <to> <message>" >&2
  echo "    arg 1 = team name    (e.g. crm_lab)" >&2
  echo "    arg 2 = your name    (e.g. kanbei-claude)" >&2
  echo "    arg 3 = recipient    (e.g. kindaichi)" >&2
  echo "    arg 4 = message text (quoted)" >&2
  if [ -d "$TEAMS_DIR" ]; then
    available=$(ls -1 "$TEAMS_DIR" 2>/dev/null | paste -sd, -)
    [ -n "$available" ] && echo "  Available teams: $available" >&2
  fi
  echo "" >&2
  echo "  Simpler:  msg.sh <to> <message>  (auto-resolves team and from)" >&2
  exit 1
fi

_smells_like_agent_type() {
  case "$1" in
    claude-code|codex|antigravity|gemini|copilot) return 0 ;;
  esac
  return 1
}

if _smells_like_path "$FROM" || _smells_like_session_id "$FROM"; then
  echo "Error: from-agent '$FROM' looks like a path or session ID." >&2
  echo "  Arg 2 must be your agent name, not a path." >&2
  echo "  Simpler:  msg.sh <to> <message>" >&2
  exit 1
fi

if _smells_like_agent_type "$FROM"; then
  echo "Error: from-agent '$FROM' is an agent type, not an agent name." >&2
  echo "  Arg 2 must be your identity (e.g. kanbei-claude), not the CLI type." >&2
  echo "  Simpler:  msg.sh <to> <message>" >&2
  exit 1
fi

if _smells_like_path "$TO" || _smells_like_session_id "$TO"; then
  echo "Error: to-agent '$TO' looks like a path or session ID." >&2
  echo "  Arg 3 must be the recipient agent name, not a path." >&2
  echo "  Simpler:  msg.sh <to> <message>" >&2
  exit 1
fi

# In direct mode, verify TO is a registered member of the team.
# Channel mode validates recipients via resolve-channel-members.sh instead.
if [ "$MODE" = "direct" ]; then
  CONFIG="$TEAMS_DIR/$TEAM/config.json"
  if [ -f "$CONFIG" ]; then
    _to_esc=$(printf '%s' "$TO" | sed "s/'/''/g")
    _to_registered=$(sqlite3 :memory: \
      ".param set :json '$(sed "s/'/''/g" "$CONFIG")'" \
      "SELECT 1 FROM json_each(json_extract(:json, '\$.agents')) WHERE key='$_to_esc' LIMIT 1;" \
      2>/dev/null | tr -d '\r')
    if [ -z "$_to_registered" ]; then
      _members=$(sqlite3 :memory: \
        ".param set :json '$(sed "s/'/''/g" "$CONFIG")'" \
        "SELECT key FROM json_each(json_extract(:json, '\$.agents'));" \
        2>/dev/null | tr -d '\r')
      echo "Error: to-agent '$TO' is not a member of team '$TEAM'." >&2
      if [ -n "$_members" ]; then
        echo "  Members: $(printf '%s\n' "$_members" | paste -sd, -)" >&2
      fi
      echo "  Simpler:  msg.sh <to> <message>" >&2
      exit 1
    fi
  fi
fi

[ -f "$DB" ] || bash "$SCRIPT_DIR/init-db.sh" >/dev/null

sql_escape() { printf '%s' "$1" | sed "s/'/''/g"; }

if [ "$MODE" = "direct" ]; then
  INSERT="INSERT INTO messages (team, from_agent, to_agent, body) VALUES ('$(sql_escape "$TEAM")', '$(sql_escape "$FROM")', '$(sql_escape "$TO")', '$(sql_escape "$BODY")');"

  # Retry once after ensuring the schema. Under a concurrent first-write fan-out
  # (leader → N members against a fresh/override store), one process can see the
  # DB file exist before the winning initializer has finished creating the table,
  # so its INSERT would hit "no such table". init-db.sh is idempotent + uses the
  # busy_timeout, so re-running it waits for the schema, then the INSERT lands.
  # See #114.
  if ! agmsg_sqlite "$DB" "$INSERT" 2>/dev/null; then
    bash "$SCRIPT_DIR/init-db.sh" >/dev/null
    agmsg_sqlite "$DB" "$INSERT"
  fi

  echo "Sent to $TO in team $TEAM"
  exit 0
fi

CHANNEL="$TO"
bash "$SCRIPT_DIR/init-db.sh" >/dev/null
CHANNEL_ADDR="@channel"
TEAM_ESC=$(sql_escape "$TEAM")
FROM_ESC=$(sql_escape "$FROM")
CHANNEL_ESC=$(sql_escape "$CHANNEL")
BODY_ESC=$(sql_escape "$BODY")
CHANNEL_ADDR_ESC=$(sql_escape "$CHANNEL_ADDR")

members="$("$SCRIPT_DIR/resolve-channel-members.sh" "$TEAM" "$CHANNEL")"
if [ -z "$members" ]; then
  echo "No channel recipients resolved for $TEAM/$CHANNEL" >&2
  exit 1
fi

delivery_values=""
while IFS= read -r member; do
  [ -z "$member" ] && continue
  member_esc=$(sql_escape "$member")
  delivery_values="${delivery_values}INSERT OR IGNORE INTO message_deliveries (message_id, team, to_agent) VALUES (_MSG_ID_, '$TEAM_ESC', '$member_esc');"$'\n'
done <<< "$members"

if [ -z "$delivery_values" ]; then
  echo "No channel recipients resolved for $TEAM/$CHANNEL" >&2
  exit 1
fi

sql=$(cat <<SQL
BEGIN IMMEDIATE;
INSERT INTO messages (team, from_agent, to_agent, body, kind, channel)
VALUES ('$TEAM_ESC', '$FROM_ESC', '$CHANNEL_ADDR_ESC', '$BODY_ESC', 'channel', '$CHANNEL_ESC');
CREATE TEMP TABLE _agmsg_new_message_id(id INTEGER);
INSERT INTO _agmsg_new_message_id VALUES (last_insert_rowid());
SQL
)

while IFS= read -r line; do
  [ -z "$line" ] && continue
  sql="${sql}"$'\n'"${line//_MSG_ID_/(SELECT id FROM _agmsg_new_message_id)}"
done <<< "$delivery_values"

sql="${sql}"$'\n'"DROP TABLE _agmsg_new_message_id;"$'\n'"COMMIT;"

if ! agmsg_sqlite "$DB" "$sql" 2>/dev/null; then
  bash "$SCRIPT_DIR/init-db.sh" >/dev/null
  agmsg_sqlite "$DB" "$sql"
fi

count=$(printf '%s\n' "$members" | sed '/^$/d' | wc -l | tr -d ' ')
echo "Broadcast to channel $CHANNEL in team $TEAM ($count recipient(s))"
