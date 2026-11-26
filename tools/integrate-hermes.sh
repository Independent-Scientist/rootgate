#!/bin/bash
# integrate-hermes.sh — wire rootgate into a Hermes Agent install (no root).
#
# Run as the user that runs Hermes, after ./install.sh has been run as root:
#     ./integrate-hermes.sh
#
# It registers the MCP server and installs the behaviour skill. Both are
# user-level; nothing here needs sudo.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
HERMES_HOME=${HERMES_HOME:-$HOME/.hermes}
MCP_BIN=${MCP_BIN:-/usr/local/sbin/rootgate-mcp}
SKILL_DIR=$HERMES_HOME/skills/security/rootgate-escalation

say() { printf '\n== %s\n' "$*"; }

say "checking the broker"
[ -x "$MCP_BIN" ] || { echo "missing $MCP_BIN — run: sudo ./install.sh" >&2; exit 1; }
command -v hermes >/dev/null || { echo "hermes not on PATH; is this the machine that runs it?" >&2; exit 1; }
echo "mcp server: $MCP_BIN"

say "registering the MCP server"
if hermes mcp list 2>/dev/null | grep -q '^ *rootgate'; then
	echo "already registered"
else
	# the add command ends with an interactive tool-selection prompt
	printf 'Y\n' | hermes mcp add rootgate --command "$MCP_BIN" | tail -3
fi
hermes mcp test rootgate 2>&1 | tail -3 || {
	echo "the server did not answer — check: systemctl status rootgate" >&2
	exit 1
}

say "installing the skill"
mkdir -p "$SKILL_DIR"
install -m 0644 "$HERE/skill/SKILL.md" "$SKILL_DIR/SKILL.md"
echo "$SKILL_DIR/SKILL.md"

say "done — two things left for a human"
cat <<EOF
  1. In the running Hermes session, type:  /reload-mcp
     (toolsets are fixed when a session starts; a new session also works)
  2. Configure the approval channel on this host:
       sudo \$EDITOR /etc/rootgate/config.json     # notify: console | telegram | ntfy
       sudo \$EDITOR /etc/rootgate/secrets         # bot token / chat id, 0600 root
       sudo systemctl restart rootgate

  Test it from an unprivileged shell:
       echo 'id -un' > /tmp/whoami.sh
       rootgate submit /tmp/whoami.sh --desc "smoke test" --name manual
EOF
