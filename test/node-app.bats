#!/usr/bin/env bats

# Application registry (I-Varse)
#
# F2 covers the data model and the listing commands. Applications are written
# into the registry by hand here; creating them through v-add-node-app is F4.

if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
	. /etc/profile.d/hestia.sh
fi

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/bats-file/load'

function setup() {
	user="ivarse-apptest"
	domain="apptest.local.test"
	source $HESTIA/func/main.sh
	source $HESTIA/func/node.sh
	source $HESTIA/func/app.sh
	conf="$HESTIA/data/users/$user/app.conf"
}

function write_app() {
	cat >> "$conf" <<-REC
		NAME='$1' DOMAIN='$2' RUNTIME='node' RUNTIME_VERSION='22' APP_ROOT='/home/$user/web/$2/app' PORT='$3' PACKAGE_MANAGER='npm' BUILD_COMMAND='npm run build' START_COMMAND='npm start' SERVICE_NAME='ivarse-node-$user-$1' SUSPENDED='no' TIME='12:00:00' DATE='2026-08-30'
	REC
}

@test "AppRegistry: Create a test user" {
	# Idempotent: a run that aborts before the cleanup test would otherwise
	# leave the user behind and fail every later run with "user exists".
	v-delete-user "$user" > /dev/null 2>&1 || true
	run v-add-user "$user" "Sup3rSecret!23" "$user@example.com" default "App Test"
	assert_success
	assert_dir_exist "$HESTIA/data/users/$user"
}

@test "AppRegistry: Listing an empty registry succeeds" {
	run v-list-node-apps "$user" plain
	assert_success
	assert_output ""
}

@test "AppRegistry: Empty registry still emits valid json" {
	run bash -c "v-list-node-apps '$user' json | jq -e 'length == 0'"
	assert_success
}

@test "AppRegistry: A hand-written record round-trips" {
	write_app "frontend" "$domain" 30001
	run v-list-node-apps "$user" plain
	assert_success
	assert_output --partial "frontend"
	assert_output --partial "30001"
}

@test "AppRegistry: json exposes every field" {
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.PORT'"
	assert_output "30001"
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.RUNTIME'"
	assert_output "node"
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.APP_ROOT'"
	assert_output "/home/$user/web/$domain/app"
}

@test "AppRegistry: csv and shell formats work" {
	run v-list-node-apps "$user" csv
	assert_success
	assert_line --index 0 --partial "NAME,DOMAIN,RUNTIME"
	run v-list-node-apps "$user" shell
	assert_success
	assert_output --partial "frontend"
}

@test "AppRegistry: Multiple applications list independently" {
	write_app "api" "api.$domain" 30002
	run bash -c "v-list-node-apps '$user' json | jq -e 'length == 2'"
	assert_success
	run bash -c "v-list-node-apps '$user' json | jq -r '.api.PORT'"
	assert_output "30002"
	run bash -c "v-list-node-apps '$user' json | jq -r '.frontend.PORT'"
	assert_output "30001"
}

@test "AppRegistry: Status is derived, not stored" {
	# No systemd unit exists for these records, so status must read as stopped
	# rather than echoing anything held in the registry.
	refute grep -q "STATUS=" "$conf"
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.STATUS'"
	assert_output "stopped"
}

@test "AppRegistry: Hestia's own object helpers read the registry" {
	# main.sh derives USER_DATA from $user at source time, so $user must be set first
	run bash -c "user='$user'; source $HESTIA/func/main.sh; get_object_value 'app' 'NAME' 'frontend' '\$PORT'"
	assert_output "30001"
}

@test "AppRegistry: Listing an unknown application fails" {
	run v-list-node-app "$user" nosuchapp
	assert_failure $E_NOTEXIST
	assert_output --partial "doesn't exist"
}

@test "AppRegistry: Reject invalid application names" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_name_format_valid 'Bad Name'"
	assert_failure $E_INVALID
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_name_format_valid '../escape'"
	assert_failure $E_INVALID
}

@test "AppRegistry: Reject a port outside the application range" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_port_format_valid 9000"
	assert_failure $E_INVALID
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_port_format_valid 30001"
	assert_success
}

@test "AppRegistry: An app root outside the managed base is refused" {
	base="/home/$user/.ivarse/apps"
	for bad in "/etc" "/home/admin/.ivarse/apps/x" "/home/$user/web/d/private/app" "/home/$user/elsewhere"; do
		run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid \"\$1\" '$user'" _ "$bad"
		assert_failure $E_FORBIDEN
	done
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '$base/../../escape' '$user'"
	assert_failure $E_INVALID
}

@test "AppRegistry: Shell metacharacters are refused in commands" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_command_format_valid 'npm start; rm -rf /' 'start command'"
	assert_failure $E_INVALID
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_command_format_valid 'npm start && curl evil' 'start command'"
	assert_failure $E_INVALID
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_command_format_valid 'npm start' 'start command'"
	assert_success
}

