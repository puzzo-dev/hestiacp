# I-Varse Hestia — Functionality Tracker

Single source of truth for what is built, in progress, and deferred.
Read `.claude/skills/ivarse-hestia/SKILL.md` before touching any item.

Base: `hestiacp/hestiacp` v1.10.4 @ `4771643`. Fork currently has **zero
divergence** from upstream — clean slate.

**Status values:** `TODO` · `IN PROGRESS` · `DONE` · `BLOCKED` · `DEFERRED`

**Phase 1 goal (the only goal right now):** get `ivarseltd.com` and the Ofada
Girl site off Cloudflare Workers and back onto the Namecheap VPS, served as
Node apps managed by Hestia, still talking to the containerised multi-tenant
Payload CMS.

---

## Ordering rationale

Urgency is taken from `research.txt`: Phase 1 is *only* Node hosting, and within
it the objective is a working runtime before any UI polish or Git deployment.
F1–F8 are the critical path to a live HTTPS Next.js site. F9–F10 make it usable
without SSH. F11–F13 stop it corrupting the rest of Hestia. F14 is what keeps
the fork alive past six months.

Do not start F10 (UI) before F1–F8 are `DONE`. The CLI is the product; the panel
is a client of it.

---

## Phase 1 — Node hosting v1

### F0 · Fork + build pipeline + test box
- **Status:** DONE (in the F1 PR)
- **Depends on:** —
- **Tier:** 0
- **Why first:** Nothing else can be verified until a deb can be built from this
  tree and installed on a throwaway Hestia. `research.txt` is explicit that we do
  not modify a production `/usr/local/hestia`.
- **Decided:** the test box is a Docker container, not a second WSL distro or a
  VM. Upstream already ships `.github/docker/hestia-ci.Dockerfile` (Ubuntu 26.04,
  `CMD ["/sbin/init"]`) and drives it from
  `.github/workflows/pr-docker-bats.yml`, so this reuses the mechanism upstream
  maintains. A Hestia install rewrites `/etc` heavily; a disposable container is
  the right blast radius, and it resets in one command.
- **Files:** `ivarse/testbox.sh` (new)
- **Acceptance:** a deb builds from this tree, installs on a throwaway Hestia,
  and the panel still works. ✅ verified — Hestia 1.10.4+ivarse1 built and
  installed, `systemctl is-system-running` reports `running`.
- **`testbox.sh up | install | verify | test | shell | logs | down | reset`.**
  The repo mounts at `/hestiacp-git`, so edits are visible inside immediately.
- **GitHub Actions is not available:** all four workflows are enabled and
  trigger correctly, but every job fails in ~3s with *"the job was not started
  because your account is locked due to a billing issue"*. Until that is
  resolved on the account, the local box is the only test path.

### F0b · Packaging identity — stop upstream replacing the fork
- **Status:** DONE (in the F1 PR)
- **Depends on:** F0
- **Tier:** 1 (one line in `src/deb/hestia/control`), rest Tier 0
- **Found by:** the first test-box install. Hestia installed and reported
  success, but **none of the F1 files were present.** `apt-cache policy` showed
  the running package had come from `apt.hestiacp.com`, not from the deb built
  out of this tree.
- **Root cause:** the fork's deb carried the *identical* version string to
  upstream's (`1.10.4-1+ubuntu26.04`), so apt treated the two as
  interchangeable. The stock installer also adds a nightly cron entry —
  `41 4 * * * v-update-sys-hestia-all` — which runs `apt-get install hestia`
  against `apt.hestiacp.com`. On a production box that would replace the entire
  I-Varse installation at 04:41, unattended, removing every command, template
  and helper this fork adds. The installer hides `dpkg` output, so it would have
  looked like a clean install.
- **Fix:** the fork builds as `1.10.4+ivarse1`, which outranks upstream's
  same-numbered release and makes `apt-cache policy` tell the truth. Because a
  future upstream `1.10.5` would still outrank it, `v-add-sys-ivarse-apt-pin`
  installs an apt preference pinning the upstream package to priority `-1`.
  Upstream changes are taken deliberately, by merging and rebuilding.
