# What was actually deployed (reference setup, 2026-11)

A worked example, so the next person can repeat it instead of re-deriving it.

## Shape

```
phone ──https──▶ VPS nginx (TLS, :443) ──▶ 127.0.0.1:8733 on the VPS
                                              │  ssh -R reverse tunnel
                                              ▼
                                        target 127.0.0.1:8733  (rootgate approval page)
```

Nothing inbound reaches the target. The only path in is the tunnel the target
opens out, and it lands on the VPS's **loopback**, so only nginx can use it.

## VPS side (Hostinger, Ubuntu 26.04, `srv2175901.hstgr.cloud` → 177.7.50.10)

```sh
apt-get install -y nginx certbot python3-certbot-nginx
ufw allow "Nginx Full"                    # 80 + 443; only these were opened
# /etc/nginx/sites-available/rootgate  <- deploy/nginx-rootgate.conf
ln -sf /etc/nginx/sites-available/rootgate /etc/nginx/sites-enabled/rootgate
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
certbot --nginx -d srv2175901.hstgr.cloud --agree-tos \
        --register-unsafely-without-email --redirect --non-interactive
```

The provider hostname already had an A record, so a real certificate was issued
without owning a domain. On a VPS without one, use your own DNS name or a
self-signed cert and expect a browser warning (still encrypted; a plain-HTTP page
is not acceptable — the token travels in a header).

The site config discards access logs and caps request bodies at 8 kB, because the
only traffic here is an approval decision.

## Tunnel key (on the VPS, for the target machine)

One key, allowed to do exactly one thing — open a listener on the VPS loopback at
port 8733, nothing else:

```
no-pty,no-agent-forwarding,no-X11-forwarding,permitlisten="127.0.0.1:8733" ssh-ed25519 AAAA… rootgate-tunnel@<target>
```

**`restrict,permitlisten=…` does not work** — `restrict` implies
`no-port-forwarding`, so the tunnel is refused and you get a silent 502. Use the
explicit option list above.

## Target side

```sh
# ~/.ssh/config
Host rootgate-vps
    HostName <vps>
    User <tunnel-user>
    IdentityFile ~/.ssh/id_ed25519_rootgate_tunnel
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    BatchMode yes
    ExitOnForwardFailure yes
    ServerAliveInterval 30
    ServerAliveCountMax 3
```

```ini
# ~/.config/systemd/user/rootgate-tunnel.service → deploy/rootgate-tunnel.service
ExecStart=/usr/bin/ssh -N -R 127.0.0.1:8733:127.0.0.1:8733 rootgate-vps
```

`systemctl --user enable --now rootgate-tunnel.service` (needs linger, or a
logged-in session).

Then in `/etc/rootgate/config.json`:

```json
{ "notify": "telegram", "public_base": "https://<vps-hostname>" }
```

## Verification actually run

| check | result |
|---|---|
| `curl http://<vps>/` | `301` to https |
| `curl https://<vps>/` with no rootgate on the target | `502` (expected) |
| temp listener on the target + tunnel | page content returned through the public URL |
| `ss -tln` on the VPS | `127.0.0.1:8733` only, never `0.0.0.0` |
| certificate | issued by Let's Encrypt for the provider hostname |

## Residual risks, plainly

- The VPS terminates TLS, so the VPS can read approval tokens and approve. Own
  it, patch it, and prefer a private path (WireGuard/Tailscale) where it matters.
- The tunnel user on the VPS is a normal account with one narrow key. Do not give
  it sudo and do not reuse that key for anything else.
- Uptime of the approval path now includes the VPS and the tunnel: if either is
  down, escalations simply time out (default deny), which is the right failure.
