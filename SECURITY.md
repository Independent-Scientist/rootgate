# Security policy

## Reporting

Open a private security advisory on this repository (Security → Advisories →
Report a vulnerability). Please do not open a public issue for a vulnerability.
Expect an answer within a few days; this is a single-maintainer project, so a
reproducer and the version you tested help more than a severity score.

Include: version (`rootgate` prints it on `serve`), the `config.json` values that
matter (`socket_mode`, `notify`, `public_base`), and what an attacker needs to
already have (a local shell? the socket? the approval link?).

## Threat model, in one page

The design assumes an attacker can make the **agent** do arbitrary things,
including submitting a forged or malicious payload. That is the whole reason the
tool exists. What the design claims:

- the requester never receives the approval token (`submit` returns id + hash
  only, and the token is stored only as sha256);
- approval is bound to the payload sha256, re-checked immediately before
  execution;
- one decision per request, expired means denied;
- no approval path is reachable from the MCP server, so an MCP client cannot
  approve its own request.

What it does **not** claim:

- it does not defend against a local root, or against root-equivalent groups
  (`docker`, `libvirt`, `disk`) — see `tools/audit-privilege-paths.sh`;
- it does not defend against a human who approves a payload without reading it;
  the approval page is the control, and it is a human control;
- it does not sandbox the payload. Approved code runs as root, unconfined, by
  design;
- the default socket is `0666` so that any local user may *ask*. On a host with
  several untrusted users, set `socket_mode` to `0660` and give the socket a
  group — and note that multi-user mode is currently untested (see README).

## Advisories

### 2026-11-26 — local privilege escalation via unvalidated request id (≤ 0.2.0)

**Fixed in 0.3.0.** Found in an internal audit, not exploited in the wild.

`req_dir()` joined the caller-supplied `id` onto the state directory without
validating its shape. Every operation built paths from it, so on a default
install (socket `0666`, any local user may submit) the following worked:

1. create a directory anywhere you can write, containing `payload.sh` and a
   forged `meta.json` with `state: pending`, `sha256` of your payload and
   `token_sha256` of a token you chose;
2. send `{"op":"approve","id":"../../<that dir>","token":"<your token>"}` to the
   socket;
3. the daemon read your forged meta, compared your token against the hash *you*
   supplied, and executed `payload.sh` as root. `systemd-run` escaped the
   invalid unit name rather than refusing it, so execution was not blocked.

Same root cause, lower impact: `log` returned any file named `run.log` outside
the state directory, and `status`/`approve` could read and rewrite `meta.json`
outside it.

Fixed by validating the id against `^\d{8}-\d{6}-[0-9a-f]{8}$` in `req_dir()`,
the single choke point every path goes through, and treating a bad id as "no such
request" everywhere.

Three smaller findings from the same audit, fixed at the same time:

- **`log` had no authorisation** — any local user could read the output of
  another user's (root) command. Now owner-or-root only.
- **`wait` accepted an unbounded `timeout`** — a local user could pin one server
  thread per connection. Now clamped by `max_wait` (default 900 s).
- **`notify=file` wrote the live approval token to a world-readable file** under
  the default umask, which would let the submitter approve itself. The file is
  now created `0600`, and an existing group/other-readable target is refused.

If you ran any version up to 0.2.0 on a multi-user host, assume the local users
could have escalated. Upgrade and re-run `tools/audit-privilege-paths.sh`.
