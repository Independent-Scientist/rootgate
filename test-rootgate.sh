#!/bin/bash
# test-rootgate.sh — exercise the broker as an unprivileged user.
# Runs the daemon in test mode (notify=file, no systemd, payloads run as $USER),
# so it proves the protocol, the token handling and the state machine without
# touching anything privileged.
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
RG=$HERE/rootgate
T=$(mktemp -d /tmp/rootgate-test.XXXXXX)
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  PASS  %s\n' "$*"; }
bad()  { FAIL=$((FAIL+1)); printf '  FAIL  %s\n' "$*"; }
check(){ if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got '$1', want '$2')"; fi; }

export ROOTGATE_STATE=$T/state
export ROOTGATE_SOCKET=$T/rg.sock
export ROOTGATE_LOG=$T/rg.log
export ROOTGATE_NOTIFY=file
export ROOTGATE_NOTIFY_FILE=$T/notifications.jsonl
export ROOTGATE_HTTP_PORT=18733
export ROOTGATE_MIN_INTERVAL=0
mkdir -p "$T"

cleanup() { [ -n "${SRV:-}" ] && kill "$SRV" 2>/dev/null; }
trap cleanup EXIT

start() {  # start(ttl, min_interval)
	export ROOTGATE_TTL=${1:-600}
	export ROOTGATE_MIN_INTERVAL=${2:-0}
	# A socket file left by the previous daemon exists but refuses connections, so
	# wait for an answer, not for the path. (This made the expiry test flaky.)
	rm -f "$ROOTGATE_SOCKET"
	$RG serve >>"$T/daemon.log" 2>&1 &
	SRV=$!
	for _ in $(seq 60); do
		if $RG list >/dev/null 2>&1; then return 0; fi
		sleep 0.1
	done
	echo "daemon did not answer on $ROOTGATE_SOCKET" >&2
	cat "$T/daemon.log" >&2
	return 1
}
stop() { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; SRV=; }

echo "rootgate test run in $T"
start 600 0

echo "[1] daemon answers"
$RG list >/dev/null 2>&1 && ok "list works" || bad "list failed"

echo "[2] submit returns an id but NOT the token"
cat >"$T/p1.sh" <<'EOF'
echo hello from the payload
id -un
EOF
out=$($RG submit "$T/p1.sh" --desc "print hello" --name "test-agent" 2>&1)
ID1=$(printf '%s\n' "$out" | awk '/^submitted/{print $2}')
[ -n "$ID1" ] && ok "got id $ID1" || bad "no id: $out"
printf '%s' "$out" | grep -qi 'token' && bad "response mentions a token" || ok "no token in response"

echo "[3] request is pending"
st=$($RG status "$ID1" | awk '/^state/{print $2}')
check "$st" "pending" "state pending"

echo "[4] wait blocks while pending"
$RG wait "$ID1" --timeout 2 >/dev/null
st=$($RG status "$ID1" | awk '/^state/{print $2}')
check "$st" "pending" "still pending after a short wait"

echo "[5] the human's channel got exactly one notification"
n=$(wc -l <"$ROOTGATE_NOTIFY_FILE")
check "$n" "1" "one notification"
TOKEN=$(python3 - "$ROOTGATE_NOTIFY_FILE" <<'PY'
import json,sys
recs=[json.loads(l) for l in open(sys.argv[1])]
print(recs[-1]["token"])
PY
)
[ -n "$TOKEN" ] && ok "token readable from the human's channel" || bad "no token in notification"

echo "[6] a wrong token cannot approve"
$RG approve "$ID1" >/dev/null 2>&1           # non-root approve must refuse
check "$?" "1" "non-root approve refused"
python3 - "$ID1" "$TOKEN" <<'PY'
import json,socket,sys,os
rid, tok = sys.argv[1], sys.argv[2]
def call(req):
    s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(os.environ["ROOTGATE_SOCKET"])
    s.sendall((json.dumps(req)+"\n").encode()); d=b""
    while not d.endswith(b"\n"):
        c=s.recv(4096)
        if not c: break
        d+=c
    return json.loads(d)
r=call({"op":"approve","id":rid,"token":"wrong-"+tok})
print("REJECTED" if not r.get("ok") else "ACCEPTED")
PY
[ "$(python3 - "$ID1" "$TOKEN" <<'PY'
import json,socket,sys,os
def call(req):
    s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(os.environ["ROOTGATE_SOCKET"])
    s.sendall((json.dumps(req)+"\n").encode()); d=b""
    while not d.endswith(b"\n"):
        c=s.recv(4096)
        if not c: break
        d+=c
    return json.loads(d)
r=call({"op":"approve","id":sys.argv[1],"token":"wrong-"+sys.argv[2]})
print("REJECTED" if not r.get("ok") else "ACCEPTED")
PY
)" = "REJECTED" ] && ok "wrong token rejected" || bad "wrong token accepted"

