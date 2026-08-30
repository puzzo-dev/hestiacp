# I-Varse Hestia — Functionality Tracker

Single source of truth for what is built, in progress, and deferred.
Read `.claude/skills/ivarse-hestia/SKILL.md` before touching any item.

Base: `hestiacp/hestiacp` v1.10.4. **Hestia itself is not forked.** The
I-Varse work ships as a separate `hestia-ivarse` package that adds files under
`/usr/local/hestia/` and replaces none, so Hestia updates through its own
channels with no merge, no rebuild and no procedure. See `ivarse/UPSTREAM.md`.

**Status values:** `TODO` · `IN PROGRESS` · `IN REVIEW` · `DONE` · `BLOCKED` · `DEFERRED`

**Phase 1 goal (the only goal right now):** get `ivarseltd.com` and the Ofada
Girl site off Cloudflare Workers and back onto the Namecheap VPS, served as
Node apps managed by Hestia, still talking to the containerised multi-tenant
Payload CMS.

---

## The constraint everything obeys

**The add-on must never ship a path the `hestia` package owns.** That single
rule is what buys automatic upstream updates. It is enforced, not trusted:
`ivarse/build-package.sh` refuses to build on a conflict, and
`ivarse/testbox.sh verify` re-checks every installed file after install.

Before adding any path to `src/deb/ivarse/files.txt`:

```sh
dpkg -S /usr/local/hestia/<path>
```

If that names `hestia`, the file cannot be shipped and the feature needs a
different design. Items below are marked **adds-only** when they satisfy this,
and **needs divert** when they do not.

The old merge-risk tiers are gone. They existed to manage a fork; there is no
fork. What replaced them is this one rule plus the `needs divert` count, which
should stay at zero for as long as possible.

---

## Ordering rationale

Urgency is taken from `research.txt`: Phase 1 is *only* Node hosting, and within
it the objective is a working runtime before any UI polish or Git deployment.
F1–F8 are the critical path to a live HTTPS Next.js site. F9–F10 make it usable
without SSH. F11–F13 stop it corrupting the rest of Hestia. F14 keeps the
add-on honest over time.

Do not start F10 (UI) before F1–F8 are `DONE`. The CLI is the product; the panel
is a client of it.

---

## Phase 1 — Node hosting v1

### F0 · Add-on packaging + test box
- **Status:** IN REVIEW
- **Depends on:** —
- **Packaging:** adds-only ✅ — touches zero upstream files
- **Why first:** nothing can be verified until the work can be built and
  installed on a throwaway Hestia, and the shape of that package determines
  whether upstream releases are a routine event or a manual one.
- **Decided — ship as a separate `hestia-ivarse` package, not as a fork of
  `hestia`.** The first attempt forked the `hestia` package with a `+ivarse1`
  version and an apt pin. It worked, but made every upstream release manual:
  merge, resolve the `control` version conflict that recurred every time,
  rebuild, reinstall — and pinned Hestia away from its own security updates.
  Measured: installing upstream's `hestia` over that fork took the Node commands
  from four to zero, because dpkg removes the files the old version of *the same
  package* owned.
  A separate package that only *adds* files is untouched by a `hestia` upgrade.
  ✅ verified — with the add-on installed, an unattended `v-update-sys-hestia-all`
  upgraded Hestia and left every command, `func/node.sh`, the keyring and the
  installed runtimes working; a new runtime installed cleanly after the upgrade.
- **The one rule:** the add-on must never ship a path the `hestia` package owns.
  `build-package.sh` checks every entry in `src/deb/ivarse/files.txt` against
  dpkg's file database and refuses to build on a conflict; `testbox.sh verify`
  checks the same after install.
- **Decided — the test box is a Docker container**, not a second WSL distro or a
  VM. Upstream ships `.github/docker/hestia-ci.Dockerfile` (Ubuntu 26.04,
  systemd as PID 1); a Hestia install rewrites `/etc` heavily, so a disposable
  container is the right blast radius. Hestia is installed **stock** in the box,
  which is what makes `testbox.sh upgrade` a meaningful test.
- **Files:** `src/deb/ivarse/{control,postinst,files.txt}`,
  `ivarse/build-package.sh`, `ivarse/testbox.sh`, `ivarse/UPSTREAM.md` (all new)
