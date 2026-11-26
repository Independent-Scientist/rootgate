# Public approval page: VPS (h-vps-1) or a private tunnel

The daemon binds `127.0.0.1:8733` only. Something has to carry the page to your
phone. Two ways, and the order matters:

1. **A private path (recommended):** WireGuard or Tailscale on the machine and on
   the phone, then `public_base = https://<wg-ip-or-name>:8733` with a self-signed
   cert, or plain `http://<wg-ip>:8733` if you accept that the token travels in a
   header over an encrypted tunnel anyway. Nothing is public, no third party
   terminates TLS, and the approval page cannot be reached by anyone who is not
   already on your private network.
2. **A VPS you control (h-vps-1):** an SSH reverse forward plus a TLS reverse
   proxy. Works from anywhere, including mobile data, but the VPS terminates TLS,
   so the VPS sees the approval token in the header. Use it only if you own the
   VPS and trust it as much as the machine itself — and be explicit about that in
   your own notes, because it is a real widening of the trust boundary.

## VPS route: steps

### On the machine that needs privilege

```sh
# 1. permanent reverse forward of the page port only
cat >~/.config/systemd/user/rootgate-tunnel.service <<'EOF'
[Unit]
Description=Reverse-forward rootgate's approval page to the VPS
After=network-online.target

[Service]
ExecStart=/usr/bin/ssh -NT \
  -o ExitOnForwardFailure=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \
  -R 127.0.0.1:8733:127.0.0.1:8733 rootgate@h-vps-1.example.net
Restart=always
RestartSec=10

[Install]
WantedBy=default.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now rootgate-tunnel.service
```

That `-R 127.0.0.1:8733:...` binds the port on the **VPS's loopback**, not its
public interface — the VPS's own proxy is the only thing that can reach it.

### On h-vps-1

```sh
apt install caddy            # or your distro's package
# /etc/caddy/Caddyfile: copy deploy/Caddyfile, set ROOTGATE_DOMAIN
caddy validate --config /etc/caddy/Caddyfile
systemctl reload caddy
```

Point `rootgate.example.net` at the VPS, open 80/443 only, and confirm the daemon
port is not reachable from outside:

```sh
ss -ltnp | grep 8733            # expect only 127.0.0.1:8733 on the VPS
curl -sS -m 3 http://h-vps-1.example.net:8733/ ; echo "should fail"
```

### Back on the machine

```json
{ "notify": "telegram", "public_base": "https://rootgate.example.net" }
```

```sh
sudo systemctl restart rootgate
echo 'id -un' > /tmp/who.sh
rootgate submit /tmp/who.sh --desc "smoke test" --name manual
```

### Check the whole path

- the Telegram message arrives with a button;
- the button opens `https://rootgate.example.net/a/<id>#t=<token>` — note the
  fragment: the token is not in the request line, so the VPS and its logs never
  see it in a URL;
- the page shows the payload and hash; approving runs it; reloading the page
  afterwards says the request is already decided;
- `curl -s https://rootgate.example.net/a/<id>` without the fragment renders the
  shell but cannot fetch the payload (403).

## What to keep an eye on

- **Tunnel ownership:** the SSH user on the VPS needs nothing but the ability to
  bind its loopback port. Do not use root for it.
- **VPS compromise = rootgate compromise** in this mode: whoever controls TLS
  termination can read tokens and approve. That is the argument for option 1.
- **Notification channel is the real gate.** If the Telegram bot token leaks,
  approvals can be read and intercepted. Keep `/etc/rootgate/secrets` at 0600,
  rotate the token if a chat is ever shared, and prefer a dedicated bot per
  machine.
- **Audit both ends:** `/var/log/rootgate.log` on the machine, and Caddy's log
  (discarded by default in `deploy/Caddyfile` — turn it on only if you are
  willing to store hashes and ids).
