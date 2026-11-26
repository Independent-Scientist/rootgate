#!/bin/bash
# vps-provision.sh — put the public front door for rootgate on a fresh Debian/Ubuntu VPS.
#
#   sudo ./vps-provision.sh approve.example.com [relay-port]
#
# Creates:
#   nginx vhost for <domain>  ->  http://127.0.0.1:8733   (the approval page tunnel)
#   a Let's Encrypt certificate, HTTP redirected to HTTPS
#   ufw rules for 80/443, plus <relay-port> if given
#   optionally an ssh relay: public <relay-port> -> 127.0.0.1:<relay-port+1>
#
# The daemon itself NEVER runs here unless this is also the machine that needs
# privilege. This script only builds the front door.
set -euo pipefail

DOMAIN=${1:-}
RELAY=${2:-}
[ -n "$DOMAIN" ] || { echo "usage: $0 <domain> [relay-port]" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "run me with sudo on the VPS" >&2; exit 1; }
case $DOMAIN in *.*) ;; *) echo "that does not look like a domain: $DOMAIN" >&2; exit 1 ;; esac

say() { printf '\n== %s\n' "$*"; }

say "packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx

say "nginx vhost for $DOMAIN"
cat > /etc/nginx/sites-available/rootgate <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;

    location /.well-known/acme-challenge/ { root /var/www/html; }
    location / { return 301 https://\$host\$request_uri; }
}

server {
    listen 443 ssl;
    listen [::]:443 ssl;
    http2 on;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;

    # Approval traffic only: never logged, never large.
    access_log off;
    client_max_body_size 8k;

    add_header Strict-Transport-Security "max-age=31536000" always;
    add_header X-Content-Type-Options nosniff always;
    add_header Referrer-Policy no-referrer always;

    location / {
        proxy_pass http://127.0.0.1:8733;
        proxy_http_version 1.1;
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_read_timeout 30s;
    }
}
EOF
# the certificate does not exist yet, so validate with the vhost held out
ln -sf /etc/nginx/sites-available/rootgate /etc/nginx/sites-enabled/rootgate
rm -f /etc/nginx/sites-enabled/default

say "firewall"
if command -v ufw >/dev/null && ufw status | grep -q "Status: active"; then
	ufw allow "Nginx Full"
else
	echo "ufw not active — make sure 80/443 are reachable another way"
fi

say "certificate"
# temporarily serve only :80 so the http-01 challenge can answer
cat > /etc/nginx/sites-available/rootgate-acme <<EOF
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location / { proxy_pass http://127.0.0.1:8733; proxy_set_header Host \$host; }
}
EOF
ln -sf /etc/nginx/sites-available/rootgate-acme /etc/nginx/sites-enabled/rootgate
nginx -t
systemctl reload nginx
certbot certonly --nginx -d "$DOMAIN" --agree-tos \
	--register-unsafely-without-email --non-interactive
# now swap in the real vhost
ln -sf /etc/nginx/sites-available/rootgate /etc/nginx/sites-enabled/rootgate
rm -f /etc/nginx/sites-available/rootgate-acme
nginx -t
systemctl reload nginx

if [ -n "$RELAY" ]; then
	say "ssh relay on :$RELAY (target sshd tunnel binds 127.0.0.1:$((RELAY+1)))"
	cat > /etc/systemd/system/rootgate-ssh-relay.socket <<EOF
[Unit]
Description=Public relay socket for a rootgate target's sshd tunnel

[Socket]
ListenStream=0.0.0.0:$RELAY
Accept=no

[Install]
WantedBy=sockets.target
EOF
	cat > /etc/systemd/system/rootgate-ssh-relay.service <<EOF
[Unit]
Description=Relay to the target sshd reverse tunnel (127.0.0.1:$((RELAY+1)))
Requires=rootgate-ssh-relay.socket
After=rootgate-ssh-relay.socket

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd 127.0.0.1:$((RELAY+1))
PrivateTmp=yes
EOF
	systemctl daemon-reload
	systemctl enable --now rootgate-ssh-relay.socket
	ufw allow "$RELAY/tcp" 2>/dev/null || true
fi

say "done"
cat <<EOF
Next, on the machine that needs privilege (as the user that will run rootgate):

    ./deploy/target-setup.sh <user>@<this-host> $DOMAIN${RELAY:+ $RELAY}

and in /etc/rootgate/config.json on that machine:

    "public_base": "https://$DOMAIN"

Then approve a test request end to end:

    echo 'id -un' > /tmp/whoami.sh
    rootgate submit /tmp/whoami.sh --desc "smoke test" --name manual
EOF