- **Files:** `src/deb/hestia/control`, `install/common/apt/ivarse-hestia.pref`
  (new), `bin/v-add-sys-ivarse-apt-pin` (new), `ivarse/testbox.sh`
- **Acceptance:** running `v-update-sys-hestia-all` leaves the I-Varse
  installation intact. ✅ verified — upstream sits at priority `-1`, the cron
  command exits 0, and all four Node commands survive.
- **Still to decide:** how the pin gets installed on a production box without
  someone remembering to run it. Hestia's `/etc/hestiacp/hooks/post_install.sh`
  is the documented hook and is the likely answer. Tracked in F14.

### F1 · Node runtime install + version management
- **Status:** IN REVIEW — PR on `feat/f1-node-runtime`
- **Depends on:** F0
- **Tier:** 0, plus one Tier 1 line in `func/main.sh`
- **Decided:** official nodejs.org tarballs unpacked into `/opt/ivarse/node/<major>`,
  root-owned, one directory per major. Chosen over NodeSource apt because apt can
  hold only one Node major at a time, which would make per-app version pinning
  impossible. Corepack is enabled per runtime so pnpm and yarn work without a
  global install.
- **Scope:** install, remove, list and default-selection for host Node runtimes.
  Downloads are checksum-verified against the `SHASUMS256.txt` published with the
  release, and unpacked in a staging directory so a failed install cannot leave a
  half-written runtime behind.
- **Files:** `func/node.sh` (new), `bin/v-add-sys-nodejs`,
  `bin/v-delete-sys-nodejs`, `bin/v-list-sys-nodejs`,
  `bin/v-change-sys-nodejs-default`, `test/nodejs.bats`,
  `func/main.sh` (Tier 1: one `is_format_valid` case, marked `# IVARSE:`)
- **Acceptance:** `v-list-sys-nodejs json` reports each installed major and its
  absolute binary path; two majors coexist. ✅ verified — 22.23.2 and 24.20.0
  installed side by side, both `node -v` correct, npm 10.9.8 present.
- **Also verified:** duplicate install refused; tampered-mirror tarball rejected
  on checksum with nothing installed and no staging left behind; a runtime an
  application is pinned to cannot be deleted; deleting the default repoints it to
  the highest remaining major; installing a second runtime does not steal the
  default.
- **Verified on a real installation:** ✅ all 21 bats cases pass as root on
  Hestia 1.10.4+ivarse1 (Ubuntu 26.04, systemd PID 1), leaving no residue under
  `/opt/ivarse/node`. This covers the root-only `chown`/`chmod` paths that the
  unprivileged sandbox could not exercise.

### F2 · Application registry + data model
- **Status:** TODO
- **Depends on:** F0
- **Tier:** 0
- **Scope:** The runtime-agnostic `Application` object. `$USER_DATA/node.conf`
  in Hestia `KEY='value'` line format, read through `parse_object_kv_list`.
  Fields: `NAME DOMAIN RUNTIME RUNTIME_VERSION APP_ROOT PORT PACKAGE_MANAGER
  BUILD_COMMAND START_COMMAND SERVICE_NAME STATUS SUSPENDED TIME DATE`.
  `func/node.sh` holds shared helpers. `TPL='nodejs'` on the web domain is the
  marker that a domain is Node-backed — **no change to the `web.conf` record
  format**, which keeps `v-add-web-domain` and `v-list-web-domain` at Tier 0.
- **Files:** `func/node.sh`, `bin/v-list-node-app`, `bin/v-list-node-apps`
- **Acceptance:** a hand-written `node.conf` round-trips through
  `v-list-node-apps` in all four formats (shell/json/plain/csv).
- **Note:** name the file/fields for the general case where it costs nothing.
  `RUNTIME` exists from day one even though it is always `node` in Phase 1.

### F3 · Port allocator
- **Status:** TODO
- **Depends on:** F2
- **Tier:** 0
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
- **Tier:** 0
- **Scope:** `v-add-node-app` (validate, allocate port, create `APP_ROOT`, write
  registry, generate unit + nginx include, do **not** auto-start),
  `v-delete-node-app` (stop, disable, remove unit, remove includes, free port,
  remove record), `v-change-node-app-*` for each mutable field.
  New `is_format_valid` cases for `app_name`, `runtime`, `runtime_version`,
  `app_port`, `package_manager`, `start_command`, `build_command` — the command
  fields need careful validation, they end up in a systemd `ExecStart`.
