# I-Varse Hestia — Node.js runtime helpers
#
# Shared functions for the Node.js application runtime. Sourced by the
# v-*-sys-nodejs and v-*-node-app commands.
#
# Runtimes are installed from the official nodejs.org distribution into
# $NODE_ROOT/<major>, one directory per major version, so that applications
# can pin a version independently of whatever the distribution's apt Node is.

# Root of the managed Node.js installations
NODE_ROOT="/opt/ivarse/node"

# Upstream distribution. Overridable for mirrors and air-gapped installs.
NODE_DIST_MIRROR="${NODE_DIST_MIRROR:-https://nodejs.org/dist}"

# Node.js release signing keys. Every release's SHASUMS256.txt is verified
# against this keyring before its checksums are trusted.
#
# Two locations, in order of preference:
#
#   1. a keyring refreshed by v-update-sys-nodejs-keys, kept outside the
#      package's own files so it survives a package upgrade
#   2. the keyring shipped with the package
#
# The bundled copy is a snapshot of the Node.js release team at build time, and
# Node rotates that team. Preferring the refreshed copy means a newly added
# signer is handled by running one command rather than by waiting for a package
# update. NODE_RELEASE_KEYRING may still be set explicitly to override both.
NODE_RELEASE_KEYRING_LOCAL="${NODE_RELEASE_KEYRING_LOCAL:-$HESTIA/data/ivarse/nodejs/release-keys.asc}"

if [ -z "$NODE_RELEASE_KEYRING" ]; then
	if [ -s "$NODE_RELEASE_KEYRING_LOCAL" ]; then
		NODE_RELEASE_KEYRING="$NODE_RELEASE_KEYRING_LOCAL"
	else
		NODE_RELEASE_KEYRING="$HESTIA_COMMON_DIR/nodejs/release-keys.asc"
	fi
fi

# Prefix for the generated systemd units, and where they are written
NODE_SERVICE_PREFIX="ivarse-node"
NODE_SYSTEMD_DIR="/etc/systemd/system"

# Map uname's machine name onto the architecture slug used by nodejs.org
node_runtime_arch() {
	case "$(uname -m)" in
		x86_64) echo "x64" ;;
		aarch64 | arm64) echo "arm64" ;;
		armv7l) echo "armv7l" ;;
		ppc64le) echo "ppc64le" ;;
		s390x) echo "s390x" ;;
		*) return 1 ;;
	esac
}

# Absolute path to the node binary of a major version
node_runtime_bin() {
	echo "$NODE_ROOT/$1/bin/node"
}

# Is a major version installed?
node_runtime_exists() {
	[ -x "$NODE_ROOT/$1/bin/node" ]
}

# Installed major versions, numerically sorted
node_runtime_list() {
	local dir major
	[ -d "$NODE_ROOT" ] || return 0
	for dir in "$NODE_ROOT"/*; do
		[ -d "$dir" ] || continue
		major="$(basename "$dir")"
		[[ "$major" =~ ^[0-9]+$ ]] || continue
		node_runtime_exists "$major" || continue
		echo "$major"
	done | sort -n
}

# Full x.y.z version of an installed major
node_runtime_version() {
	local vfile="$NODE_ROOT/$1/.ivarse-version"
	if [ -f "$vfile" ]; then
		cat "$vfile"
	elif node_runtime_exists "$1"; then
		"$(node_runtime_bin "$1")" -v 2> /dev/null | sed 's/^v//'
	fi
}

# Is this major the default runtime? Echoes yes/no.
node_runtime_is_default() {
	if [ "$(readlink "$NODE_ROOT/default" 2> /dev/null)" = "$1" ]; then
		echo "yes"
	else
		echo "no"
	fi
}

# The default major version, if one is set
node_runtime_default() {
	readlink "$NODE_ROOT/default" 2> /dev/null
}

# Discover which full version the "latest" pointer for a major resolves to.
# Sets node_full_version and node_tarball in the caller's scope.
#
# The result is untrusted: it only decides which release directory to fetch.
# The checksums that are actually used come from that release's signed
# SHASUMS256.txt, read by node_runtime_checksum below.
node_runtime_resolve() {
	local major="$1" arch listing
	arch="$(node_runtime_arch)" || return 1

	listing="$(curl -fsSL --max-time 60 "$NODE_DIST_MIRROR/latest-v$major.x/SHASUMS256.txt" 2> /dev/null)"
	[ -n "$listing" ] || return 1

	# One line per artifact: "<sha256>  node-v22.20.0-linux-x64.tar.xz"
	node_tarball="$(echo "$listing" \
		| grep -oE "node-v${major}\.[0-9]+\.[0-9]+-linux-${arch}\.tar\.xz" \
		| head -n 1)"
	[ -n "$node_tarball" ] || return 1

	node_full_version="$(echo "$node_tarball" | sed -E 's/^node-v([0-9.]+)-.*/\1/')"
	[ -n "$node_full_version" ]
}

# Verify the GPG signature on a release's SHASUMS256.txt against the Node.js
# release keys. Returns 0 only for a good signature made by a bundled key.
#
# gpgv is used rather than gpg so that verification reads a fixed keyring and
# cannot be influenced by, or write to, any keyring on the host.
node_runtime_verify_shasums() {
	local shasums="$1" signature="$2" keyring="$3"

	[ -s "$signature" ] || return 1
	[ -s "$NODE_RELEASE_KEYRING" ] || return 1

	# gpgv needs a binary keyring; the bundled one is armored so it stays
	# reviewable in the repository.
	gpg --dearmor < "$NODE_RELEASE_KEYRING" > "$keyring" 2> /dev/null || return 1

	gpgv --keyring "$keyring" "$signature" "$shasums" > /dev/null 2>&1
}

# Read the checksum for a tarball out of a verified SHASUMS256.txt.
# Sets node_sha256 in the caller's scope.
node_runtime_checksum() {
	local shasums="$1" tarball="$2"
	node_sha256="$(grep -E "  ${tarball}\$" "$shasums" | head -n 1 | awk '{print $1}')"
	[ -n "$node_sha256" ]
}

# Applications currently pinned to a major version.
# Reads the generated systemd units so this stays correct without depending on
# the application registry.
node_runtime_in_use() {
	local major="$1" unit
	for unit in "$NODE_SYSTEMD_DIR"/${NODE_SERVICE_PREFIX}-*.service; do
		[ -f "$unit" ] || continue
		if grep -qF "$NODE_ROOT/$major/bin/" "$unit"; then
			basename "$unit" .service
		fi
	done
}

# Node.js major version validator, dispatched from is_format_valid in main.sh
is_node_major_format_valid() {
	if ! [[ "$1" =~ ^[0-9]{1,2}$ ]] || [ "$1" -lt 1 ]; then
		check_result "$E_INVALID" "invalid node major format :: $1"
	fi
}