- **Acceptance:** the package builds, installs onto stock Hestia with no file
  conflicts, and survives a Hestia upgrade.
- **Cost, stated plainly:** features that must change Hestia's own behaviour —
  a nav item in `panel.php`, a hook inside `v-delete-web-domain` — cannot be
  done by adding a file. Those need `dpkg-divert` or an upstream contribution,
  and each reintroduces an upgrade step for that file alone. Affects F10 and
  F11 only; F1–F9 are unaffected. Keep the count at zero as long as possible.

### F1 · Node runtime install + version management
- **Status:** IN REVIEW — PR #3, stacked on #2
- **Depends on:** F0
- **Packaging:** adds-only ✅
- **Decided:** official nodejs.org tarballs into `/opt/ivarse/node/<major>`,
  one directory per major, root-owned. NodeSource apt was rejected because apt
  can hold only one Node major at a time, which would defeat per-app pinning —
  the entire point of this item.
- **Files:** `func/node.sh`, `bin/v-{add,delete,list}-sys-nodejs`,
  `bin/v-change-sys-nodejs-default`, `test/nodejs.bats` (all new)
- **Consequence of adds-only:** the major-version validator is called directly
  rather than routed through `is_format_valid` in `func/main.sh`. Adding a case
  there would mean shipping a hestia-owned file — the build would refuse and the
  next Hestia upgrade would revert it. Mildly against Hestia convention; the
  alternative is a package that cannot be installed.
- **Acceptance:** two majors coexist, each pinnable. ✅ verified — 22.23.2 and
  24.20.0 side by side on stock Hestia, npm 10.9.8, corepack shims present.
- **Verified on a real installation:** 22/22 bats as root on stock Hestia,
  and again after Hestia was upgraded underneath the add-on.
- **Bugs found in review, all fixed:**
  - staging in `/tmp` made the final move a cross-filesystem copy rather than an
    atomic rename, so a failure could leave a partial runtime at the final path;
    it also buffered ~230MB through tmpfs. Now staged inside `NODE_ROOT`.
  - a directory existing without a working `bin/node` passed the "not installed"
    check, and `mv` then nested the runtime inside it while **reporting exit 0**.
    Now refused explicitly, and `mv -T` makes nesting impossible.
  - `mktemp`'s result was used unchecked; a failure would have written the
    download to `/`.
  - `xz-utils` was undeclared. It is `Priority: standard`, not required.

### F2 · Application registry + data model
- **Status:** IN REVIEW — PR #7
- **Depends on:** F0
- **Packaging:** adds-only ✅
- **Scope:** the runtime-agnostic `Application` object, plus the two listing
  commands. Creating and mutating applications is F4.
- **Decided — the registry is `$USER_DATA/app.conf`, not `node.conf`.**
  `research.txt` makes Application the primitive and Node the first
  implementation, so the file is named for the primitive. `RUNTIME='node'`
  distinguishes rows, and a later `v-add-python-app` writes to the same file.
  Because it uses Hestia's `KEY='value'` record format, Hestia's own helpers
  work against it unchanged — `get_object_value 'app' 'NAME' "$app" '$PORT'`
  and friends. ✅ verified in the suite.
- **Decided — `func/app.sh` is separate from `func/node.sh`.** The registry is
  the runtime-agnostic layer; `node.sh` stays Node-specific. Phase 2 reuses
  `app.sh` untouched, which is the test of whether the abstraction was right.
- **Decided — `APP_ROOT` defaults to `/home/<user>/web/<domain>/app`** as
  `research.txt` suggests, but is a stored, configurable field so an
  application can live elsewhere. It is validated to resolve inside the owning
  user's home, with `..` rejected: it becomes a systemd `WorkingDirectory` and
  the target of a build run as that user, so a path escaping the home directory
  would cross Hestia's isolation boundary.
- **Decided — `STATUS` is derived, never stored.** Whether an application is
  running is a fact about systemd. Storing it guarantees eventual disagreement
  with reality, so `app_status` reads `systemctl` and the registry cannot drift.
- **Files:** `func/app.sh`, `bin/v-list-node-app`, `bin/v-list-node-apps`,
  `test/node-app.bats` (all new)
- **Acceptance:** a hand-written record round-trips through `v-list-node-apps`
  in all four formats. ✅ verified — **16/16** on stock Hestia, including an
  empty registry emitting valid JSON.
