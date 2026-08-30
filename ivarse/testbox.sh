#!/usr/bin/env bash
#
# I-Varse Hestia test box
#
# Runs a disposable Hestia installation in a systemd-capable Docker container,
# so changes can be installed and tested without touching a real server.
#
# This mirrors .github/workflows/pr-docker-bats.yml, which is what CI runs, so
# a green run here means the same thing a green run there does.
#
#   ./ivarse/testbox.sh up        build the image and boot the container
#   ./ivarse/testbox.sh install   build the deb from this tree and install it
#   ./ivarse/testbox.sh verify    confirm the running install really is this tree
#   ./ivarse/testbox.sh test      run the bats suite (default: nodejs.bats)
#   ./ivarse/testbox.sh shell     open a shell inside the box
#   ./ivarse/testbox.sh logs      journal from inside the box
#   ./ivarse/testbox.sh down      destroy the container
#   ./ivarse/testbox.sh reset     down, then up + install
#
# Requires Docker with cgroup v2. Under WSL2, systemd must be enabled on the
# host distro (/etc/wsl.conf -> [boot] systemd=true).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IMAGE="hestia-ci:ivarse"
NAME="ivarse-testbox"

HST_HOSTNAME="hestia.local.test"
HST_EMAIL="admin@example.com"
HST_USER="admin"
HST_PASS="Password123"

die() {
	echo "error: $*" >&2
	exit 1
}

require_docker() {
	command -v docker > /dev/null || die "docker not found"
	docker info > /dev/null 2>&1 || die "cannot talk to the docker daemon"
	if [ "$(stat -fc %T /sys/fs/cgroup)" != "cgroup2fs" ]; then
		die "cgroup v2 is required to run systemd in a container"
	fi
}

running() {
	[ -n "$(docker ps -q -f "name=^${NAME}$")" ]
}

cmd_up() {
	require_docker
	echo "==> building $IMAGE"
	docker build -f "$REPO_ROOT/.github/docker/hestia-ci.Dockerfile" -t "$IMAGE" "$REPO_ROOT"

	docker rm -f "$NAME" > /dev/null 2>&1 || true

	echo "==> booting $NAME"
	# --privileged, host cgroups and the tmpfs mounts are what let systemd run
	# as PID 1 inside the container. These are the same flags CI uses.
	docker run -d \
		--name "$NAME" \
		--hostname hestia-dev.local \
		--privileged \
		--cgroupns=host \
		--tmpfs /run \
		--tmpfs /run/lock \
		--tmpfs /tmp:exec,mode=1777 \
		--dns 8.8.8.8 \
		--dns 8.8.4.4 \
		-e TZ=UTC \
		-e LANG=en_US.UTF-8 \
		-e LC_ALL=en_US.UTF-8 \
		-v /sys/fs/cgroup:/sys/fs/cgroup:rw \
		-v "$REPO_ROOT:/hestiacp-git" \
		-w /hestiacp-git \
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

cmd_install() {
	require_docker
	running || die "container is not running; run '$0 up' first"

	echo "==> building the hestia deb from this tree"
	docker exec "$NAME" bash -lc '
		set -euo pipefail
		export TERM=xterm
		cd /hestiacp-git/src
		bash ./hst_autocompile.sh --hestia --noinstall --keepbuild "~localsrc"
	'

	echo "==> installing hestia"
	docker exec "$NAME" bash -lc "
		set -euo pipefail
		export TERM=xterm
		DEB_PATH=''
		if compgen -G '/tmp/hestiacp-src/deb/hestia_*.deb' >/dev/null; then
			DEB_PATH=/tmp/hestiacp-src/deb
		elif compgen -G '/tmp/hestiacp-src/debs/hestia_*.deb' >/dev/null; then
			DEB_PATH=/tmp/hestiacp-src/debs
		else
			echo 'no locally built hestia deb found' >&2
			exit 1
		fi
		cd /hestiacp-git
		bash install/hst-install-ubuntu.sh \
			--hostname $HST_HOSTNAME \
			--email $HST_EMAIL \
			--username $HST_USER \
			--password $HST_PASS \
			--interactive no \
			--force \
			--with-debs \"\$DEB_PATH\" \
			--clamav no \
			--spamassassin no
	"
	# The stock installer enables apt.hestiacp.com and a nightly job that runs
	# "apt-get install hestia" against it. Pin upstream down before anything can
	# replace the package we just built.
	echo "==> pinning upstream hestia packages"
	docker exec "$NAME" bash -lc '/usr/local/hestia/bin/v-add-sys-ivarse-apt-pin' || true

	cmd_verify
	echo "==> hestia installed. panel user: $HST_USER / $HST_PASS"
}

# Confirm the running installation is actually this tree, not a package that
# apt pulled from upstream. The installer hides dpkg output, so without this a
# silent replacement looks like a successful install.
cmd_verify() {
	require_docker
	running || die "container is not running"

	echo "==> verifying the installed package is ours"
	docker exec "$NAME" bash -lc '
		set -euo pipefail
		ver="$(dpkg-query -W -f='"'"'${Version}'"'"' hestia 2>/dev/null || true)"
		echo "    installed hestia: ${ver:-none}"
		case "$ver" in
			*ivarse*) ;;
			*) echo "    ERROR: installed hestia is not an I-Varse build" >&2; exit 1 ;;
		esac
		missing=0
		for f in 			/usr/local/hestia/func/node.sh 			/usr/local/hestia/bin/v-add-sys-nodejs 			/usr/local/hestia/bin/v-delete-sys-nodejs 			/usr/local/hestia/bin/v-list-sys-nodejs 			/usr/local/hestia/bin/v-change-sys-nodejs-default 			/usr/local/hestia/install/common/nodejs/release-keys.asc
		do
			[ -e "$f" ] || { echo "    MISSING: $f" >&2; missing=1; }
		done
		[ "$missing" -eq 0 ] || exit 1
		grep -q "IVARSE" /usr/local/hestia/func/main.sh 			|| { echo "    MISSING: the is_format_valid patch in func/main.sh" >&2; exit 1; }
		echo "    all I-Varse files present"
	'
}

cmd_test() {
	require_docker
	running || die "container is not running; run '$0 up' first"
	local suite="${1:-test/nodejs.bats}"

	docker exec "$NAME" bash -lc "
		set -euo pipefail
		cd /hestiacp-git
		if ! command -v bats >/dev/null 2>&1; then
			test/test_helper/bats-core/install.sh /usr/local
		fi
		bats $suite
	"
}

cmd_shell() {
	running || die "container is not running"
	docker exec -it "$NAME" bash -l
}

cmd_logs() {
	running || die "container is not running"
	docker exec "$NAME" bash -lc 'journalctl --no-pager -n "${1:-200}"'
}

cmd_down() {
	docker rm -f "$NAME" > /dev/null 2>&1 && echo "==> removed $NAME" || echo "==> nothing to remove"
}

case "${1:-}" in
	up) cmd_up ;;
	install) cmd_install ;;
	verify) cmd_verify ;;
	test) shift; cmd_test "$@" ;;
	shell) cmd_shell ;;
	logs) cmd_logs ;;
	down) cmd_down ;;
	reset) cmd_down; cmd_up; cmd_install ;;
	*)
		sed -n '2,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 1
		;;
esac
