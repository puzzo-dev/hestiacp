#!/usr/bin/env bats

# Application lifecycle (I-Varse)
#
# F4 is the first consumer of the primitives built in F2a/F2b/F2c and F3, so
# these check that it uses them rather than working around them.

if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
	. /etc/profile.d/hestia.sh
fi

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/bats-file/load'

function setup() {
	user="ivarse-crud"
	other="ivarse-crud2"
	domain="crud.local.test"
	otherdomain="crud2.local.test"
	source $HESTIA/func/main.sh
	source $HESTIA/func/node.sh
	source $HESTIA/func/app.sh
}

@test "Crud: Prepare users, domains and a runtime" {
	v-delete-user "$user" > /dev/null 2>&1 || true
	v-delete-user "$other" > /dev/null 2>&1 || true
	run v-add-user "$user" "Sup3rSecret!23" "$user@example.com" default "Crud"
	assert_success
	run v-add-user "$other" "Sup3rSecret!23" "$other@example.com" default "Crud2"
	assert_success
	run v-add-web-domain "$user" "$domain"
	assert_success
	run v-add-web-domain "$other" "$otherdomain"
	assert_success
	v-add-sys-nodejs 22 > /dev/null 2>&1 || true
	assert_file_executable "/opt/ivarse/node/22/bin/node"
}

@test "Crud: Add an application with defaults" {
	run v-add-node-app "$user" "$domain" frontend
	assert_success
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.RUNTIME'"
	assert_output "node"
}

@test "Crud: The port comes from the allocator range" {
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.PORT'"
	[ "$output" -ge "$APP_PORT_MIN" ]
	[ "$output" -le "$APP_PORT_MAX" ]
}

@test "Crud: The app root is the managed, unswappable location" {
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.APP_ROOT'"
	assert_output "/home/$user/.ivarse/apps/frontend"
	assert_dir_exist "/home/$user/.ivarse/apps/frontend"
	run stat -c "%U:%G" "/home/$user/.ivarse/apps/frontend"
	assert_output "$user:$user"
	run stat -c "%U:%G" "/home/$user/.ivarse/apps"
	assert_output "root:root"
}

@test "Crud: The service name is runtime-scoped" {
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.SERVICE_NAME'"
	assert_output "ivarse-node-$user-frontend"
}

@test "Crud: The registry is not world-readable" {
	# It carries every application's layout for that user.
	run stat -c "%U:%G %a" "$HESTIA/data/users/$user/app.conf"
	assert_output "root:$user 660"
}

@test "Crud: A second application gets a different port" {
	first=$(v-list-node-app "$user" frontend plain | awk '{print $6}')
	run v-add-node-app "$user" "$domain" api
	assert_success
	second=$(v-list-node-app "$user" api plain | awk '{print $6}')
	[ "$first" != "$second" ]
}

@test "Crud: Adding the same application twice is refused" {
	run v-add-node-app "$user" "$domain" frontend
	assert_failure $E_EXISTS
	assert_output --partial 'exists'
}

@test "Crud: A domain belonging to another user is refused" {
	run v-add-node-app "$user" "$otherdomain" stolen
	assert_failure
	run v-list-node-app "$user" stolen
	assert_failure $E_NOTEXIST
}

@test "Crud: An explicit port that is taken is refused" {
	taken=$(v-list-node-app "$user" frontend plain | awk '{print $6}')
	run v-add-node-app "$user" "$domain" clash 22 "$taken"
	assert_failure $E_EXISTS
	assert_output --partial 'already in use'
}

@test "Crud: A port outside the range is refused" {
	run v-add-node-app "$user" "$domain" badport 22 9000
	assert_failure $E_INVALID
}

@test "Crud: An uninstalled runtime is refused" {
	run v-add-node-app "$user" "$domain" oldnode 18
	assert_failure $E_NOTEXIST
	assert_output --partial 'not installed'
}

@test "Crud: A start command with shell metacharacters is refused" {
	run v-add-node-app "$user" "$domain" evil 22 "" npm 'npm start; id'
	assert_failure $E_INVALID
	run v-add-node-app "$user" "$domain" evil2 22 "" npm "$(printf 'npm start\nUser=root')"
	assert_failure $E_INVALID
}

@test "Crud: An invalid package manager is refused" {
	run v-add-node-app "$user" "$domain" badpm 22 "" cargo
	assert_failure $E_INVALID
}

@test "Crud: Change the port" {
	free=$((APP_PORT_MIN + 500))
	run v-change-node-app-port "$user" frontend "$free"
	assert_success
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.PORT'"
	assert_output "$free"
}

@test "Crud: Changing to a port in use is refused" {
	other_port=$(v-list-node-app "$user" api plain | awk '{print $6}')
	run v-change-node-app-port "$user" frontend "$other_port"
	assert_failure $E_EXISTS
}

@test "Crud: Change the runtime version" {
	v-add-sys-nodejs 24 > /dev/null 2>&1 || true
	run v-change-node-app-runtime "$user" frontend 24
	assert_success
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.RUNTIME_VERSION'"
	assert_output "24"
}

@test "Crud: Change the start and build commands" {
	run v-change-node-app-command "$user" frontend start 'node server.js'
	assert_success
	run bash -c "v-list-node-app '$user' frontend json | jq -r '.frontend.START_COMMAND'"
	assert_output "node server.js"
	run v-change-node-app-command "$user" frontend build ''
	assert_success
}

@test "Crud: An empty start command is refused" {
	run v-change-node-app-command "$user" frontend start ''
	assert_failure $E_INVALID
}

@test "Crud: A command with metacharacters is refused on change" {
	run v-change-node-app-command "$user" frontend start 'node server.js && id'
	assert_failure $E_INVALID
}

@test "Crud: Delete keeps files by default" {
	run v-delete-node-app "$user" api
	assert_success
	run v-list-node-app "$user" api
	assert_failure $E_NOTEXIST
	assert_dir_exist "/home/$user/.ivarse/apps/api"
}

@test "Crud: Delete with DELETE_FILES removes the app root" {
	run v-add-node-app "$user" "$domain" temp
	assert_success
	assert_dir_exist "/home/$user/.ivarse/apps/temp"
	run v-delete-node-app "$user" temp yes
	assert_success
	assert_dir_not_exist "/home/$user/.ivarse/apps/temp"
}

@test "Crud: A deleted application frees its port" {
	before=$(v-list-node-app "$user" frontend plain | awk '{print $6}')
	run v-delete-node-app "$user" frontend yes
	assert_success
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; app_port_lock_acquire; is_app_port_available $before"
	assert_success
}

@test "Crud: Deleting an unknown application is refused" {
	run v-delete-node-app "$user" nosuchapp
	assert_failure $E_NOTEXIST
}

@test "Crud: Clean up" {
	run v-delete-user "$user"
	assert_success
	run v-delete-user "$other"
	assert_success
}
