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

# Loopback port range for applications.
#
# Clear of php-fpm, whose allocator in v-change-web-domain-backend-tpl starts
# at 9000, and - more importantly - entirely below the kernel's ephemeral
# range. On a default Linux host that is 32768-60999, so the obvious
# 30000-39999 would overlap it by more than seven thousand ports: an outgoing
# connection could transiently hold an application's port, and the application
# would then fail to bind on its next restart. That failure is intermittent and
# depends on unrelated traffic, which makes it a miserable one to diagnose.
#
# 30000-32767 stays below the ephemeral floor, which leaves 2768 applications
# per host. A host needing more should reserve a wider range with
# net.ipv4.ip_local_reserved_ports and widen APP_PORT_MAX to match, rather than
# overlapping the ephemeral range.
APP_PORT_MIN=30000
APP_PORT_MAX=32767

# Serialises port allocation. Allocation and recording must happen under the
# same lock, otherwise two concurrent creations can be handed the same port:
# the first has not written its record by the time the second scans for one in
# use.
APP_PORT_LOCK="/run/lock/ivarse-app-ports.lock"

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
#                    Port allocation                        #
#----------------------------------------------------------#

# Take the allocation lock. Callers must hold it across both choosing a port
# and writing the record that claims it.
app_port_lock_acquire() {
	mkdir -p "$(dirname "$APP_PORT_LOCK")" 2> /dev/null
	exec {APP_PORT_LOCK_FD}> "$APP_PORT_LOCK" || return 1
	flock -w 30 "$APP_PORT_LOCK_FD" || {
		check_result "$E_LIMIT" "timed out waiting for the port allocation lock"
	}
}

app_port_lock_release() {
	[ -n "$APP_PORT_LOCK_FD" ] || return 0
	flock -u "$APP_PORT_LOCK_FD" 2> /dev/null
	exec {APP_PORT_LOCK_FD}>&- 2> /dev/null
	APP_PORT_LOCK_FD=""
}

