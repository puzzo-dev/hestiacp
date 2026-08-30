#!/usr/bin/env bats

# Application port allocation (I-Varse)

if [ "${PATH#*/usr/local/hestia/bin*}" = "$PATH" ]; then
	. /etc/profile.d/hestia.sh
fi

load 'test_helper/bats-support/load'
load 'test_helper/bats-assert/load'
load 'test_helper/bats-file/load'

function setup() {
	user="ivarse-porttest"
	user2="ivarse-porttest2"
	source $HESTIA/func/main.sh
	source $HESTIA/func/app.sh
	conf="$HESTIA/data/users/$user/app.conf"
	conf2="$HESTIA/data/users/$user2/app.conf"
}

function write_app() {
	printf "NAME='%s' DOMAIN='x.test' RUNTIME='node' RUNTIME_VERSION='22' APP_ROOT='/home/%s/.ivarse/apps/%s' PORT='%s' PACKAGE_MANAGER='npm' BUILD_COMMAND='' START_COMMAND='npm start' SERVICE_NAME='ivarse-node-%s-%s' SUSPENDED='no' TIME='12:00:00' DATE='2026-08-30'\n" \
		"$1" "$3" "$1" "$2" "$3" "$1" >> "$4"
}

@test "Ports: Create test users" {
	v-delete-user "$user" > /dev/null 2>&1 || true
	v-delete-user "$user2" > /dev/null 2>&1 || true
	run v-add-user "$user" "Sup3rSecret!23" "$user@example.com" default "Port Test"
	assert_success
	run v-add-user "$user2" "Sup3rSecret!23" "$user2@example.com" default "Port Test 2"
	assert_success
}

@test "Ports: The range sits below the kernel ephemeral range" {
	# Overlapping it means an outgoing connection can transiently hold an
	# application's port, so the application fails to bind on its next
	# restart - intermittently, and for reasons unrelated to itself.
	ephemeral_low="$(sysctl -n net.ipv4.ip_local_port_range | awk '{print $1}')"
	[ "$APP_PORT_MAX" -lt "$ephemeral_low" ]
}

@test "Ports: The range is clear of php-fpm's allocator" {
	[ "$APP_PORT_MIN" -gt 9999 ]
}

@test "Ports: First allocation returns the bottom of the range" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; get_next_app_port"
	assert_success
	assert_output "$APP_PORT_MIN"
}

@test "Ports: A claimed port is skipped" {
	write_app "a" "$APP_PORT_MIN" "$user" "$conf"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; get_next_app_port"
	assert_output "$((APP_PORT_MIN + 1))"
}

@test "Ports: Ports claimed by another user are skipped" {
	# Ports belong to the host, not to a user. A per-user scan would hand the
	# same port to two different users.
	write_app "b" "$((APP_PORT_MIN + 1))" "$user2" "$conf2"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; get_next_app_port"
	assert_output "$((APP_PORT_MIN + 2))"
}

@test "Ports: A gap left by a deleted application is reused" {
	sed -i "/NAME='a'/d" "$conf"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; get_next_app_port"
	assert_output "$APP_PORT_MIN"
}

@test "Ports: A port held by an unrelated process is skipped" {
	# The registry cannot know about a process outside Hestia. Handing out its
	# port would leave the application unable to start, blaming the wrong thing.
	port="$APP_PORT_MIN"
	nc -l -s 127.0.0.1 -p "$port" > /dev/null 2>&1 &
	listener=$!
	sleep 1
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; get_next_app_port"
	kill "$listener" > /dev/null 2>&1 || true
	refute_output "$port"
}

@test "Ports: is_app_port_available agrees with the allocator" {
	write_app "c" "$APP_PORT_MIN" "$user" "$conf"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_port_available $APP_PORT_MIN"
	assert_failure
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_port_available $((APP_PORT_MIN + 50))"
	assert_success
}

@test "Ports: Allocation is serialised by a lock" {
	# Without the lock, two concurrent creations are handed the same port: the
	# first has not written its record when the second scans.
	run bash -c "
		source $HESTIA/func/main.sh; source $HESTIA/func/app.sh
		app_port_lock_acquire
		( source $HESTIA/func/main.sh; source $HESTIA/func/app.sh
		  APP_PORT_LOCK_FD=''; app_port_lock_acquire && echo SECOND-GOT-LOCK ) &
		sleep 2
		app_port_lock_release
		wait
	"
	assert_success
	assert_output --partial "SECOND-GOT-LOCK"
}

@test "Ports: A PORT field at the start of a line is still seen" {
	# The scan originally required whitespace before PORT=, so a record with
	# it first was missed entirely - which means the same port handed out to
	# two applications.
	# Both registries: ports are host-global, so a claim left by the other
	# user is correctly counted and would move the expected answer.
	: > "$conf2"
	printf "PORT='%s' NAME='edge'\n" "$APP_PORT_MIN" > "$conf"
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; get_next_app_port"
	assert_output "$((APP_PORT_MIN + 1))"
	: > "$conf"
}

@test "Ports: Allocation stays fast on a nearly full range" {
	# Scanning with two subprocesses per candidate took over five seconds.
	: > "$conf2"
	python3 -c "open('$conf','w').write('\n'.join(\"NAME='a%d' PORT='%d'\" % (i,i) for i in range($APP_PORT_MIN, $APP_PORT_MAX)) + '\n')"
	start=$(date +%s%N)
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; get_next_app_port"
	elapsed=$(( ($(date +%s%N) - start) / 1000000 ))
	assert_success
	assert_output "$APP_PORT_MAX"
	[ "$elapsed" -lt 1000 ]
	: > "$conf"
}

@test "Ports: Reject a port outside the range" {
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_port_format_valid $((APP_PORT_MAX + 1))"
	assert_failure $E_INVALID
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_port_format_valid $((APP_PORT_MIN - 1))"
	assert_failure $E_INVALID
	run bash -c "source $HESTIA/func/main.sh; source $HESTIA/func/app.sh; is_app_port_format_valid $APP_PORT_MAX"
	assert_success
}

@test "Ports: Exhaustion is reported, not silently wrong" {
	run bash -c "
		source $HESTIA/func/main.sh; source $HESTIA/func/app.sh
		APP_PORT_MIN=31000; APP_PORT_MAX=31000
		printf \"NAME='z' PORT='31000'\n\" >> $conf
		get_next_app_port
	"
	assert_failure $E_LIMIT
	assert_output --partial "no free application port"
	sed -i "/NAME='z'/d" "$conf"
}

@test "Ports: Remove the test users" {
	run v-delete-user "$user"
	assert_success
	run v-delete-user "$user2"
	assert_success
}