- **Security:** command fields are rejected if they contain shell
  metacharacters. They become a systemd `ExecStart` run as the owning user, and
  they arrive from panel users, so quoting them safely is a losing game
  compared with refusing them.

### F2a · Resolve the application root before trusting it
- **Status:** IN REVIEW — PR pending
- **Depends on:** F2
- **Packaging:** adds-only ✅
- **Why:** not hardening — a **root privilege escalation**, demonstrated on the
  test box. `is_app_root_format_valid` checked the path as written, so a symlink
  passed:
  ```
  ln -s /etc /home/alice/web/site/app     # as the user
  chown -R alice:alice .../site/app       # as root, from F4
  -> /etc owner before: root
  -> /etc owner after:  alice
  ```
  From there `/etc/sudoers.d/` and `/etc/passwd` are writable and the box is gone.
- **Fix:** the validator now resolves with `realpath -m` — which works on paths
  that do not exist yet — and requires the **resolved** path to be inside the
  owning user's home. A symlink staying inside the home is still allowed.
- **Binding requirement on every later item:** commands that create or write
  through `APP_ROOT` must use the **resolved** path for `mkdir`, `chown` and
  systemd. Resolving here and then using the raw value elsewhere reintroduces
  the identical hole. This applies to F4, F5 and F7.
- **Files:** `func/app.sh`, `test/node-app.bats`
- **Acceptance:** a symlinked root escaping the home is refused; one pointing at
  another user is refused; one staying inside the home is allowed; a path that
  does not exist yet still validates.

### F3 · Port allocator
- **Status:** TODO
- **Depends on:** F2
- **Packaging:** adds-only ✅
- **Scope:** Allocate a free loopback port per app. Own range (proposal:
  30000–39999) so it never collides with php-fpm's 9000+ scanner. Allocation is
  recorded in the registry and cross-checked against live listeners (`ss -ltn`)
  — registry alone is not enough, a stray process can hold the port.
- **Files:** `func/node.sh` (`get_next_app_port`)
- **Acceptance:** allocating N apps yields N distinct ports; a port held by an
  unrelated process is skipped; a deleted app's port is reusable.
- **Do not:** reuse `v-change-web-domain-backend-tpl`'s scanner. It greps
  php-fpm pool files and is meaningless here.

### F4 · Application CRUD
- **Status:** TODO
- **Depends on:** F2, F3
- **Packaging:** adds-only ✅
- **Scope:** `v-add-node-app` (validate, allocate port, create `APP_ROOT`, write
  registry, generate unit + nginx include, do **not** auto-start),
  `v-delete-node-app` (stop, disable, remove unit, remove includes, free port,
  remove record), `v-change-node-app-*` for each mutable field.
  New `is_format_valid` cases for `app_name`, `runtime`, `runtime_version`,
  `app_port`, `package_manager`, `start_command`, `build_command` — the command
  fields need careful validation, they end up in a systemd `ExecStart`.
- **Files:** `bin/v-add-node-app`, `bin/v-delete-node-app`,
  `bin/v-change-node-app-*`. Validators live in `func/node.sh` and are called
  directly — `func/main.sh` belongs to `hestia` and cannot be shipped.
- **Acceptance:** add → list → change → delete leaves no unit file, no nginx
  include, no registry line, and no leaked port.
- **Security — carried forward from F2a, not optional:**
  - use the **resolved** `APP_ROOT` (`app_root_resolve`) for every `mkdir`,
    `chown` and path written into config. Using the raw value restores the
    root escalation F2a closed.
  - better still, create the directory **as the user** (`runuser -u "$user"`)
    rather than as root, so a symlink cannot be leveraged even if a check is
    missed.
  - start/build commands are attacker-controlled input from panel users that
    become root-generated systemd config. They are already refused if they
    contain shell metacharacters or newlines; keep that check on every path
    that accepts them.

### F5 · systemd unit generation + lifecycle
- **Status:** TODO
- **Depends on:** F1, F4
- **Packaging:** adds-only ✅
- **Scope:** Template `ivarse-node-{user}-{app}.service` under
  `/etc/systemd/system/`. `User=`/`Group=` the Hestia user, `WorkingDirectory=`
  the app root, `Environment=PORT=`, `Restart=on-failure`, hardening
  (`NoNewPrivileges`, `PrivateTmp`, `ProtectSystem=strict`, `ReadWritePaths=`).
  Then `v-start-node-app`, `v-stop-node-app`, `v-restart-node-app`,
  `v-rebuild-node-app`.