echo "[7] the right token approves, the payload runs, the log is captured"
$RG wait "$ID1" --timeout 20 >/dev/null 2>&1 & WPID=$!   # approve happens just below
python3 - "$ID1" "$TOKEN" <<'PY'
import json,socket,sys,os
def call(req):
    s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(os.environ["ROOTGATE_SOCKET"])
    s.sendall((json.dumps(req)+"\n").encode()); d=b""
    while not d.endswith(b"\n"):
        c=s.recv(4096)
        if not c: break
        d+=c
    return json.loads(d)
r=call({"op":"approve","id":sys.argv[1],"token":sys.argv[2]})
print(r.get("state") or r.get("error"))
PY
sleep 1
st=$($RG status "$ID1" | awk '/^state/{print $2}')
check "$st" "done" "state done"
$RG log "$ID1" | grep -q "hello from the payload" && ok "payload output captured" || bad "payload output missing"
wait "$WPID" 2>/dev/null || true

echo "[8] the token is single use"
python3 - "$ID1" "$TOKEN" <<'PY'
import json,socket,sys,os
def call(req):
    s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(os.environ["ROOTGATE_SOCKET"])
    s.sendall((json.dumps(req)+"\n").encode()); d=b""
    while not d.endswith(b"\n"):
        c=s.recv(4096)
        if not c: break
        d+=c
    return json.loads(d)
r=call({"op":"approve","id":sys.argv[1],"token":sys.argv[2]})
print("REFUSED" if not r.get("ok") else "ACCEPTED AGAIN")
PY
st=$($RG status "$ID1" | awk '/^state/{print $2}')
check "$st" "done" "state unchanged after replay"

echo "[9] a payload swapped after approval is refused"
$RG submit "$T/p1.sh" --desc "tamper test" --name test-agent >/dev/null
ID2=$($RG list | awk 'NR==1{print $1}')
TOK2=$(python3 - "$ROOTGATE_NOTIFY_FILE" <<'PY'
import json,sys
recs=[json.loads(l) for l in open(sys.argv[1])]
print(recs[-1]["token"])
PY
)
printf 'echo TAMPERED\n' >>"$ROOTGATE_STATE/requests/$ID2/payload.sh"
python3 - "$ID2" "$TOK2" <<'PY' >/dev/null
import json,socket,sys,os
def call(req):
    s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(os.environ["ROOTGATE_SOCKET"])
    s.sendall((json.dumps(req)+"\n").encode()); d=b""
    while not d.endswith(b"\n"):
        c=s.recv(4096)
        if not c: break
        d+=c
    return json.loads(d)
call({"op":"approve","id":sys.argv[1],"token":sys.argv[2]})
PY
sleep 1
st=$($RG status "$ID2" | awk '/^state/{print $2}')
check "$st" "refused" "tampered payload refused"
$RG log "$ID2" 2>/dev/null | grep -q TAMPERED && bad "tampered payload executed" || ok "tampered payload did not execute"
stop

echo "[10] expired requests cannot be approved"
start 2 0
$RG submit "$T/p1.sh" --desc "expiry test" --name test-agent >/dev/null
ID3=$($RG list | awk 'NR==1{print $1}')
TOK3=$(python3 - "$ROOTGATE_NOTIFY_FILE" <<'PY'
import json,sys
recs=[json.loads(l) for l in open(sys.argv[1])]
print(recs[-1]["token"])
PY
)
sleep 3
python3 - "$ID3" "$TOK3" <<'PY'
import json,socket,sys,os
def call(req):
    s=socket.socket(socket.AF_UNIX, socket.SOCK_STREAM); s.connect(os.environ["ROOTGATE_SOCKET"])
    s.sendall((json.dumps(req)+"\n").encode()); d=b""
    while not d.endswith(b"\n"):
        c=s.recv(4096)
        if not c: break
        d+=c
    return json.loads(d)
r=call({"op":"approve","id":sys.argv[1],"token":sys.argv[2]})
print("REFUSED" if not r.get("ok") else "ACCEPTED")
PY
st=$($RG status "$ID3" | awk '/^state/{print $2}')
check "$st" "expired" "state expired"
stop

echo "[11] submission rate limit"
start 600 30
$RG submit "$T/p1.sh" --desc "first" --name test-agent >/dev/null
out=$($RG submit "$T/p1.sh" --desc "second" --name test-agent 2>&1)
printf '%s' "$out" | grep -q "too recently" && ok "second submit refused" || bad "rate limit did not apply: $out"
stop

echo
echo "PASS=$PASS FAIL=$FAIL   (state kept in $T)"
[ "$FAIL" -eq 0 ]