- **Files:** `bin/v-add-node-app`, `bin/v-delete-node-app`,
  `bin/v-change-node-app-*`, `func/main.sh` (Tier 1: `is_format_valid` cases)
- **Acceptance:** add → list → change → delete leaves no unit file, no nginx
  include, no registry line, and no leaked port.
- **Security:** start/build commands are attacker-controlled input from panel
  users that become root-generated systemd config. Validate against an allowlist
  shape; never interpolate raw into a shell string.

### F5 · systemd unit generation + lifecycle
- **Status:** TODO
- **Depends on:** F1, F4
- **Tier:** 0
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
- **Reference:** `src/deb/web-terminal/hestia-web-terminal.service` — same shape,
  already shipping.

### F6 · Nginx integration
- **Status:** TODO
- **Depends on:** F3
- **Tier:** 0
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
  upstream template variable has to be added (that would be Tier 3).
- **Watch:** template selection differs between nginx-only and nginx+Apache
  installs. Confirm which the target VPS runs before writing the stpl.

### F7 · Build pipeline
- **Status:** TODO
- **Depends on:** F1, F4
- **Tier:** 0
- **Scope:** `v-build-node-app` runs install-then-build as the Hestia user via
  `runuser`, with a timeout, a concurrency guard, and full output captured to a
  build log. npm / pnpm / yarn / bun.
- **Files:** `bin/v-build-node-app`
- **Acceptance:** a Next.js app builds end to end; a failing build exits non-zero
  with the error visible in the build log and leaves the previous build serving.
- **Do not:** add `node`/`npm` to `v-run-cli-cmd`'s whitelist. That grants every
  panel user arbitrary `npm` execution. Fixed argv here instead.

### F8 · Environment variables
- **Status:** TODO
- **Depends on:** F4, F5
- **Tier:** 0
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
- **Tier:** 0
- **Scope:** `v-list-node-app-log` over `journalctl -u`, build log tail, running
  state, PID, CPU and RSS.
- **Files:** `bin/v-list-node-app-log`, `bin/v-list-node-app-status`
- **Acceptance:** logs readable from the CLI for a running and a crashed app.

### F10 · Panel UI
- **Status:** TODO
- **Depends on:** F4–F9
- **Tier:** 0 for new pages, 1 for the nav entry
- **Scope:** List / add / edit pages matching the `research.txt` mockup (domain,
  app root, node version, package manager, build command, start command, port,
  env vars, create). Start/stop/restart controls, log viewer. All through
  `HESTIA_CMD` — the panel calls `v-*` and nothing else.
- **Files:** `web/list/node/`, `web/add/node/`, `web/edit/node/`,
  `web/templates/pages/{list,add,edit}_node.php`,
  `web/templates/includes/panel.php` (Tier 1, one nav item)
- **Acceptance:** an app can be created, built, started and inspected without SSH.

### F11 · Web domain lifecycle hooks
- **Status:** TODO
- **Depends on:** F4
- **Tier:** 2 — **mitigation mandatory**
- **Scope:** Deleting or suspending a web domain must not orphan a systemd unit
  or leak a port. Add exactly one hook line to each upstream command and put all
  logic in `func/ivarse-hooks.sh`.
- **Files:** `func/ivarse-hooks.sh` (new, Tier 0),
  `bin/v-delete-web-domain`, `bin/v-suspend-web-domain`,
  `bin/v-unsuspend-web-domain`, `func/rebuild.sh` — one `# IVARSE:` line each
- **Acceptance:** deleting a Node-backed domain removes the unit and frees the
  port; suspending stops the app; unsuspending restarts it.
- **Risk:** this is the item most likely to conflict on an upstream merge. Keep
  the diffs to one line each, no exceptions.

