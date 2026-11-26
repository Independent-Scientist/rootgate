# rootgate

**sudo for AI agents — without giving the agent root, or a password.**

[![release](https://img.shields.io/github/v/release/Independent-Scientist/rootgate?label=release)](https://github.com/Independent-Scientist/rootgate/releases)
[![license](https://img.shields.io/badge/license-MIT-blue)](LICENSE)
[![tests](https://img.shields.io/badge/tests-16%20passing-brightgreen)](test-rootgate.sh)
[![python](https://img.shields.io/badge/python-3.11%2B-blue)](rootgate)
[![MCP](https://img.shields.io/badge/MCP-stdio%20server-purple)](rootgate-mcp)

`rootgate` is a privileged-action broker: a small privileged daemon that lets an
AI coding agent — Claude Code, Codex, Cursor, Hermes, or your own script — ask
for a command to be run as root, and lets a human approve that exact command
from a phone, a browser, or a root shell.

The agent asks. A human approves. Root runs the exact bytes that were approved.
Nothing else.

It exists because every agent hits the same wall: `sudo` needs a password, an
agent has no tty and must never hold one. Handing an agent a password, a NOPASSWD rule or a reusable
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

## What has actually been tested

Honest labelling, because "it works" is not uniform across these:

| area | status |
|---|---|
| `notify: telegram` — message delivery, link button, approval round trip | **tested end to end** against the live Bot API; this is the only notification channel exercised for real |
| approval page over TLS (nginx + reverse tunnel + cert) | tested end to end; a submitted command ran as root from a phone approval |
| `notify: console` | exercised on a real host — the prompt lands in the journal and `sudo rootgate approve` works |
| `notify: ntfy` | **untested.** Same code path as telegram, never run against a live topic |
| inline buttons (`telegram_poll: 1`) | decision logic tested with a stubbed Telegram API (wrong HMAC, wrong chat, replay, happy path); **never tested against a real dedicated bot** |
| CLI, MCP server, hash pinning, single use, TTL, rate limits | 16 unprivileged tests, run on every change |
| running on a second, unrelated host | tested: installed on a second machine and executed a root command after approval (`decided_by root`, log `root`) |
| multi-user hosts (`socket_mode: 0660` + a group) | **untested.** The default `0666` socket is what has been used |

So: Telegram is the supported, proven channel. Everything else is either
partially exercised or code-only — treat it as "probably fine", not as verified.

## Install

Two steps: the broker as root, then the Hermes integration as your user.

```
sudo ./install.sh             # /usr/local/sbin, systemd unit, /etc/rootgate
./tools/integrate-hermes.sh   # registers the MCP server, installs the skill
```

`integrate-hermes.sh` is safe to re-run: it skips registration if the server is
already configured, runs `hermes mcp test` and fails loudly if the server does
not answer, and prints the two things only a human can do — type `/reload-mcp`
in the running session, and set the approval channel.

Installs `/usr/local/sbin/rootgate`, `/etc/systemd/system/rootgate.service`,
`/etc/rootgate/{config.json,secrets}`, `/var/lib/rootgate`, and enables the unit.

## Configure `/etc/rootgate/config.json`

| key | meaning |
|---|---|
| `notify` | `console` (default), `telegram` (**the only channel tested against a real service**), `ntfy` (untested), `file` (tests only) |
| `telegram_poll` | `1` only with a bot dedicated to rootgate; enables inline buttons |
| `public_base` | external base URL for approval links, e.g. `https://abc.ngrok-free.app`; empty means `http://127.0.0.1:8733` (useless from a phone) |
| `http_port` | approval page port, bound to 127.0.0.1 only |
| `ttl` | seconds an approval stays valid |
| `socket_mode` | mode of the unix socket, default `0666` (see below) |
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

### Why the socket is 0666

Submitting is unprivileged by design — the approval is what needs a token or
root. A socket owned `root:root 0660` therefore locks out every agent running as
the login user, which is the entire point of the tool; that was a real bug here,
and it fails as `PermissionError: [Errno 13]` in the client.

The trade: any local account can *submit*, i.e. can make your phone buzz. Per-uid
`max_pending` and `min_interval` bound that, and denying is one tap. On a
multi-user machine, set `socket_mode` to `0660` and run the daemon with
`RuntimeDirectory` owned by a `rootgate` group containing only the accounts that
should be able to ask.

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

## Approving inside Telegram (inline buttons)

With `"notify": "telegram"` the request arrives as a message with **✅ Approve**
and **⛔ Deny** buttons. A press is verified three ways before anything runs:

- `callback_data` is `a|d:<id>:<16 hex>`, where the hex is `HMAC-SHA256(key=token_sha256, "action:id")`.
  The requester never sees `token_sha256`, so it cannot forge a press for its own
  request;
- the press must come from the configured `TELEGRAM_CHAT_ID`;
- the decision still goes through the normal path (hash re-checked, single use,
  TTL), and the result — `rc` plus the log — is posted back into the chat.

**This needs a bot the daemon owns.** Set `"telegram_poll": "1"` only for such a
bot. Telegram keeps a single update queue per bot: if an agent gateway is polling
the same token, the two consumers steal each other's updates — the daemon would
swallow the agent's messages, and the agent the button presses. The default is
`0` (link-only approvals) deliberately.

## Publishing the page to a phone

Full runbook: **`deploy/vps.md`**. Two scripts do the work on any host:

```
sudo ./deploy/vps-provision.sh approve.example.com 2224   # on the VPS: nginx, cert, ufw, relay
./deploy/target-setup.sh <user>@<vps> approve.example.com 2224   # on the target: key, tunnels
```

The daemon never runs on the VPS — the VPS is a front door that terminates TLS
and forwards to a reverse tunnel the target opens outward. Nothing is exposed
inbound on the target. The token rides in the URL fragment and is sent as a
header, so it never appears in a request line, a proxy log, or a `Referer`.

Prefer no third party at all? Use WireGuard/Tailscale between phone and target
and point `public_base` at the private address, or skip the page entirely and use
the Telegram button path.

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

## Audit the host first

A broker is theatre if the same user already has a root-equivalent path. Two
scripts, both in `tools/`:

```sh
./tools/audit-privilege-paths.sh          # read-only; exits 1 if it finds a HIGH
sudo ./tools/remove-container-escalation.sh <user> [--dry-run]
```

The audit looks for container/VM/disk group membership, container sockets,
NOPASSWD sudo rules, setuid and capability binaries, writable `PATH` entries,
permissive polkit rules and unprivileged user namespaces. The removal script
takes a user out of `docker`/`podman`/`lxd`/`incus` and tightens a
group-accessible container socket; it does not stop running services, so root-run
containers keep working.

Run the audit before you install, and again after. If it reports HIGH, fix that
first — otherwise "approve before root" describes a machine where root is one
`docker run` away.

## Tests

```
./test-rootgate.sh          # 16 checks, unprivileged, no systemd, no root
```

Covers: no token in the submit response, wrong token rejected, right token
approves, payload runs and log captured, token replay refused, tampered payload
refused **and not executed**, expiry, rate limiting. The approval page is the
same code path (GET renders, POST decides) and was verified separately against a
live daemon.

## FAQ

### How do I let an AI agent run a command as root without giving it a password?

Install rootgate on the machine, register its MCP server with your agent, and the
agent submits the command instead of running `sudo`. You approve it on your
phone; the daemon runs it as root. The agent never sees a password, a token or an
ssh key, and it cannot approve its own request — the token goes to a channel whose
credentials live in a root-only file.

### Is it safe to give Claude Code (or any agent) sudo?

Indirectly, and deliberately so. The agent gets *no* standing privilege: each
privileged action is its own request, pinned to a hash, with a TTL and one use.
The risk that remains is you approving something bad — which is why the page shows
the payload verbatim, in full, under a warning that it runs as root.

### How is this different from `NOPASSWD` in sudoers?

`NOPASSWD` is a permanent, reusable grant: one prompt-injected line and the agent
has root for the rest of the session. rootgate grants nothing. Approval is per
payload, bound to a sha256, expires in ten minutes by default, and is consumed by
a single execution.

### How is it different from running the agent in a container?

Both are worth doing. A container bounds *what the agent can touch*; rootgate
answers *what happens when the task genuinely needs the host* — installing a
package, restarting a service, loading a kernel module, editing `/etc`. Run
`tools/audit-privilege-paths.sh` too: it finds the group and container grants
that hand out root silently.

### Does it work with the Model Context Protocol (MCP)?

Yes. `rootgate-mcp` is a stdio MCP server exposing `escalate`,
`escalation_status`, `escalation_wait`, `escalation_log` and `escalation_list`.
It deliberately exposes **no approve tool**, so an MCP client cannot approve
anything — by construction, not by prompt.

### Can I approve from my phone?

Two ways: a link button in Telegram that opens a TLS page with the payload and an
Approve button, or inline Approve/Deny buttons when the daemon owns a dedicated
bot. A root shell (`sudo rootgate approve <id>`) also works and is what the
`console` channel uses.

### What happens if the agent is prompt-injected?

It can submit anything a human will read. It cannot approve, cannot replay a used
request, cannot change the bytes after approval, and cannot reach the token. The
defence is a human reading the payload; the page makes that hard to skip, and the
audit log records every submission and decision.

### Which notification channels are tested?

Telegram, end to end; `console` on real hosts; `ntfy` is code-only so far. The
"What has actually been tested" table above is the honest list.

### Do I need a VPS?

No. Telegram-only approvals need no page and no tunnel; LAN approval from a shell
needs nothing at all; a private WireGuard/Tailscale path avoids public exposure.
A VPS is only for "approve from anywhere", and even then it is a front door — the
daemon never runs there. See `deploy/vps.md`.

### Does it work on macOS or the BSDs?

It targets Linux (systemd, `/run`, uid-based identity). Nothing in the wire
protocol is Linux-specific, but the installer and units are. Ports welcome.

## Layout

```
rootgate                 daemon + CLI (one file, python3 stdlib only)
rootgate-mcp             MCP stdio server (tools for any MCP agent)
rootgate.service         systemd unit
install.sh               root installer
config.example.json      defaults
skill/SKILL.md           how an agent should request privilege
tools/integrate-hermes.sh             MCP + skill wiring for a Hermes install
tools/audit-privilege-paths.sh        find root-equivalent paths on a host
tools/remove-container-escalation.sh  remove container-group escalation
deploy/vps.md            VPS deployment runbook (start here)
deploy/vps-provision.sh  VPS side: nginx, Let's Encrypt, ufw, optional ssh relay
deploy/target-setup.sh   target side: key, ssh config, autossh units
deploy/Caddyfile         Caddy alternative to nginx
deploy/nginx-rootgate.conf  reference vhost for manual nginx
test-rootgate.sh         unprivileged test suite
```

MIT.