@test "AppRegistry: Service names are runtime-scoped" {
	run bash -c "source $HESTIA/func/app.sh; app_service_name '$user' 'frontend' 'node'"
	assert_output "ivarse-node-$user-frontend"
	run bash -c "source $HESTIA/func/app.sh; app_service_name '$user' 'frontend' 'python'"
	assert_output "ivarse-python-$user-frontend"
}

@test "AppRegistry: A newline in the app root is refused" {
	# APP_ROOT becomes WorkingDirectory= in a systemd unit. A newline lets a
	# caller append ExecStartPost= and User=root, and systemd honours the last
	# User=, so this is arbitrary execution as root.
	inject="$(printf '/home/%s/web/a/app\nExecStartPost=/bin/id\nUser=root' "$user")"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid \"\$1\" '$user'" _ "$inject"
	assert_failure $E_INVALID
	assert_output --partial 'may only contain'
}

@test "AppRegistry: Shell metacharacters in the app root are refused" {
	for bad in 'a;id' 'a$(id)' 'a`id`' 'a b' 'a"q' "a'q" 'a|b' 'a&b'; do
		run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid \"\$1\" '$user'" _ "/home/$user/web/$bad/app"
		assert_failure $E_INVALID
	done
}

@test "AppRegistry: Ordinary app roots are still accepted" {
	for good in "app" "my-app_2" "site.com" "a.b-c_d"; do
		run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid \"\$1\" '$user'" _ "/home/$user/.ivarse/apps/$good"
		assert_success
	done
}

@test "AppRegistry: A symlinked app root that escapes the base is refused" {
	mkdir -p "/home/$user/.ivarse/apps"
	ln -sfn /etc "/home/$user/.ivarse/apps/esc"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/.ivarse/apps/esc' '$user'"
	assert_failure $E_FORBIDEN
	assert_output --partial 'resolves outside'
	rm -f "/home/$user/.ivarse/apps/esc"
}

@test "AppRegistry: A symlink pointing to another user is refused" {
	mkdir -p "/home/$user/.ivarse/apps"
	ln -sfn /home/admin "/home/$user/.ivarse/apps/other"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/.ivarse/apps/other' '$user'"
	assert_failure $E_FORBIDEN
	rm -f "/home/$user/.ivarse/apps/other"
}

@test "AppRegistry: A symlink staying inside the base is allowed" {
	mkdir -p "/home/$user/.ivarse/apps/real"
	ln -sfn "/home/$user/.ivarse/apps/real" "/home/$user/.ivarse/apps/alias"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/.ivarse/apps/alias' '$user'"
	assert_success
	rm -f "/home/$user/.ivarse/apps/alias"
}

@test "AppRegistry: A path that does not exist yet still validates" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/.ivarse/apps/notyet' '$user'"
	assert_success
}

@test "AppRegistry: app_root_resolve returns the real path" {
	mkdir -p "/home/$user/.ivarse/apps/real2"
	ln -sfn "/home/$user/.ivarse/apps/real2" "/home/$user/.ivarse/apps/alias2"
	run bash -c "source $HESTIA/func/app.sh; app_root_resolve '/home/$user/.ivarse/apps/alias2'"
	assert_output "/home/$user/.ivarse/apps/real2"
	rm -f "/home/$user/.ivarse/apps/alias2"
}

@test "AppRegistry: A symlinked home directory does not cause false rejections" {
	# Homes on mounted storage are often reached through a symlink.
	mkdir -p "/srv/althome/$user/.ivarse/apps/x"
	ln -sfn /srv/althome /altohome
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; HOMEDIR=/altohome; is_app_root_format_valid '/altohome/$user/.ivarse/apps/x' '$user'"
	assert_success
	rm -f /altohome
	rm -rf /srv/althome
}

@test "AppRegistry: The app root base is root-owned and not user-writable" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; app_root_create '$user' \"\$(app_default_root '$user' frontend)\""
	assert_success
	base="/home/$user/.ivarse/apps"
	run stat -c "%U:%G %a" "$base"
	assert_output "root:root 755"
	# The user must not be able to delete a name here and re-point it: that is
	# the swap the whole layout exists to prevent.
	run runuser -u "$user" -- rmdir "$base/frontend"
	assert_failure
	run runuser -u "$user" -- ln -s /etc "$base/evil"
	assert_failure
}

@test "AppRegistry: The app root itself is owned by the user" {
	run stat -c "%U:%G" "/home/$user/.ivarse/apps/frontend"
	assert_output "$user:$user"
}

@test "AppRegistry: The user can write inside their app root" {
	run runuser -u "$user" -- touch "/home/$user/.ivarse/apps/frontend/index.js"
	assert_success
	assert_file_exist "/home/$user/.ivarse/apps/frontend/index.js"
}

@test "AppRegistry: The default app root is under the managed base" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; app_default_root '$user' 'frontend'"
	assert_output "/home/$user/.ivarse/apps/frontend"
}

@test "AppRegistry: A root anywhere else in the home is refused" {
	# web/<domain>/private is user-writable, so a name there can be swapped.
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/web/x/private/app' '$user'"
	assert_failure $E_FORBIDEN
	assert_output --partial 'must be under'
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/anywhere' '$user'"
	assert_failure $E_FORBIDEN
}