### F12 · Backup and restore
- **Status:** TODO
- **Depends on:** F2, F8
- **Tier:** 2 — **mitigation mandatory**
- **Scope:** `v-backup-user` walks `web.conf` per domain and knows nothing about
  a separate registry, so app records, env files and the app root are **silently
  absent from backups** until hooked. Same on restore.
- **Files:** `bin/v-backup-user`, `bin/v-restore-user` — one hook line each;
  logic in `func/ivarse-hooks.sh`
- **Acceptance:** back up a user with a running Node app, restore onto a clean
  box, app starts and serves.
- **Note:** this gap is not in `research.txt` and is easy to discover only after
  losing data. Do not defer it past the first real site migration.

### F13 · Permissions, isolation, limits
- **Status:** TODO
- **Depends on:** F4, F5
- **Tier:** 0, plus Tier 1 for the package key
- **Scope:** A user may only manage apps on domains they own — enforce in the CLI
  with `is_object_valid`/`get_user_owner`, not in the panel. `NODE_APPS` limit in
  the package format. Confirm behaviour under Hestia's cgroup enforcement
  (`v-update-user-cgroup`) so one runaway Next.js build cannot take the VPS down.
- **Files:** `install/common/packages/*.pkg` (Tier 1), the `v-*-node-app` commands
- **Acceptance:** user A cannot start, stop, or read the logs of user B's app.

### F14 · Upstream merge maintenance
- **Status:** TODO
- **Depends on:** F11, F12
- **Tier:** —
- **Scope:** `research.txt` calls this the biggest engineering risk in the
  project. Write down the procedure: `git fetch upstream`, review the diff
  against the `# IVARSE:` grep list, merge, rebuild the deb, run the test suite,
  reinstall on the test box. Keep a living inventory of every Tier 1+ touch point.
- **Files:** `ivarse/UPSTREAM.md` (new), `ivarse/TOUCHPOINTS.md` (new)
- **Acceptance:** a real upstream release merges with conflicts only in files
  listed in `TOUCHPOINTS.md`.

### F1a · Verify the nodejs.org release signature
- **Status:** IN REVIEW — folded into the F1 PR
- **Depends on:** F1
- **Tier:** 0
- **Scope:** Checksum-alone was not enough. `SHASUMS256.txt` is now verified
  against the Node.js release keys before any checksum from it is trusted.
  The keys are bundled at `install/common/nodejs/release-keys.asc`, and
  `gpgv` reads that fixed keyring so verification cannot be influenced by, or
  write to, any keyring on the host. `NODE_RELEASE_KEYRING` is overridable so an
  administrator can supply a refreshed keyring when Node adds a release signer
  without waiting for a package update.
- **Files:** `install/common/nodejs/release-keys.asc` (new), `func/node.sh`,
  `bin/v-add-sys-nodejs`, `test/nodejs.bats`, `src/deb/hestia/control` (gpgv)
- **Acceptance:** a release whose `SHASUMS256.txt` carries an invalid, absent or
  untrusted signature is refused. ✅ verified, including the case that matters:
  a mirror serving a correct checksum and a *valid* signature made by a
  non-Node key is rejected. The pre-fix code installed that mirror's payload as
  `node` and made it the default runtime. Re-verified on the real installation as
  part of the 21-case bats run.
- **Known limitation:** the bundled keyring is a point-in-time snapshot of
  Node's release team. A release signed by a newly added member will fail until
  the keyring is refreshed. The error names the cause, and the override exists
  for exactly this.

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

## Open decisions

Blocking questions, to resolve before the dependent item starts.

1. ~~**Multi-version Node mechanism**~~ — **resolved**: official tarballs into
   `/opt/ivarse/node/<major>`. See F1.
2. **App root layout** (blocks F4). `/home/user/web/<domain>/app/` alongside
   `public_html`, versus registering an arbitrary directory.
   `research.txt` leaves this open and flags it as needing care.
3. ~~**Target VPS web stack**~~ — **resolved**: nginx only. Node templates are
   WEB templates in `install/deb/templates/web/nginx/php-fpm/`, no Apache bypass
   needed.
4. **One app per domain, or many?** Phase 1 needs one. The registry is app-keyed
   either way, so this only affects the nginx include and the UI.
