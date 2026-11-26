# rootgate

A privileged-action broker for *any* agent on the machine. Agents ask; a human
approves; root runs the exact bytes that were approved.

It exists because agents (Hermes, Claude Code, Codex, a cron script, a person on
a phone) all hit the same wall: `sudo` needs a password, an agent has no tty and
must never hold one. Handing an agent a password, a NOPASSWD rule or a reusable
token is worse than the problem. rootgate inverts it: **the agent never gets a
secret, and the approval travels on a channel the agent cannot read.**

Caveat first, because it matters: any process can *submit*, including a
prompt-injected agent. The human approval step is the entire control. If a
payload looks wrong, deny it — the request is not the action.

## What it enforces

- **No secret reaches the requester.** `submit` returns an id, a hash and an
  expiry — never the approval token. The token goes to the notification channel
  (console, Telegram bot, ntfy topic), whose credentials are in a root-only file.
- **Approval is bound to bytes.** The payload hash is pinned at submit; the
  executor re-hashes immediately before running and refuses if the file changed.
- **Single use, short life.** 256-bit token, one decision, `ttl` (default 600 s),
  expired means denied.
- **Two ways to be the human.** A root shell (`sudo rootgate approve <id>`, which
  prints the payload and makes you echo its hash), or the link delivered to the
  notification channel.
- **Agent-agnostic.** One unix socket, one JSON protocol, one CLI. It knows
  nothing about Hermes or any other agent. Identity shown to the human is best
  effort: uid, pid, exe, cwd, plus a self-declared name.
- **Rate limited.** `max_pending` per uid and `min_interval` between submissions,
  so a runaway agent cannot flood the human into clicking by accident.

## What it does not do

- It is not a sandbox: an approved payload runs as root with a clean env, and can
  do anything root can.
- The phone-approval path is a bearer token. If the token leaks *and* the payload
  is hostile, that is root. The TTL, single use, hash binding and your reading of
  the payload are what stand in the way. There is no second factor yet.
- It does not make an agent trustworthy, it makes its privilege requests visible
  and refusable.

## Install

```
sudo ./install.sh
```

Installs `/usr/local/sbin/rootgate`, `/etc/systemd/system/rootgate.service`,
`/etc/rootgate/{config.json,secrets}`, `/var/lib/rootgate`, and enables the unit.

## Configure `/etc/rootgate/config.json`

| key | meaning |
|---|---|
| `notify` | `console` (default), `telegram`, `ntfy`, `file` (tests only) |
| `public_base` | external base URL for approval links, e.g. `https://abc.ngrok-free.app`; empty means `http://127.0.0.1:8733` (useless from a phone) |
| `http_port` | approval page port, bound to 127.0.0.1 only |
| `ttl` | seconds an approval stays valid |
| `max_pending`, `min_interval` | per-uid limits |
| `exec_timeout` | hard cap on a payload's runtime |

**Telegram** (fits this setup): create a bot, put
`TELEGRAM_BOT_TOKEN=…` and `TELEGRAM_CHAT_ID=…` in `/etc/rootgate/secrets`
(root-only, 0600), set `"notify": "telegram"`. The approval arrives as a message
with a button, and the agent never sees the bot token, the message, or the link.

**ntfy**: install the app, subscribe to a long random topic, set `ntfy_topic`.
On public ntfy.sh anyone who guesses the topic can read the link — use a 30+
character random topic, or self-host with access control.

Reaching the page from a phone needs a tunnel you control (`ngrok http 8733` on
gb360-style box, `ssh -R`), and `public_base` set to it. Do not bind the page to
anything but loopback.

## Use it

Any process, any agent, one protocol:

```sh
rootgate submit action.sh --desc "rebuild the i915 module for 7.2.14" --name claude-code
#   submitted 20261126-055202-e63ec42c
#   sha256    efe748999b…
#   expires   06:02:02
rootgate wait 20261126-055202-e63ec42c --timeout 300   # blocks, prints rc and log
rootgate status <id> | log <id> | list
```

Approving locally:

```sh
sudo rootgate approve <id>     # prints the payload, asks you to type the hash prefix
sudo rootgate deny <id>
```

Wire it into an agent's instructions as: *"if a step needs root, write the
commands to a file and run `rootgate submit …`, never ask the user for a
password."* Nothing else in the agent changes.

## Agent integration: MCP first, skill second

**MCP** is the integration that makes this agent-agnostic: `rootgate-mcp` is a
stdio MCP server exposing `escalate`, `escalation_status`, `escalation_wait`,
`escalation_log`, `escalation_list`. Register it in any MCP-capable agent and the
only new capability is "ask a human for privilege" — no approval tool exists in
it, by construction:

```json
{
  "mcpServers": {
    "rootgate": { "command": "/usr/local/sbin/rootgate-mcp", "args": [] }
  }
}
```

That snippet is the whole integration for Claude Desktop/Code, Hermes, and
anything else that speaks MCP. For agents without MCP, the CLI is the same
protocol (`rootgate submit … / wait`).

**Skill** (`skill/SKILL.md`) is the other half: it tells the agent *how* to
behave — one purpose per submission, rollback in the script, no password
requests, what "denied" means. Install it where your agent reads skills
(Hermes: `~/.hermes/skills/`, Claude Code: `.claude/skills/`). Both are shipped;
neither replaces the other.

## Publishing the page to a phone

See `deploy/h-vps-1.md`. Two options, in order of preference: a private path
(WireGuard/Tailscale, no third party), or an SSH reverse forward to a VPS you
control with Caddy terminating TLS. The token rides in the URL fragment and is
sent as a header, so it never appears in a request line, a proxy log, or a
`Referer`. `deploy/Caddyfile` is the proxy config.

## Operations

- Audit log: `/var/log/rootgate.log`, one JSON object per event
  (`submit`, `approve`, `deny`, `execution_start`, `execution_end`,
  `execution_refused`, `decision_rejected`), root-only, append.
- Kill switch: `sudo systemctl stop rootgate` — every pending request becomes
  unusable immediately.
- State: `/var/lib/rootgate/requests/<id>/{payload.sh,meta.json,run.log}`, root
  only. Clean up by deleting old directories; nothing else references them.
- Payloads run via `systemd-run --unit=rootgate-<id> --collect`, so a runaway
  action can be inspected and killed with `systemctl status rootgate-<id>`.

## Tests

```
./test-rootgate.sh          # 16 checks, unprivileged, no systemd, no root
```

Covers: no token in the submit response, wrong token rejected, right token
approves, payload runs and log captured, token replay refused, tampered payload
refused **and not executed**, expiry, rate limiting. The approval page is the
same code path (GET renders, POST decides) and was verified separately against a
live daemon.

## Layout

```
rootgate                 daemon + CLI (one file, python3 stdlib only)
rootgate-mcp             MCP stdio server (tools for any MCP agent)
rootgate.service         systemd unit
install.sh               root installer
config.example.json      defaults
skill/SKILL.md           how an agent should request privilege
deploy/Caddyfile         reverse proxy for the approval page
deploy/h-vps-1.md        VPS/tunnel runbook
test-rootgate.sh         unprivileged test suite
```

MIT.