- **Files:** `install/deb/templates/node/service.tpl`,
  `bin/v-start-node-app`, `bin/v-stop-node-app`, `bin/v-restart-node-app`,
  `bin/v-rebuild-node-app`
- **Acceptance:** app survives `systemctl restart`, comes back after host reboot,
  and `ProtectSystem=strict` does not break Next.js's `.next/cache` writes.
- **Required when generating the unit — both carried from F2/F2a:**
  - **escape `%` as `%%`.** systemd treats `%` as a specifier prefix, so
    `npm start %n` would expand to the unit name and an unknown specifier makes
    the unit fail to start. `%` is allowed in commands because it is harmless as
    an argument; it is the unit writer's job to escape it. Needs a test with a
    literal `%` in the start command.
  - `WorkingDirectory` and `ReadWritePaths` must use the **resolved**
    `APP_ROOT`. `ReadWritePaths` on an unresolved symlink would hand systemd a
    path outside the user's home to make writable.
- **Reference:** `src/deb/web-terminal/hestia-web-terminal.service` — same shape,
  already shipping.

### F6 · Nginx integration
- **Status:** TODO
- **Depends on:** F3
- **Packaging:** adds-only ✅
- **Scope:** `nodejs.tpl` / `nodejs.stpl` that deliberately **omit `location /`**
  and keep the `nginx.conf_*` / `nginx.ssl.conf_*` includes. `v-add-node-app`
  writes `nginx.conf_ivarse_app` and `nginx.ssl.conf_ivarse_app` carrying the
  `location /` with `proxy_pass http://127.0.0.1:<port>`, `proxy_http_version
  1.1`, `Upgrade`/`Connection` for WebSockets, and `Host` / `X-Real-IP` /
  `X-Forwarded-For` / `X-Forwarded-Proto`. Serve `/_next/static` from disk.
- **Files:** `install/deb/templates/web/nginx/nodejs.{tpl,stpl}` and the
  `php-fpm/` variants
- **Acceptance:** HTTP and HTTPS both proxy; WebSocket upgrade completes;
  `v-rebuild-web-domains` does not break the app; Let's Encrypt issuance still
  works through `/.well-known/`.
- **Why this shape:** rebuild regenerates the tpl-derived config but never
  touches `nginx.conf_*`, so the port stays entirely inside our subsystem and no
  upstream template variable has to be added — `func/domain.sh` belongs to
  `hestia` and cannot be shipped.
- **Watch:** template selection differs between nginx-only and nginx+Apache
  installs. Confirm which the target VPS runs before writing the stpl.

### F7 · Build pipeline
- **Status:** TODO
- **Depends on:** F1, F4
- **Packaging:** adds-only ✅
- **Scope:** `v-build-node-app` runs install-then-build as the Hestia user via
  `runuser`, with a timeout, a concurrency guard, and full output captured to a
  build log. npm / pnpm / yarn / bun.
- **Files:** `bin/v-build-node-app`
- **Acceptance:** a Next.js app builds end to end; a failing build exits non-zero
  with the error visible in the build log and leaves the previous build serving.
- **Do not:** add `node`/`npm` to `v-run-cli-cmd`'s whitelist. That grants every
  panel user arbitrary `npm` execution. Fixed argv here instead.
- **Required:** run the build in the **resolved** `APP_ROOT`, and as the owning
  user. A build is the easiest place to follow a planted symlink by accident.

### F8 · Environment variables
- **Status:** TODO
- **Depends on:** F4, F5
- **Packaging:** adds-only ✅
- **Scope:** Per-app env file at `$USER_DATA/node/<app>.env`, mode 0600, injected
  via systemd `EnvironmentFile=`. Needed immediately — the frontends reach the
  Payload CMS through env config.
- **Files:** `bin/v-add-node-app-env`, `bin/v-delete-node-app-env`,
  `bin/v-list-node-app-env`
- **Acceptance:** a secret set through the CLI reaches `process.env`, is not
  world-readable, and does not appear in `journalctl` or the panel HTML.

