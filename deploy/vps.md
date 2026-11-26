# Deploying on your own VPS

The daemon runs on the machine that needs privilege. The VPS is only the front
door, so a phone can reach the approval page:

```
phone ──https──▶ VPS nginx :443 ──▶ 127.0.0.1:8733 on the VPS
                                        │  autossh reverse tunnel (outbound from the target)
                                        ▼
                                  target 127.0.0.1:8733  (rootgate page)
```

Nothing inbound reaches the target; the only path in is the tunnel it opens.

## What you need

- A VPS you control, with root, reachable on 80/443.
- A DNS name pointing at it — `approve.example.com` is the convention here. A
  provider hostname works too if it resolves to the VPS; a self-signed cert works
  but the browser will warn, and a plain-HTTP page is not acceptable because the
  approval token travels in a header.
- On the target: rootgate installed (`sudo ./install.sh`), and `autossh`
  (`target-setup.sh` falls back to `~/.local/bin/autossh`).

## Step 1 — DNS

Point the name at the VPS **before** running step 2; certificate validation
fails otherwise. Check from anywhere:

```
dig +short approve.example.com
```

## Step 2 — provision the VPS

```
scp deploy/vps-provision.sh root@<your-vps>:/root/
ssh root@<your-vps> 'bash /root/vps-provision.sh approve.example.com 2224'
```

That installs nginx + certbot, writes the vhost (proxy to `127.0.0.1:8733`,
access log off, 8 kB body cap), obtains the certificate, redirects HTTP to HTTPS,
opens 80/443 in ufw, and — if you passed a relay port — exposes `:2224` as an ssh
relay for the target, bridged to `127.0.0.1:2225` where the tunnel terminates.

## Step 3 — wire the target

```
./deploy/target-setup.sh <user>@<your-vps> approve.example.com 2224
```

Run it as the user that runs rootgate, **not** with sudo. It creates a dedicated
key, an `rootgate-vps` entry in `~/.ssh/config`, and two autossh user units
(approval page, optional ssh relay), then prints the single line to add to the
VPS's `authorized_keys` — that file is root-owned there, so it stays your job:

```
no-pty,no-agent-forwarding,no-X11-forwarding,permitlisten="127.0.0.1:8733",permitlisten="127.0.0.1:2225" ssh-ed25519 AAAA… rootgate-tunnel@<target>
```

Then set the public URL on the target and restart:

```json
// /etc/rootgate/config.json
{ "public_base": "https://approve.example.com" }
```

```
sudo systemctl restart rootgate
```

## Step 4 — prove it

```
echo 'id -un' > /tmp/whoami.sh
rootgate submit /tmp/whoami.sh --desc "smoke test" --name manual
```

Open the link the notifier delivered (or the journal, if `notify: console`), read
the payload, approve, and confirm the log says `root`.

## Pitfalls that cost real time

- **`restrict,permitlisten=…` does not work.** `restrict` implies
  `no-port-forwarding`, so the tunnel is refused and you get a silent 502. Use the
  explicit option list above.
- **`permitlisten` takes one `host:port` per option.** Two ports means the option
  twice, comma-separated at the *option* level.
- **The public socket must not share a port with the tunnel's bind.** `:2224`
  public proxies to `127.0.0.1:2225`, and the tunnel binds 2225 — binding both on
  2224 fails with "remote forward failure" and looks like an auth problem.
- **A dead tunnel looks like a broken page.** `curl -sI https://<domain>/a/x`
  returning 502 means nginx is fine and the target tunnel is down:
  `systemctl --user status rootgate-tunnel` on the target.
- **A link pasted as text wraps**, and a long-press copy often grabs only part of
  it — that yields "no such request" on the page. Prefer the link button in the
  chat, or copy from the browser's address bar.
- **The VPS terminates TLS, so the VPS can read approval tokens.** Own it, patch
  it, and prefer a private path (WireGuard/Tailscale) where that trust boundary
  matters more than reachability.

## If you would rather not run a VPS

- **Telegram only.** With `notify: telegram` and a bot the daemon owns
  (`telegram_poll: 1`), the request arrives as a message with Approve/Deny
  buttons and the result is posted back into the chat. No page, no tunnel, no
  VPS. This needs a *dedicated* bot — two consumers of one token steal each
  other's updates.
- **LAN only.** Leave `public_base` empty and approve from a shell on the machine:
  `sudo rootgate approve <id>`.
- **Private network.** WireGuard or Tailscale between phone and target, then
  `public_base` points at the target's private address. No public exposure at all.

## Files

```
deploy/vps-provision.sh   VPS-side setup (root): nginx, cert, ufw, optional relay
deploy/target-setup.sh    target-side setup (user): key, ssh config, autossh units
deploy/Caddyfile          alternative to nginx, if you prefer Caddy
deploy/nginx-rootgate.conf reference vhost if you configure nginx by hand
```