# Ports claimed by applications, across every user. Ports are a property of the
# host, not of a user, so a per-user scan would hand the same port to two
# different users.
app_ports_claimed() {
	local conf
	for conf in "$HESTIA"/data/users/*/app.conf; do
		[ -f "$conf" ] || continue
		# The field may begin a line, so do not require whitespace before it -
		# a missed claim means the same port handed out twice.
		grep -o "\(^\|[[:space:]]\)PORT='[0-9]\{1,5\}'" "$conf" 2> /dev/null \
			| grep -o "[0-9]\{1,5\}"
	done
}

# Ports something is currently listening on. The registry alone is not enough:
# a process outside Hestia's knowledge may hold a port, and handing it to an
# application would leave that application unable to start with a message
# pointing at the wrong thing.
app_ports_listening() {
	if [ -z "$(command -v ss)" ]; then
		return 0
	fi
	ss -ltnH 2> /dev/null | awk '{print $4}' | sed -n 's/.*:\([0-9]\{1,5\}\)$/\1/p'
}

# Is a port free, by both measures?
is_app_port_available() {
	local port="$1"
	app_ports_claimed | grep -qx "$port" && return 1
	app_ports_listening | grep -qx "$port" && return 1
	return 0
}

# Ports that cannot be handed out, as an associative array in the caller's
# scope. Built once so that scanning the range does not spawn two processes per
# candidate: with a nearly full range that took over five seconds.
app_ports_taken_into() {
	local -n _taken="$1"
	local p
	while read -r p; do
		[ -n "$p" ] && _taken["$p"]=1
	done < <(
		app_ports_claimed
		app_ports_listening
	)
}

# Lowest free port in the application range.
#
# The caller must already hold the allocation lock, and must write the record
# claiming the port before releasing it.
get_next_app_port() {
	local port
	local -A taken=()

	app_ports_taken_into taken

	for ((port = APP_PORT_MIN; port <= APP_PORT_MAX; port++)); do
		[ -n "${taken[$port]:-}" ] && continue
		echo "$port"
		return 0
	done

	check_result "$E_LIMIT" "no free application port in $APP_PORT_MIN-$APP_PORT_MAX"
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

# The application root must be inside the owning user's home directory, both as
# written and after symlinks are resolved.
#
# Resolution is not optional hardening. APP_ROOT is created and chowned by
# commands that run as root, so a symlink is a direct privilege escalation:
#
#   ln -s /etc /home/alice/web/site/app
#   chown -R alice:alice /home/alice/web/site/app   # run as root
#   -> /etc is now owned by alice
#
# realpath -m is used because the directory need not exist yet; it resolves the
# components that do exist and leaves the rest lexically normalised.
#
# Callers that create or write through this path must still pass the *resolved*
# path to mkdir, chown and systemd, never the path as supplied. Resolving here
# and then using the raw value elsewhere reintroduces the same hole.
is_app_root_format_valid() {
	local path="$1" user="$2" home resolved resolved_home

	app_env_required
	case "$path" in
		/*) ;;
		*) check_result "$E_INVALID" "app root must be an absolute path :: $path" ;;
	esac
	case "$path" in
		*..*) check_result "$E_INVALID" "app root must not contain '..' :: $path" ;;
	esac

	# Restrict to characters a real application root needs. This is not
	# tidiness: the path is written into a systemd unit as WorkingDirectory,
	# and a newline there lets a caller append further directives -
	#
	#   WorkingDirectory=/home/u/app
	#   ExecStartPost=/bin/id
	#   User=root
	#
	# systemd honours the last User=, so a newline in this value is arbitrary
	# execution as root. The same value also reaches shell commands and nginx
	# configuration, so quote characters and shell metacharacters are refused
	# for the same reason.
	if [ ${#path} -gt 4096 ]; then
		check_result "$E_INVALID" "app root is too long"
	fi
	if ! [[ "$path" =~ ^[A-Za-z0-9/._-]+$ ]]; then
		check_result "$E_INVALID" "app root may only contain letters, digits and / . _ - :: $path"
	fi

	# Containment is against the managed base rather than the home directory.
	# Everywhere else in the home is user-writable, so a name there can be
	# deleted and replaced with a symlink; under the base it cannot.
	home="$(app_root_base "$user")"
	case "$path" in
		"$home"/*) ;;
		*) check_result "$E_FORBIDEN" "app root must be under $home :: $path" ;;
	esac

	# Compare resolved against resolved. The home may itself sit behind a
	# symlink - homes on mounted storage are often /home -> /srv/home - and
	# comparing a resolved path against an unresolved base would reject every
	# legitimate application root on such a host.
	resolved="$(app_root_resolve "$path")"
	resolved_home="$(app_root_resolve "$home")"
	if [ -z "$resolved" ] || [ -z "$resolved_home" ]; then
		check_result "$E_INVALID" "unable to resolve app root :: $path"
	fi
	case "$resolved" in
		"$resolved_home"/*) ;;
		*) check_result "$E_FORBIDEN" "app root resolves outside $home :: $path -> $resolved" ;;
	esac

	# Exactly one component below the base. Without this, ".../apps/x/",
	# ".../apps//x" and ".../apps/./x" are all accepted and all store a
	# different string for the same directory, so a value written into a unit
	# file would not compare equal to the same application's root read back
	# later. A nested path also failed with a confusing "unable to create"
	# from mkdir rather than saying what was wrong.
	if ! [[ "${resolved#"$resolved_home"/}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
		check_result "$E_INVALID" "app root must be a single directory directly under $home :: $path"
	fi
}

# Resolve an application root to its real path, following symlinks in any
# component that already exists. Echoes nothing if the path cannot be resolved.
app_root_resolve() {
	realpath -m -- "$1" 2> /dev/null
}

# These come from Hestia's configuration and main.sh. If either is empty - for
# instance because this file was sourced on its own - the home directory would
# be computed as "/$user" and every containment check below would be answering
# the wrong question. Refuse rather than answer it wrongly.
app_env_required() {
	if [ -z "$HOMEDIR" ]; then
		check_result "$E_INVALID" "HOMEDIR is not set; source hestia.conf before func/app.sh"
	fi
	if [ -z "$BIN" ]; then
		check_result "$E_INVALID" "BIN is not set; source func/main.sh before func/app.sh"
	fi
}

# Where application roots live.
#
# NOT under web/<domain>/. Every directory a user can write to is a directory
# where they can delete a name and replace it with a symlink, which is the
# race that F2b closed only for the moment of creation. Putting the root
# somewhere with no user-writable component above it removes the race entirely
# rather than mitigating it:
#
#   /home/<user>            root:root 751   Hestia's own layout, user cannot write
#   /home/<user>/.ivarse    root:root 755   ours, user cannot write
#   .../apps                root:root 755   user cannot write, so <app> cannot
#                                           be deleted and re-pointed
#   .../apps/<app>          user:user 755   the user owns the contents
#
# The user writes freely inside the application root - that is where their
# code lives - but cannot replace the root itself. Anything they symlink
# inside it is their own business, reachable with their own privileges.
app_root_base() {
	echo "$HOMEDIR/$1/.ivarse/apps"
}

# The default, and only permitted, application root.
app_default_root() {
	echo "$(app_root_base "$1")/$2"
}

# Create an application root.
#
# The parent chain is root-owned and not user-writable, so creating it as root
# is safe: no name along the path can have been pre-empted by a symlink. The
# leaf is then handed to the user so their application can write into it.
#
# mkdir without -p on the leaf is deliberate. It fails if anything already
# exists at that name, including a symlink, rather than silently accepting it.
app_root_create() {
	local user="$1" path="$2" base component

	app_env_required
	is_app_root_format_valid "$path" "$user"

	base="$(app_root_base "$user")"

	# Build the parent chain one component at a time, refusing any component
	# that is already a symlink. mkdir -p and chown both follow a symlink, so
	# a link at .ivarse would have this creating and chowning directories
	# wherever it pointed - measured: it created /etc/apps.
	#
	# /home/<user> is root-owned and not user-writable, so an unprivileged user
	# cannot plant such a link today. This does not depend on that remaining
	# true: a restored backup or another tool could create one, and this is the
	# component every other guarantee rests on.
	for component in "$HOMEDIR/$user/.ivarse" "$base"; do
		if [ -L "$component" ]; then
			check_result "$E_FORBIDEN" "app root base component is a symlink :: $component"
		fi
		if [ ! -d "$component" ]; then
			if ! mkdir -- "$component" 2> /dev/null; then
				check_result "$E_DISK" "unable to create $component"
			fi
		fi
		chown root:root "$component"
		chmod 755 "$component"
	done

	if [ -L "$path" ]; then
		check_result "$E_EXISTS" "app root exists and is a symlink :: $path"
	fi
	if [ ! -d "$path" ]; then
		if ! mkdir -- "$path" 2> /dev/null; then
			check_result "$E_EXISTS" "unable to create app root :: $path"
		fi
	fi

	chown "$user:$user" "$path"
	chmod 755 "$path"

	app_root_assert_safe "$user" "$path" > /dev/null
}

# Re-check an application root at the moment it is used, and echo the resolved
# path. Callers must use what this echoes, never the value they passed in.
#
# Two reasons. It is the resolved path, so it does not traverse anything the
# caller supplied. And it is canonical: ".../apps/x/", ".../apps//x" and
# ".../apps/./x" all name the same directory, so storing the raw value would
# mean the same application's root not comparing equal to itself later, and a
# unit file disagreeing with the registry.
#
# Call it immediately before use, not once at the start of a long command.
app_root_assert_safe() {
	local user="$1" path="$2" home resolved resolved_home

	app_env_required
	home="$HOMEDIR/$user"
	resolved="$(app_root_resolve "$path")"
	resolved_home="$(app_root_resolve "$(app_root_base "$user")")"

	if [ -z "$resolved" ] || [ -z "$resolved_home" ]; then
		check_result "$E_INVALID" "unable to resolve app root :: $path"
	fi
	# Containment is against the managed base, not merely the home directory.
	# Anywhere else in the home is user-writable, and therefore swappable.
	case "$resolved" in
		"$resolved_home"/*) ;;
		*) check_result "$E_FORBIDEN" "app root must be under $(app_root_base "$user") :: $path -> $resolved" ;;
	esac
	if [ ! -d "$resolved" ]; then
		check_result "$E_NOTEXIST" "app root is not a directory :: $resolved"
	fi

	echo "$resolved"
}

# Commands become a systemd ExecStart and are run as the owning user. Reject
# shell metacharacters rather than trying to quote them safely. Newlines are
# included, since a newline would otherwise let a caller append further
# directives such as ExecStartPost= to the generated unit.
#
# Note for whoever writes the unit file: '%' is still permitted here because it
# is harmless as an argument, but systemd treats it as a specifier prefix, so it
# must be written as '%%' in the unit.
is_app_command_format_valid() {
	if [ ${#1} -gt 512 ]; then
		check_result "$E_INVALID" "$2 is too long"
	fi
	if [[ "$1" =~ [\;\&\|\<\>\`\$\(\)\{\}\\\'\"$'\n'] ]]; then
		check_result "$E_INVALID" "invalid $2 format :: shell metacharacters are not allowed"
	fi
}
