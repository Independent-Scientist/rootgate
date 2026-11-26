#!/bin/bash
# remove-container-escalation.sh — take a user out of the container groups that
# make them root without an approval step. Root only; prints what it changed.
#
#   sudo ./remove-container-escalation.sh [user] [--dry-run]
#
# Removing the membership does not stop containers: any systemd service running
# as root keeps working. It only stops *this user* (and therefore any agent
# running as them) from starting a container with / bind-mounted.
set -uo pipefail

DRY=0
USER_TARGET=""
for a in "$@"; do
	case $a in
	--dry-run) DRY=1 ;;
	-*) echo "unknown option $a" >&2; exit 2 ;;
	*) USER_TARGET=$a ;;
	esac
done
[ "$DRY" -eq 1 ] || [ "$(id -u)" -eq 0 ] || { echo "run me with sudo (or use --dry-run)" >&2; exit 1; }
# dry-run needs no privilege: it only prints what would change
case ${SUDO_USER:-} in "") USER_TARGET=${USER_TARGET:-} ;; esac
[ -n "$USER_TARGET" ] || USER_TARGET=${SUDO_USER:-$(id -un)}
[ -n "$USER_TARGET" ] || { echo "usage: $0 [user] [--dry-run]" >&2; exit 1; }
id "$USER_TARGET" >/dev/null 2>&1 || { echo "no such user: $USER_TARGET" >&2; exit 1; }

changed=0
echo "user: $USER_TARGET   (dry-run=$DRY)"
echo "groups before: $(id -nG "$USER_TARGET")"

for g in docker podman lxd incus; do
	if id -nG "$USER_TARGET" | tr ' ' '\n' | grep -qx "$g"; then
		if [ "$DRY" -eq 1 ]; then
			echo "would remove $USER_TARGET from group '$g'"
		else
			if gpasswd -d "$USER_TARGET" "$g" >/dev/null 2>&1; then
				echo "removed $USER_TARGET from group '$g'"
				changed=$((changed+1))
			else
				echo "FAILED to remove $USER_TARGET from '$g'" >&2
			fi
		fi
	fi
done

# A container socket that a non-root group can open is the same hole as the
# group itself. Report it; only tighten the mode when it is group-accessible by
# a group the user is in.
for s in /var/run/docker.sock /run/docker.sock /run/podman/podman.sock; do
	[ -S "$s" ] || continue
	owner_group=$(stat -Lc '%G' "$s")
	perm=$(stat -Lc '%a' "$s")
	echo "socket $s group=$owner_group mode=$perm"
	if id -nG "$USER_TARGET" | tr ' ' '\n' | grep -qx "$owner_group" && [ "$owner_group" != "root" ]; then
		if [ "$DRY" -eq 1 ]; then
			echo "would set $s to root:root 0660"
		else
			chown root:root "$s" && chmod 0660 "$s" && echo "tightened $s to root:root 0660"
			changed=$((changed+1))
		fi
	fi
done

echo "groups after:  $(id -nG "$USER_TARGET")"
if [ "$DRY" -eq 0 ]; then
	echo "changed: $changed"
	echo "note: the user must log out and back in (or the agent restart) before the old group set is gone from running processes."
fi
[ "$DRY" -eq 1 ] || [ "$changed" -gt 0 ] || echo "nothing to do"
