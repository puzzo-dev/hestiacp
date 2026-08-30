#!/usr/bin/env bats

# Node.js runtime management (I-Varse)
#
# Exercises v-*-sys-nodejs against a real installation. Runtimes are installed
# from nodejs.org, so these tests need outbound network access and take a while.

if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
	. /etc/profile.d/hestia.sh
fi

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/bats-file/load'

function setup() {
	NODE_ROOT="/opt/ivarse/node"
	primary="22"
	secondary="24"
	source $HESTIA/func/main.sh
}

@test "Nodejs: Install a runtime" {
	run v-add-sys-nodejs $primary
	assert_success
	assert_file_executable "$NODE_ROOT/$primary/bin/node"
	run $NODE_ROOT/$primary/bin/node -v
	assert_success
	assert_output --partial "v$primary."
}

@test "Nodejs: The first runtime installed becomes the default" {
	assert_link_exist "$NODE_ROOT/default"
	run readlink "$NODE_ROOT/default"
	assert_output "$primary"
}

@test "Nodejs: npm is available alongside node" {
	assert_file_executable "$NODE_ROOT/$primary/bin/npm"
}

@test "Nodejs: Installing the same runtime twice is refused" {
	run v-add-sys-nodejs $primary
	assert_failure $E_EXISTS
	assert_output --partial 'already installed'
}

@test "Nodejs: Reject a non-numeric major version" {
	run v-add-sys-nodejs 'twentytwo'
	assert_failure $E_INVALID
	assert_output --partial 'invalid node major format'
}

@test "Nodejs: Reject a major version that does not exist upstream" {
	run v-add-sys-nodejs 97
	assert_failure $E_CONNECT
	assert_output --partial 'unable to resolve'
}

@test "Nodejs: Reject an invalid DEFAULT flag" {
	run v-add-sys-nodejs 23 'maybe'
	assert_failure $E_INVALID
	assert_output --partial 'invalid default format'
}

@test "Nodejs: The release keyring is present and parseable" {
	assert_file_exist "$HESTIA/install/common/nodejs/release-keys.asc"
	run bash -c "gpg --dearmor < $HESTIA/install/common/nodejs/release-keys.asc | wc -c"
	assert_success
	[ "$output" -gt 0 ]
}

@test "Nodejs: Refuse to install without a release keyring" {
	run env NODE_RELEASE_KEYRING=/nonexistent/keys.asc v-add-sys-nodejs 23
	assert_failure $E_NOTEXIST
	assert_output --partial 'release keyring not found'
}

@test "Nodejs: Refuse a release whose SHASUMS256.txt is not signed by a Node key" {
	# A mirror that is internally consistent - correct checksum, valid
	# signature - but signed by a key that is not a Node.js release key.
	mirror="$BATS_TEST_TMPDIR/mirror"
	export GNUPGHOME="$BATS_TEST_TMPDIR/gnupg"
	mkdir -p "$mirror/latest-v31.x" "$mirror/v31.0.0" "$GNUPGHOME"
	chmod 700 "$GNUPGHOME"
	gpg --batch --quiet --passphrase '' --quick-gen-key "Not Node <evil@example.invalid>" default default never

	mkdir -p "$BATS_TEST_TMPDIR/src/node-v31.0.0-linux-x64/bin"
	printf '#!/bin/sh\necho pwned\n' > "$BATS_TEST_TMPDIR/src/node-v31.0.0-linux-x64/bin/node"
	tar -cJf "$mirror/v31.0.0/node-v31.0.0-linux-x64.tar.xz" \
		-C "$BATS_TEST_TMPDIR/src" node-v31.0.0-linux-x64
	(cd "$mirror/v31.0.0" && sha256sum node-v31.0.0-linux-x64.tar.xz > SHASUMS256.txt)
	cp "$mirror/v31.0.0/SHASUMS256.txt" "$mirror/latest-v31.x/SHASUMS256.txt"
	gpg --batch --yes --detach-sign -o "$mirror/v31.0.0/SHASUMS256.txt.sig" \
		"$mirror/v31.0.0/SHASUMS256.txt"
	unset GNUPGHOME

	run env NODE_DIST_MIRROR="file://$mirror" v-add-sys-nodejs 31
	assert_failure $E_INVALID
	assert_output --partial 'not signed by a known Node.js release key'
	assert_dir_not_exist "$NODE_ROOT/31"
}

@test "Nodejs: Refuse a release with no signature at all" {
	mirror="$BATS_TEST_TMPDIR/nosig"
	mkdir -p "$mirror/latest-v31.x" "$mirror/v31.0.0"
	echo "0  node-v31.0.0-linux-x64.tar.xz" > "$mirror/latest-v31.x/SHASUMS256.txt"
	cp "$mirror/latest-v31.x/SHASUMS256.txt" "$mirror/v31.0.0/SHASUMS256.txt"

	run env NODE_DIST_MIRROR="file://$mirror" v-add-sys-nodejs 31
	assert_failure $E_CONNECT
	assert_output --partial 'SHASUMS256.txt.sig'
	assert_dir_not_exist "$NODE_ROOT/31"
}

@test "Nodejs: List reports the installed runtime" {
	run v-list-sys-nodejs plain
	assert_success
	assert_output --partial "$primary"
}

@test "Nodejs: List emits parseable json" {
	run v-list-sys-nodejs json
	assert_success
	run bash -c "v-list-sys-nodejs json | jq -r '.\"$primary\".DEFAULT'"
	assert_output 'yes'
}

@test "Nodejs: A second major version installs alongside the first" {
	run v-add-sys-nodejs $secondary
	assert_success
	assert_file_executable "$NODE_ROOT/$primary/bin/node"
	assert_file_executable "$NODE_ROOT/$secondary/bin/node"
}

@test "Nodejs: Installing a second runtime does not steal the default" {
	run readlink "$NODE_ROOT/default"
	assert_output "$primary"
}

@test "Nodejs: Change the default runtime" {
	run v-change-sys-nodejs-default $secondary
	assert_success
	run readlink "$NODE_ROOT/default"
	assert_output "$secondary"
}

@test "Nodejs: Cannot default to a runtime that is not installed" {
	run v-change-sys-nodejs-default 19
	assert_failure $E_NOTEXIST
	assert_output --partial 'not installed'
}

@test "Nodejs: Cannot delete a runtime an application is pinned to" {
	unit="/etc/systemd/system/ivarse-node-batstest-example.service"
	printf '[Service]\nExecStart=%s/%s/bin/node server.js\n' "$NODE_ROOT" "$primary" > "$unit"
	run v-delete-sys-nodejs $primary
	assert_failure $E_INUSE
	assert_output --partial 'in use by'
	rm -f "$unit"
}

@test "Nodejs: Delete an unused runtime" {
	run v-delete-sys-nodejs $primary
	assert_success
	assert_dir_not_exist "$NODE_ROOT/$primary"
}

@test "Nodejs: Deleting the default runtime repoints the default" {
	run v-delete-sys-nodejs $secondary
	assert_success
	assert_dir_not_exist "$NODE_ROOT/$secondary"
	assert_not_exist "$NODE_ROOT/default"
}

@test "Nodejs: Cannot delete a runtime that is not installed" {
	run v-delete-sys-nodejs $primary
	assert_failure $E_NOTEXIST
	assert_output --partial 'not installed'
}
