#!/bin/bash
# target-setup.sh — wire the machine that needs privilege to its VPS front door.
#
#   ./target-setup.sh <user@vps> <public-domain> [relay-port]
#
# Run as the user that will run rootgate (NOT with sudo). It creates a dedicated
# key, an ssh config entry, and autossh user units that keep the reverse tunnels
# up. It prints the one line you must add to the VPS's authorized_keys, because
# that file is root-owned there.
set -euo pipefail

TARGET=${1:-}
DOMAIN=${2:-}
RELAY=${3:-}
[ -n "$TARGET" ] && [ -n "$DOMAIN" ] || {
	echo "usage: $0 <user@vps-host> <public-domain> [relay-port]" >&2; exit 1; }
[ "$(id -u)" -ne 0 ] || { echo "run me as the user that runs rootgate, not with sudo" >&2; exit 1; }

VPS_USER=${TARGET%@*}
VPS_HOST=${TARGET#*@}
KEY=$HOME/.ssh/id_ed25519_rootgate_tunnel
UNITDIR=${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user
AUTOSSH=$(command -v autossh || echo "$HOME/.local/bin/autossh")

say() { printf '\n== %s\n' "$*"; }

say "key"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [ ! -f "$KEY" ]; then
	ssh-keygen -q -t ed25519 -N '' -C "rootgate-tunnel@$(hostname)" -f "$KEY"
	echo "created $KEY"
else
	echo "using existing $KEY"
fi
PUB=$(cat "$KEY.pub")
chmod 600 "$KEY"

say "ssh config entry"
if grep -q '^Host rootgate-vps' "$HOME/.ssh/config" 2>/dev/null; then
	echo "rootgate-vps already in ~/.ssh/config (leaving it alone)"
else
	mkdir -p "$HOME/.ssh"
	cat >>"$HOME/.ssh/config" <<EOF

# rootgate: reverse tunnels to the VPS front door
Host rootgate-vps
    HostName $VPS_HOST
    User $VPS_USER
    IdentityFile $KEY
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    BatchMode yes
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
EOF
	chmod 600 "$HOME/.ssh/config"
	echo "added rootgate-vps to ~/.ssh/config"
fi

say "autossh units"
mkdir -p "$UNITDIR"
write_unit() {  # write_unit <name> <description> <remote-bind> <local-bind>
	cat >"$UNITDIR/$1.service" <<EOF
[Unit]
Description=$2
After=network-online.target

[Service]
Type=simple
Environment=AUTOSSH_GATETIME=0
ExecStart=$AUTOSSH -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -o StrictHostKeyChecking=accept-new -o BatchMode=yes -R $3 rootgate-vps
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
}
write_unit rootgate-tunnel "rootgate approval-page tunnel (VPS 8733 -> this host 8733)" \
	"127.0.0.1:8733:127.0.0.1:8733"
if [ -n "$RELAY" ]; then
	write_unit rootgate-ssh-relay "ssh relay (VPS $((RELAY+1)) -> this host 22)" \
		"127.0.0.1:$((RELAY+1)):127.0.0.1:22"
fi
if [ "${ROOTGATE_SKIP_SYSTEMD:-0}" = 1 ]; then
	echo "units written to $UNITDIR (systemctl skipped: ROOTGATE_SKIP_SYSTEMD=1)"
else
	systemctl --user daemon-reload
	systemctl --user enable --now rootgate-tunnel.service
	[ -n "$RELAY" ] && systemctl --user enable --now rootgate-ssh-relay.service
	echo "units written to $UNITDIR"
fi

say "one line for the VPS (root-owned file there)"
if [ -n "$RELAY" ]; then
	LISTEN="permitlisten=\"127.0.0.1:8733\",permitlisten=\"127.0.0.1:$((RELAY+1))\""
else
	LISTEN='permitlisten="127.0.0.1:8733"'
fi
cat <<EOF

echo 'no-pty,no-agent-forwarding,no-X11-forwarding,$LISTEN $PUB' >> ~/.ssh/authorized_keys

Run that as $VPS_USER on $VPS_HOST. Then add to /etc/rootgate/config.json here:

    "public_base": "https://$DOMAIN"

and restart: sudo systemctl restart rootgate
EOF

say "state"
for u in rootgate-tunnel rootgate-ssh-relay; do
	[ -f "$UNITDIR/$u.service" ] && printf '  %-22s %s\n' "$u" "$(systemctl --user is-active $u.service 2>/dev/null)"
done
echo "  (tunnels stay down until the VPS accepts the key above)"
