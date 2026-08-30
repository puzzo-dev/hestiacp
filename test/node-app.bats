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

@test "AppRegistry: An app root outside the user's home is refused" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; HOMEDIR=/home; is_app_root_format_valid '/etc' '$user'"
	assert_failure $E_FORBIDEN
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; HOMEDIR=/home; is_app_root_format_valid '/home/otheruser/web/x/app' '$user'"
	assert_failure $E_FORBIDEN
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; HOMEDIR=/home; is_app_root_format_valid '/home/$user/web/x/app/../../../etc' '$user'"
	assert_failure $E_INVALID
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; HOMEDIR=/home; is_app_root_format_valid '/home/$user/web/x/app' '$user'"
	assert_success
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
	for good in "app" "my-app_2" "web/site.com/app" "a.b-c_d/app"; do
		run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid \"\$1\" '$user'" _ "/home/$user/$good"
		assert_success
	done
}

@test "AppRegistry: A symlinked app root that escapes the home is refused" {
	# Without resolution this is a root privilege escalation: APP_ROOT is
	# created and chowned by commands running as root, so a symlink to /etc
	# turns "chown -R $user $APP_ROOT" into handing /etc to that user.
	mkdir -p "/home/$user/web/symsite"
	ln -sfn /etc "/home/$user/web/symsite/app"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/web/symsite/app' '$user'"
	assert_failure $E_FORBIDEN
	assert_output --partial 'resolves outside'
	rm -f "/home/$user/web/symsite/app"
}

@test "AppRegistry: A symlink pointing to another user is refused" {
	mkdir -p "/home/$user/web/symsite"
	ln -sfn /home/admin "/home/$user/web/symsite/app"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/web/symsite/app' '$user'"
	assert_failure $E_FORBIDEN
	rm -f "/home/$user/web/symsite/app"
}

@test "AppRegistry: A symlink staying inside the home is allowed" {
	mkdir -p "/home/$user/web/symsite" "/home/$user/realapp"
	ln -sfn "/home/$user/realapp" "/home/$user/web/symsite/app"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/web/symsite/app' '$user'"
	assert_success
	rm -f "/home/$user/web/symsite/app"
}

@test "AppRegistry: A path that does not exist yet still validates" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_root_format_valid '/home/$user/web/notyet/app' '$user'"
	assert_success
}

@test "AppRegistry: app_root_resolve returns the real path" {
	mkdir -p "/home/$user/web/symsite" "/home/$user/realapp"
	ln -sfn "/home/$user/realapp" "/home/$user/web/symsite/app"
	run bash -c "source $HESTIA/func/app.sh; app_root_resolve '/home/$user/web/symsite/app'"
	assert_output "/home/$user/realapp"
	rm -f "/home/$user/web/symsite/app"
}

@test "AppRegistry: A symlinked home directory does not cause false rejections" {
	# Homes on mounted storage are often reached through a symlink, e.g.
	# /home -> /srv/home. Comparing a resolved path against an unresolved home
	# would reject every legitimate application root on such a host.
	mkdir -p "/srv/althome/$user/web/x"
	ln -sfn /srv/althome /altohome
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; HOMEDIR=/altohome; is_app_root_format_valid '/altohome/$user/web/x/app' '$user'"
	assert_success
	rm -f /altohome
	rm -rf /srv/althome
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

