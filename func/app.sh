# I-Varse Hestia — application registry
#
# The Application is the I-Varse primitive attached to a Hestia web domain.
# It is deliberately runtime-agnostic: Node is the first implementation, and
# Python, Docker and Cloudflare runtimes are meant to reuse this file
# unchanged.
#
# Applications live in $USER_DATA/app.conf, one KEY='value' line per
# application, which is the same record format Hestia uses for web.conf and
# friends. That means Hestia's own helpers work directly:
#
#   get_object_value    'app' 'NAME' "$app" '$PORT'
#   update_object_value 'app' 'NAME' "$app" '$PORT' '3001'
#   is_object_valid     'app' 'NAME' "$app"
#   search_objects      'app' 'RUNTIME' 'node' 'NAME'
#
# NAME is the key and is unique per user.
#
# Fields:
#   NAME             identifier, unique per user
#   DOMAIN           the Hestia web domain this application serves
#   RUNTIME          node | python | docker | cloudflare
#   RUNTIME_VERSION  major version of the runtime, e.g. 22
#   APP_ROOT         absolute path to the application, inside the user's home
#   PORT             loopback port the application listens on
#   PACKAGE_MANAGER  npm | pnpm | yarn | bun
#   BUILD_COMMAND    run before start, may be empty
#   START_COMMAND    the process systemd supervises
#   SERVICE_NAME     the generated systemd unit, without .service
#   SUSPENDED        yes | no
#   TIME, DATE       creation timestamp, as elsewhere in Hestia
#
# Deliberately absent: STATUS. Whether an application is running is a fact
# about systemd, not a value to be stored and kept in sync. It is derived by
# app_status, so the registry can never disagree with reality.

# Runtimes this build understands. Extended as each is implemented.
APP_RUNTIMES="node"

# Package managers a Node application may select
APP_PACKAGE_MANAGERS="npm pnpm yarn bun"

# Loopback port range for applications. Deliberately clear of php-fpm, whose
# allocator in v-change-web-domain-backend-tpl starts at 9000.
APP_PORT_MIN=30000
APP_PORT_MAX=39999

# Path to a user's application registry
app_conf() {
	echo "$HESTIA/data/users/$1/app.conf"
}

# Does an application exist for this user?
app_exists() {
	local conf
	conf="$(app_conf "$1")"
	[ -f "$conf" ] && grep -q "NAME='$2'" "$conf"
}

# All application names for a user, in file order
app_list() {
	local conf
	conf="$(app_conf "$1")"
	[ -f "$conf" ] || return 0
	sed -n "s/^NAME='\([^']*\)'.*/\1/p" "$conf"
}

# The systemd unit for an application, without the .service suffix.
# Runtime is part of the name so a later Python application on the same domain
# cannot collide with a Node one.
app_service_name() {
	local user="$1" app="$2" runtime="${3:-node}"
	echo "ivarse-${runtime}-${user}-${app}"
}

# Live state of an application, read from systemd rather than stored.
# Echoes one of: running, stopped, failed, unknown
app_status() {
	local unit="$1"
	if ! command -v systemctl > /dev/null 2>&1; then
		echo "unknown"
		return
	fi
	if [ ! -f "$NODE_SYSTEMD_DIR/$unit.service" ]; then
		echo "stopped"
		return
	fi
	case "$(systemctl is-active "$unit" 2> /dev/null)" in
		active) echo "running" ;;
		failed) echo "failed" ;;
		*) echo "stopped" ;;
	esac
}

# Is the application's unit enabled at boot? Echoes yes/no.
app_autostart() {
	if systemctl is-enabled "$1" > /dev/null 2>&1; then
		echo "yes"
	else
		echo "no"
	fi
}

#----------------------------------------------------------#
#                       Validators                          #
#----------------------------------------------------------#

is_app_name_format_valid() {
	if ! [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; then
		check_result "$E_INVALID" "invalid app name format :: $1"
	fi
}

is_app_runtime_format_valid() {
	local runtime
	for runtime in $APP_RUNTIMES; do
		[ "$1" = "$runtime" ] && return 0
	done
	check_result "$E_INVALID" "invalid runtime format :: $1"
}

is_app_pm_format_valid() {
	local pm
	for pm in $APP_PACKAGE_MANAGERS; do
		[ "$1" = "$pm" ] && return 0
	done
	check_result "$E_INVALID" "invalid package manager format :: $1"
}

is_app_port_format_valid() {
	if ! [[ "$1" =~ ^[0-9]{1,5}$ ]] \
		|| [ "$1" -lt "$APP_PORT_MIN" ] || [ "$1" -gt "$APP_PORT_MAX" ]; then
		check_result "$E_INVALID" "invalid app port format :: $1"
	fi
}

# The application root must resolve inside the owning user's home directory.
# It ends up as a systemd WorkingDirectory and as the target of a build run as
# that user, so a path escaping the home directory would cross the isolation
# boundary Hestia maintains between users.
is_app_root_format_valid() {
	local path="$1" user="$2" home
	case "$path" in
		/*) ;;
		*) check_result "$E_INVALID" "app root must be an absolute path :: $path" ;;
	esac
	case "$path" in
		*..*) check_result "$E_INVALID" "app root must not contain '..' :: $path" ;;
	esac
	home="$HOMEDIR/$user"
	case "$path" in
		"$home"/*) ;;
		*) check_result "$E_FORBIDEN" "app root must be inside $home :: $path" ;;
	esac
}

# Commands become a systemd ExecStart and are run as the owning user. Reject
# shell metacharacters rather than trying to quote them safely.
is_app_command_format_valid() {
	if [ ${#1} -gt 512 ]; then
		check_result "$E_INVALID" "$2 is too long"
	fi
	if [[ "$1" =~ [\;\&\|\<\>\`\$\(\)\{\}\\\'\"$'\n'] ]]; then
		check_result "$E_INVALID" "invalid $2 format :: shell metacharacters are not allowed"
	fi
}
