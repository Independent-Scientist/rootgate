---
name: rootgate-escalation
description: "Use when a step needs root: submit it for human approval instead of asking for a password."
version: 1.0.0
author: Hermes Agent
license: MIT
platforms: [linux]
metadata:
  hermes:
    tags: [privilege, root, sudo, escalation, approval, mcp]
---

# Escalating through rootgate

`rootgate` is a privileged-action broker on the machine. You never get a
password, a sudo token or any reusable credential. You submit the exact script
you want to run as root; a human approves or denies it; root runs those bytes.

## When to Use

- Any step that needs root: `systemctl`, package install, `/etc` edits, mounts,
  device permissions, loading modules, `chown` outside `$HOME`.
- Whenever you catch yourself about to ask the user for a password — stop, submit
  instead. Asking for a password is never the right move.
- When a previous escalation was denied: do **not** resubmit the same thing
  rewritten to look different. Ask the user why first.

## How to call it

If your runtime has the MCP server (`rootgate-mcp`), the tools are:
`escalate`, `escalation_status`, `escalation_wait`, `escalation_log`,
`escalation_list`. Otherwise use the CLI, which is the same protocol:

```sh
rootgate submit /tmp/step.sh --desc "what this does" --name <your-name>
rootgate wait <id> --timeout 300
```

## Rules the reviewer will hold you to

1. **One purpose per submission.** "Install the module and reboot" is two.
2. **Write the rollback into the script** as comments, and mention it in `desc`
   when the action is destructive.
3. **Be explicit.** No `curl | bash`, no unquoted globs over `/`, no `rm -rf` on
   a variable you did not set in the same script.
4. **Make it idempotent** where you can: `install -D`, `mkdir -p`,
   `systemctl enable --now`, checks before writes.
5. **`set -euo pipefail`** at the top, and echo markers before risky steps so a
   hang leaves a trail.
6. **Environment is clean**: `PATH` is the system one, `HOME=/root`, cwd `/`.
   Use absolute paths for anything you brought from `$HOME`.
7. **Read the log afterwards** and report what actually happened — the exit code
   alone does not tell the user whether the change is in effect.
8. **Denied means denied.** Report it; do not work around it.

## What the human sees

The id, the requesting uid/pid/exe/cwd, your `--name`, the description, the
sha256 of the payload, and the payload verbatim — then Approve/Deny. The
approval link goes to their own channel (console, Telegram, ntfy), not back
through you.

## Failure modes

| response | meaning | what to do |
|---|---|---|
| `too many pending` | you already have requests waiting | wait for one to be decided |
| `submitted too recently` | rate limit | wait a few seconds |
| `request expired` | nobody approved in time | ask the user, then resubmit |
| `refused` | the payload file changed after approval | do not retry; stage a new submission |
| `denied` | the human said no | stop and ask what they want instead |