### F9 · Logs, status, resource visibility
- **Status:** TODO
- **Depends on:** F5, F7
- **Packaging:** adds-only ✅
- **Scope:** `v-list-node-app-log` over `journalctl -u`, build log tail, running
  state, PID, CPU and RSS.
- **Files:** `bin/v-list-node-app-log`, `bin/v-list-node-app-status`
- **Acceptance:** logs readable from the CLI for a running and a crashed app.

### F10 · Panel UI
- **Status:** TODO
- **Depends on:** F4–F9
- **Packaging:** ⚠️ **needs divert** — the nav entry edits an upstream file
- **Scope:** List / add / edit pages matching the `research.txt` mockup (domain,
  app root, node version, package manager, build command, start command, port,
  env vars, create). Start/stop/restart controls, log viewer. All through
  `HESTIA_CMD` — the panel calls `v-*` and nothing else.
- **Files:** `web/list/node/`, `web/add/node/`, `web/edit/node/`,
  `web/templates/pages/{list,add,edit}_node.php`,
  `web/templates/includes/panel.php` (**hestia-owned**, see the note below)
- **Acceptance:** an app can be created, built, started and inspected without SSH.
- **Packaging problem:** new pages under `web/list/node/` etc. are adds-only and
  fine. The nav entry in `web/templates/includes/panel.php` is not — that file
  belongs to `hestia`. Options, none chosen yet: `dpkg-divert` plus a dpkg
  trigger that re-applies the edit after every Hestia upgrade; a small
  JS/CSS injection from a file we do own; or contributing a nav hook upstream.
  **Decide before starting.** Whatever is chosen reintroduces an upgrade step
  for that one file.

### F11 · Web domain lifecycle hooks
- **Status:** TODO
- **Depends on:** F4
- **Packaging:** ⚠️ **needs divert** — hooks live inside upstream commands
- **Scope:** Deleting or suspending a web domain must not orphan a systemd unit
  or leak a port. Add exactly one hook line to each upstream command and put all
  logic in `func/ivarse-hooks.sh`.
- **Files:** `func/ivarse-hooks.sh` (new, adds-only),
  `bin/v-delete-web-domain`, `bin/v-suspend-web-domain`,
  `bin/v-unsuspend-web-domain`, `func/rebuild.sh` — one `# IVARSE:` line each
- **Acceptance:** deleting a Node-backed domain removes the unit and frees the
  port; suspending stops the app; unsuspending restarts it.
- **Packaging problem:** `v-delete-web-domain` and the suspend/unsuspend
  commands belong to `hestia`. The add-on cannot patch them. Options, none
  chosen yet: `dpkg-divert` on those specific commands with a trigger to
  re-apply after upgrades; a systemd path unit watching `web.conf` for
  deletions; or contributing hook points upstream, which is the clean answer and
  the slow one. **Decide before starting.**
- **Interim safety:** until this exists, deleting a Node-backed web domain
  leaks a systemd unit and a port. Document it rather than pretend otherwise.

### F12 · Backup and restore
- **Status:** TODO
- **Depends on:** F2, F8
- **Packaging:** ⚠️ **needs divert** — hooks live inside upstream commands
- **Scope:** `v-backup-user` walks `web.conf` per domain and knows nothing about
  a separate registry, so app records, env files and the app root are **silently
  absent from backups** until hooked. Same on restore.
- **Packaging problem:** `v-backup-user` and `v-restore-user` belong to
  `hestia`. Same constraint as F11. A separate `v-backup-node-apps` the admin or
  a cron calls alongside Hestia's backup avoids diverting anything and is
  probably the right first answer.
- **Files:** `bin/v-backup-node-apps`, `bin/v-restore-node-apps` (new, adds-only)
- **Acceptance:** back up a user with a running Node app, restore onto a clean
  box, app starts and serves.
- **Note:** this gap is not in `research.txt` and is easy to discover only after
  losing data. Do not defer it past the first real site migration.

### F13 · Permissions, isolation, limits
- **Status:** TODO
- **Depends on:** F4, F5
- **Packaging:** adds-only ✅ for the commands; the package-limit key is a
  `hestia`-owned file, see note below