@test "AppRegistry: An existing symlink at the app root is refused" {
	mkdir -p "/home/$user/.ivarse/apps"
	ln -sfn /etc "/home/$user/.ivarse/apps/linked"
	etc_before="$(stat -c %U /etc)"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; app_root_create '$user' '/home/$user/.ivarse/apps/linked'"
	assert_failure
	assert_equal "$(stat -c %U /etc)" "$etc_before"
	rm -f "/home/$user/.ivarse/apps/linked"
}

@test "AppRegistry: Creating an app root validates before it creates" {
	# v-add-fs-directory also permits /tmp, so validating only afterwards left
	# a stray directory behind on a rejected call.
	rm -rf /tmp/ivarse-stray
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; app_root_create '$user' '/tmp/ivarse-stray'"
	assert_failure
	assert_dir_not_exist "/tmp/ivarse-stray"
}

@test "AppRegistry: Creating an app root enforces the path format itself" {
	inject="$(printf '/home/%s/web/%s/private/a\nExecStartPost=/bin/id' "$user" "$domain")"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; app_root_create '$user' \"\$1\"" _ "$inject"
	assert_failure $E_INVALID
	assert_output --partial 'may only contain'
}

@test "AppRegistry: Containment checks refuse to run without HOMEDIR" {
	# Without HOMEDIR the home would be computed as "/$user" and every
	# containment check would be answering the wrong question.
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; HOMEDIR=''; app_root_assert_safe '$user' '/home/$user'"
	assert_failure $E_INVALID
	assert_output --partial 'HOMEDIR is not set'
}

@test "AppRegistry: assert_safe echoes the resolved path" {
	runuser -u "$user" -- mkdir -p "/home/$user/.ivarse/apps/frontend/sub"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; app_root_assert_safe '$user' '/home/$user/.ivarse/apps/frontend'"
	assert_success
	assert_output "/home/$user/.ivarse/apps/frontend"
}

@test "AppRegistry: assert_safe refuses a path outside the managed base" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; app_root_assert_safe '$user' '/home/$user/web'"
	assert_failure $E_FORBIDEN
}

@test "AppRegistry: assert_safe refuses a path that is not a directory" {
	touch "/home/$user/.ivarse/apps/afile"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; app_root_assert_safe '$user' '/home/$user/.ivarse/apps/afile'"
	assert_failure $E_NOTEXIST
	assert_output --partial 'not a directory'
	rm -f "/home/$user/.ivarse/apps/afile"
}

@test "NodejsKeys: A refreshed keyring takes precedence over the bundled one" {
	local_kr="$HESTIA/data/ivarse/nodejs/release-keys.asc"
	run bash -c "source /etc/hestiacp/hestia.conf; source $HESTIA/func/main.sh; source $HESTIA/func/node.sh; echo \$NODE_RELEASE_KEYRING"
	assert_output --partial "install/common/nodejs/release-keys.asc"

	mkdir -p "$(dirname "$local_kr")"
	cp "$HESTIA/install/common/nodejs/release-keys.asc" "$local_kr"
	run bash -c "source /etc/hestiacp/hestia.conf; source $HESTIA/func/main.sh; source $HESTIA/func/node.sh; echo \$NODE_RELEASE_KEYRING"
	assert_output "$local_kr"
	rm -f "$local_kr"
}

@test "NodejsKeys: Refreshing the keyring produces a parseable keyring" {
	run v-update-sys-nodejs-keys
	assert_success
	assert_output --partial "Refreshed"
	assert_file_exist "$HESTIA/data/ivarse/nodejs/release-keys.asc"
	run bash -c "gpg --dearmor < $HESTIA/data/ivarse/nodejs/release-keys.asc | wc -c"
	[ "$output" -gt 0 ]
}

@test "NodejsKeys: A runtime still verifies against the refreshed keyring" {
	run v-add-sys-nodejs 22
	assert_success
	run v-delete-sys-nodejs 22
	assert_success
	rm -f "$HESTIA/data/ivarse/nodejs/release-keys.asc"
}

@test "AppRegistry: An app name is not usable as a search pattern" {
	# Unvalidated, a name like '.*' matched every record at once and the parser
	# merged them into a single malformed object while exiting 0.
	write_app "alpha" "alpha.$domain" 30003
	write_app "beta" "beta.$domain" 30004
	run v-list-node-app "$user" '.*'
	assert_failure $E_INVALID
	assert_output --partial 'invalid app name format'
	refute_output --partial 'Duplicate key'
}

@test "AppRegistry: A duplicated record does not merge into one object" {
	write_app "alpha" "dupe.$domain" 30005
	run v-list-node-app "$user" alpha plain
	assert_success
	refute_output --partial 'Duplicate key'
	assert_output --partial "alpha.$domain"
}

@test "AppRegistry: Remove the test user" {
	run v-delete-user "$user"
	assert_success
}

