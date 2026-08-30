#!/usr/bin/env bash
#
# I-Varse Hestia test box
#
# Runs a disposable, stock Hestia installation in a systemd-capable Docker
# container, then installs the hestia-ivarse add-on package on top of it.
#
# Hestia itself is installed unmodified. That is the point: the add-on must
# work against stock upstream Hestia, and must survive Hestia being upgraded
# underneath it.
#
#   ./ivarse/testbox.sh up        build the image and boot the container
#   ./ivarse/testbox.sh hestia    install stock Hestia (slow, once per box)
#   ./ivarse/testbox.sh install   build and install the add-on (fast, repeat)
#   ./ivarse/testbox.sh verify    confirm the add-on owns its files and Hestia is stock
#   ./ivarse/testbox.sh test      run the bats suite
#   ./ivarse/testbox.sh upgrade   upgrade Hestia underneath the add-on, then verify
#   ./ivarse/testbox.sh shell     open a shell inside the box
#   ./ivarse/testbox.sh down      destroy the container
#
# Requires Docker with cgroup v2. Under WSL2, systemd must be enabled on the
# host distro (/etc/wsl.conf -> [boot] systemd=true).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="hestia-ci:ivarse"
NAME="ivarse-testbox"

die() {
	echo "error: $*" >&2
	exit 1
}

require_box() {
	command -v docker > /dev/null || die "docker not found"
	[ -n "$(docker ps -q -f "name=^${NAME}$")" ] || die "container not running; run '$0 up' first"
}

cmd_up() {
	command -v docker > /dev/null || die "docker not found"
	[ "$(stat -fc %T /sys/fs/cgroup)" = "cgroup2fs" ] || die "cgroup v2 is required to run systemd in a container"

	echo "==> building $IMAGE"
	docker build -f "$REPO_ROOT/.github/docker/hestia-ci.Dockerfile" -t "$IMAGE" "$REPO_ROOT"
	docker rm -f "$NAME" > /dev/null 2>&1 || true

	echo "==> booting $NAME"
	docker run -d --name "$NAME" --hostname hestia-dev.local \
		--privileged --cgroupns=host \
		--tmpfs /run --tmpfs /run/lock --tmpfs /tmp:exec,mode=1777 \
		--dns 8.8.8.8 --dns 8.8.4.4 \
		-e TZ=UTC -e LANG=en_US.UTF-8 -e LC_ALL=en_US.UTF-8 \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		-v "$REPO_ROOT:/hestiacp-git" -w /hestiacp-git \
		"$IMAGE" > /dev/null

	echo -n "==> waiting for systemd"
	for _ in $(seq 1 300); do
		if docker exec "$NAME" bash -lc \
			'systemctl is-system-running 2>/dev/null | grep -Eq "running|degraded"'; then
			echo " ok"
			return 0
		fi
		echo -n "."
		sleep 1
	done
	echo
	die "systemd did not come up inside the container"
}

cmd_hestia() {
	require_box
	echo "==> installing stock Hestia (this takes a while)"
	docker exec "$NAME" bash -lc '
		set -euo pipefail
		export TERM=xterm
		cd /hestiacp-git
		bash install/hst-install-ubuntu.sh \
			--hostname hestia.local.test --email admin@example.com \
			--username admin --password Password123 \
			--interactive no --force --clamav no --spamassassin no
	'
}

cmd_install() {
	require_box
	echo "==> building and installing the add-on"
	docker exec "$NAME" bash -lc '
		set -euo pipefail
		cd /hestiacp-git
		./ivarse/build-package.sh /tmp/ivarse-build
		dpkg -i /tmp/ivarse-build/hestia-ivarse_*.deb
	'
	cmd_verify
}

# The add-on is only correct if it adds files and replaces none. Anything it
# ships that the hestia package owns would be silently reverted by the next
# Hestia upgrade, which is the failure this packaging exists to prevent.
cmd_verify() {
	require_box
	echo "==> verifying the add-on adds files rather than replacing Hestia's"
	docker exec "$NAME" bash -lc '
		set -euo pipefail
		dpkg-query -W -f="    hestia:        \${Version}\n" hestia
		dpkg-query -W -f="    hestia-ivarse: \${Version}\n" hestia-ivarse

		bad=0
		checked=0
		# dpkg -L lists directories too, and shipped commands have no extension,
		# so select real files rather than matching on the path text.
		while IFS= read -r f; do
			[ -f "$f" ] || continue
			checked=$((checked + 1))
			owner="$(dpkg -S "$f" 2>/dev/null | cut -d: -f1 || true)"
			if [ "$owner" != "hestia-ivarse" ]; then
				echo "    OWNERSHIP: $f is owned by ${owner:-nobody}" >&2
				bad=1
			fi
		done < <(dpkg -L hestia-ivarse)
		[ "$checked" -gt 0 ] || { echo "    ERROR: package ships no files" >&2; exit 1; }
		[ "$bad" -eq 0 ] || exit 1
		echo "    all $checked shipped files are owned by hestia-ivarse"
	'
}

# The whole promise of this packaging: Hestia can be upgraded through its own
# normal channels and the add-on keeps working, with no merge and no rebuild.
cmd_upgrade() {
	require_box
	echo "==> upgrading Hestia underneath the add-on"
	docker exec "$NAME" bash -lc '
		set -euo pipefail
		before="$(dpkg-query -W -f="\${Version}" hestia)"
		apt-get update -qq -o Dir::Etc::sourcelist="sources.list.d/hestia.list" \
			-o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0"
		/usr/local/hestia/bin/v-update-sys-hestia-all || true
		after="$(dpkg-query -W -f="\${Version}" hestia)"
		echo "    hestia: $before -> $after"
	'
	cmd_verify
	echo "==> re-running the suite after the upgrade"
	cmd_test
}

cmd_test() {
	require_box
	local suite="${1:-test/nodejs.bats}"
	docker exec "$NAME" bash -lc "
		set -euo pipefail
		cd /hestiacp-git
		command -v bats >/dev/null 2>&1 || test/test_helper/bats-core/install.sh /usr/local
		bats $suite
	"
}

case "${1:-}" in
	up) cmd_up ;;
	hestia) cmd_hestia ;;
	install) cmd_install ;;
	verify) cmd_verify ;;
	upgrade) cmd_upgrade ;;
	test) shift; cmd_test "$@" ;;
	shell) require_box; docker exec -it "$NAME" bash -l ;;
	logs) require_box; docker exec "$NAME" bash -lc 'journalctl --no-pager -n 200' ;;
	down) docker rm -f "$NAME" > /dev/null 2>&1 && echo "removed $NAME" || echo "nothing to remove" ;;
	*) sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 1 ;;
esac
