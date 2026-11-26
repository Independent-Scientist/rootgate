#!/bin/bash
# install.sh — install rootgate (root). Nothing here runs an agent's code.
#
#   sudo ./install.sh
#
# Then edit /etc/rootgate/config.json (notify backend) and
# /etc/rootgate/secrets (bot token / ntfy credentials, if used).
set -euo pipefail

[ "$(id -u)" -eq 0 ] || { echo "run me with sudo" >&2; exit 1; }
HERE=$(cd "$(dirname "$0")" && pwd)

install -o root -g root -m 0755 "$HERE/rootgate" /usr/local/sbin/rootgate
install -o root -g root -m 0755 "$HERE/rootgate-mcp" /usr/local/sbin/rootgate-mcp
install -d -o root -g root -m 0755 /usr/local/share/doc/rootgate
install -o root -g root -m 0644 "$HERE/README.md" /usr/local/share/doc/rootgate/README.md
install -d -o root -g root -m 0755 /usr/local/share/doc/rootgate/deploy /usr/local/share/doc/rootgate/skill
install -o root -g root -m 0644 "$HERE"/deploy/* /usr/local/share/doc/rootgate/deploy/
cp -a "$HERE"/skill/* /usr/local/share/doc/rootgate/skill/

install -d -o root -g root -m 0755 /etc/rootgate
install -d -o root -g root -m 0750 /var/lib/rootgate

if [ ! -f /etc/rootgate/config.json ]; then
	install -o root -g root -m 0644 "$HERE/config.example.json" /etc/rootgate/config.json
	echo "wrote /etc/rootgate/config.json (defaults: console notifications)"
else
	echo "kept existing /etc/rootgate/config.json"
fi

if [ ! -f /etc/rootgate/secrets ]; then
	umask 077
	cat >/etc/rootgate/secrets <<'EOF'
# rootgate secrets — root-only (0600). Agents must never be able to read this.
# Needed only if notify is "telegram".
#TELEGRAM_BOT_TOKEN=123456:ABC...
#TELEGRAM_CHAT_ID=123456789
EOF
	chown root:root /etc/rootgate/secrets
	chmod 0600 /etc/rootgate/secrets
	echo "wrote /etc/rootgate/secrets (template)"
fi

install -o root -g root -m 0644 "$HERE/rootgate.service" /etc/systemd/system/rootgate.service
systemctl daemon-reload
systemctl enable rootgate.service
# `enable --now` does NOT restart a service that is already running, which is how
# a reinstall leaves the old daemon (and its old socket mode) in place.
systemctl restart rootgate.service

sleep 0.5
systemctl --no-pager --lines=5 status rootgate.service || true

cat <<EOF

rootgate installed.

  socket  /run/rootgate/rootgate.sock
  config  /etc/rootgate/config.json
  state   /var/lib/rootgate
  audit   /var/log/rootgate.log

Try it as a normal user:

  echo 'id -un; uptime' > /tmp/who.sh
  rootgate submit /tmp/who.sh --desc "print identity" --name "manual test"
  rootgate wait <id>          # after you approve

Approve from a root shell (shows the payload, asks you to echo its hash):

  sudo rootgate approve <id>

or from the link the notification backend delivered.
EOF