- **Scope:** A user may only manage apps on domains they own — enforce in the CLI
  with `is_object_valid`/`get_user_owner`, not in the panel. `NODE_APPS` limit in
  the package format. Confirm behaviour under Hestia's cgroup enforcement
  (`v-update-user-cgroup`) so one runaway Next.js build cannot take the VPS down.
- **Files:** the `v-*-node-app` commands. `install/common/packages/*.pkg` is
  **hestia-owned**; a per-user limit stored in our own registry avoids touching it.
- **Acceptance:** user A cannot start, stop, or read the logs of user B's app.

### F14 · Keeping the add-on add-only
- **Status:** TODO
- **Depends on:** F0
- **Packaging:** adds-only ✅
- **Scope:** `research.txt` called an unmergeable fork the biggest engineering
  risk in the project. The add-on packaging removes most of it: there is no
  fork, so there is nothing to merge on an upstream release. What remains is
  keeping it that way.
- **What to maintain:** a short list of anything that needs `dpkg-divert`,
  currently empty and ideally staying that way. Every entry is a file that must
  be re-checked on each Hestia release. F10 and F11 are the two candidates.
- **Also:** a periodic job that installs the current upstream Hestia in the test
  box, layers the add-on, and runs the suite — so a breaking upstream change is
  found by us rather than by a customer.
- **Acceptance:** a real upstream Hestia release installs on a box running the
  add-on with no manual step and no test failures.

---

## Migration milestones

These are the actual point of Phase 1.

- **M1** — throwaway Next.js app on the test Hestia, served over HTTPS. Gate: F1–F8.
- **M2** — one real I-Varse site migrated off Cloudflare Workers, monitored. Gate: M1, F9, F12.
- **M3** — Ofada Girl site migrated. Gate: M2 stable.
- **M4** — remaining frontends; Workers decommissioned. Gate: M3.

Payload CMS stays in its Docker container throughout. Nothing in Phase 1 touches it.

---

## Deferred — do not start

Listed so they are visibly parked, not forgotten. Each is explicitly excluded
from Phase 1 by `research.txt`.

| Item | Notes |
|---|---|
| Git / GitHub / GitLab deployment, webhooks | Phase 1 is local files only. Deliberate. |
| Python runtime (Flask/FastAPI) | Phase 2. Must reuse F2–F9 unchanged — that is the test of whether the abstraction was right. |
| Docker / Compose / GHCR management | Phase 3. |
| Cloudflare Workers + multi-account credentials | Phase 4. The thing being migrated *away* from. |
| OpenStack | No OpenStack exists yet. Not a current dependency. |
| OpsCloud / Frappe / ERPNext integration | Stays a separate system. |
| Multi-server orchestration, central dashboard, billing, Kubernetes | Not in scope. |

---

## Decisions made

| | Decision | Why |
|---|---|---|
| **Fork or add-on** | **Add-on.** A separate `hestia-ivarse` package that adds files and replaces none | Forking made every upstream release a manual merge-and-rebuild and pinned Hestia away from its own security updates. Measured: upstream's package over the fork took the Node commands 4 → 0 |
| **Node install mechanism** | Official nodejs.org tarballs into `/opt/ivarse/node/<major>` | NodeSource apt holds only one Node major at a time, which defeats per-app pinning |
| **Release trust** | Verify the GPG signature on `SHASUMS256.txt`, not just the checksum | A self-consistent hostile mirror passed a checksum-only check and installed its payload as `node` |
| **Test box** | Disposable Docker container running **stock** Hestia | A Hestia install rewrites `/etc` heavily; stock Hestia inside is what makes the upgrade test real |
| **Target web stack** | nginx only | Answered directly; decides where the F6 templates live |

## Open decisions

Blocking questions, to resolve before the dependent item starts.

1. **App root layout** (blocks F4). `/home/<user>/web/<domain>/app/` alongside
   `public_html`, versus registering an arbitrary directory. `research.txt`
   leaves this open and flags it as needing care. **This is the next decision
   needed.**
2. **One app per domain, or many?** (affects F6, F10). Phase 1 needs one. The
   registry is app-keyed either way, so this only changes the nginx include and
   the UI.
3. **How F10 and F11 modify Hestia's own behaviour** — the only two items that
   cannot be adds-only. `dpkg-divert` plus a dpkg trigger, a systemd path unit
   watching `web.conf`, or contributing hook points upstream. Not needed until
   F10; decide before starting it.
