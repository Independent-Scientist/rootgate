#!/bin/bash
# audit-privilege-paths.sh — find the ways a non-root user becomes root on this
# host *without* an approval step. Read-only: it reports, it changes nothing.
#
# Run it as the user an agent runs as. The point is to catch the root-equivalent
# paths that quietly make any approval broker theatre: container groups, sockets,
# NOPASSWD rules, setuid/capability binaries, writable PATH entries.
#
# Exit: 0 = nothing high, 1 = at least one HIGH finding.
set -uo pipefail

HIGH=0
WARN=0
say_high() { HIGH=$((HIGH+1)); printf 'HIGH   %s\n' "$*"; }
say_warn() { WARN=$((WARN+1)); printf 'WARN   %s\n' "$*"; }
say_ok()   { printf 'ok     %s\n' "$*"; }

ME=$(id -un)
# NB: GROUPS is a bash special array (numeric gids) and silently shadows an
# assignment — hence MYGROUPS.
MYGROUPS=$(id -nG)
echo "host        $(hostname)"
echo "user        $ME"
echo "groups      $MYGROUPS"
echo

echo "== container / VM groups (root-equivalent by design) =="
for g in docker podman lxd incus libvirt kvm disk; do
	if printf '%s\n' $MYGROUPS | grep -qx "$g"; then
		case $g in
		docker|podman|lxd|incus) say_high "member of '$g': a container with / bind-mounted gives root" ;;
		libvirt) say_warn "member of 'libvirt': qemu hooks and guest disks are a root path" ;;
		disk)    say_high "member of 'disk': raw block device access is root-equivalent" ;;
		kvm)     say_ok "member of 'kvm' (expected for VM use, not an escalation)" ;;
		esac
	fi
done
if ! printf '%s\n' $MYGROUPS | grep -qxE 'docker|podman|lxd|incus|disk'; then
	say_ok "no container/disk group membership"
fi

echo
echo "== container sockets =="
sock_seen=0
for s in /var/run/docker.sock /run/docker.sock /run/podman/podman.sock; do
	[ -S "$s" ] || continue
	sock_seen=1
	g=$(stat -Lc '%G' "$s")
	m=$(stat -Lc '%a' "$s")
	if printf '%s\n' $MYGROUPS | grep -qx "$g"; then
		say_high "socket $s is openable by you (group $g, mode $m): starting a container is root"
	else
		case ${m: -1} in
		2|3|6|7) say_high "socket $s is world-writable (mode $m)" ;;
		*) say_ok "socket $s exists (group $g, mode $m) but you are not in '$g'" ;;
		esac
	fi
done
[ "$sock_seen" -eq 1 ] || say_ok "no container socket"

echo
echo "== sudo rules =="
if command -v sudo >/dev/null; then
	nopass=$( { sudo -n -l 2>/dev/null || true; } | grep -c 'NOPASSWD' || true)
	if [ "${nopass:-0}" -gt 0 ]; then
		say_high "sudo -n -l lists NOPASSWD entries for $ME"
	else
		say_ok "no NOPASSWD entries usable by $ME (sudo -n -l)"
	fi
	if [ -r /etc/sudoers.d ] || ls /etc/sudoers.d >/dev/null 2>&1; then
		for f in /etc/sudoers.d/*; do
			[ -f "$f" ] || continue
			grep -q 'NOPASSWD' "$f" 2>/dev/null && say_warn "NOPASSWD in $f"
		done
	fi
fi

echo
echo "== setuid / capability binaries =="
setuid=$(find /usr/bin /usr/sbin /bin /sbin /usr/local/bin /usr/local/sbin -xdev -perm -4000 -type f 2>/dev/null)
if [ -n "$setuid" ]; then
	echo "$setuid" | sed 's/^/       /'
	say_warn "$(printf '%s\n' "$setuid" | wc -l) setuid binaries (normal on most distros; check any you do not recognise)"
else
	say_ok "no setuid binaries in PATH dirs"
fi
if command -v getcap >/dev/null; then
	caps=$(getcap -r /usr/bin /usr/sbin 2>/dev/null)
	[ -n "$caps" ] && { echo "$caps" | sed 's/^/       /'; say_warn "file capabilities present (see above)"; } || say_ok "no file capabilities in /usr/bin,/usr/sbin"
fi

echo
echo "== PATH writability =="
IFS=: read -ra PATHDIRS <<<"$PATH"
for d in "${PATHDIRS[@]}"; do
	[ -d "$d" ] || continue
	if [ -w "$d" ] && [ "$(stat -c %U "$d")" != "$ME" ]; then
		say_high "PATH dir $d is writable by $ME but owned by $(stat -c %U "$d")"
	fi
done
say_ok "PATH checked: $PATH"

echo
echo "== polkit allow rules =="
if [ -d /etc/polkit-1/rules.d ]; then
	hits=$(grep -rlE 'return\s+polkit\.Result\.YES|allow_active\s*=\s*"?yes' /etc/polkit-1/rules.d 2>/dev/null || true)
	[ -n "$hits" ] && { echo "$hits" | sed 's/^/       /'; say_warn "polkit rules that allow without auth (verify they are intended)"; } || say_ok "no permissive polkit rules found"
else
	say_ok "no /etc/polkit-1/rules.d"
fi

echo
echo "== unprivileged namespaces =="
nsv=$(cat /proc/sys/user/max_user_namespaces 2>/dev/null || echo "?")
if [ "$nsv" != "0" ] && [ "$nsv" != "?" ]; then
	say_warn "user namespaces enabled (max_user_namespaces=$nsv): kernel-exploit surface, not a direct root path"
else
	say_ok "user namespaces disabled or unavailable"
fi

echo
echo "summary: HIGH=$HIGH WARN=$WARN"
[ "$HIGH" -eq 0 ] || { echo "at least one root-equivalent path exists for $ME"; exit 1; }
exit 0
