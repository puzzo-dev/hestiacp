---
name: ivarse-hestia
description: Use for ALL work on I-Varse Hestia - adding runtimes (Node/Python/Docker/Cloudflare), v-* CLI commands, web templates, panel pages, or anything touching bin/, func/, install/, web/, src/deb/. Enforces the fixed architecture, the adds-only packaging rule that keeps Hestia self-updating, and the track-before-you-build workflow.
---

# I-Varse Hestia

Adds first-class application runtimes to HestiaCP — Node.js first, then Python,
Docker, Cloudflare Workers.

The repo (`puzzo-dev/hestiacp`) tracks upstream `hestiacp/hestiacp` v1.10.4, but
**Hestia is not forked**. The work ships as a separate `hestia-ivarse` package,
so a box runs stock Hestia plus the add-on and Hestia updates itself normally.

## Fixed premises — do not redesign

These were settled in `research.txt`. Treat them as given. If you believe one is
wrong, say so in one paragraph and then implement it as specified anyway unless
the user changes it.

1. **Web Domain stays the Hestia primitive. Application is the new primitive
   attached to it.** Not the other way round.
2. **Application is runtime-agnostic from day one.** Node is the first
   implementation of a general model (`runtime = node | python | docker |
   cloudflare`). Never write `node` into a name or schema where `runtime` belongs.
3. **systemd is the process supervisor.** Not PM2, not a custom daemon.
   One unit per app: `ivarse-node-{user}-{app}.service`.
4. **Nginx reverse-proxies to `127.0.0.1:<port>`.** Node is not a fake PHP-FPM
   backend template.
5. **Everything goes through the CLI layer.** Panel PHP calls
   `sudo /usr/local/hestia/bin/v-*`. The panel never writes nginx config, never
   touches systemd, never shells out to `npm`.
6. **Ship as the `hestia-ivarse` add-on package**, never as edits to a live
   `/usr/local/hestia`. Build with `ivarse/build-package.sh`. Hestia itself is
   installed stock and is never modified.
7. **No OpenStack, no Frappe/OpsCloud, no multi-server, no billing.** Out of
   scope until the user says otherwise.

## Track before you build

`ivarse/ROADMAP.md` is the single source of truth for what is done, in progress,
and deferred.

- Before starting work: read the roadmap, confirm the item is next on the
  critical path, and set its status to `IN PROGRESS`.
- Do not start an item whose `Depends on` items are not `DONE`.
- Before writing code for an item, its roadmap entry must have a filled-in
  **Files** list and **Acceptance** test. If they are vague, sharpen them first
  and show the user.
- After finishing: set `DONE`, and record what actually shipped if it diverged
  from the plan.
- New work discovered mid-task becomes a new roadmap item. It does not get
  silently folded into the current one.

## The one rule: add files, never replace them

This is not a fork of HestiaCP. The work ships as a separate `hestia-ivarse`
package that adds files under `/usr/local/hestia/` and replaces none of
Hestia's. That is what lets Hestia update itself through its own channels with
no merge, no rebuild and no procedure.

**Never ship a path the `hestia` package owns.** Before adding anything to
`src/deb/ivarse/files.txt`:

```sh
dpkg -S /usr/local/hestia/<path>
```

If that names `hestia`, the file cannot be shipped. Find another design.

It is enforced, not trusted: `ivarse/build-package.sh` refuses to build on a
conflict, and `ivarse/testbox.sh verify` re-checks every installed file. Do not
work around either — they are the reason upstream updates are free.

Practical consequences you will hit:

- Validators go in `func/node.sh` and are called directly. Adding a case to
  `is_format_valid` means shipping `func/main.sh`, which is Hestia's.
- Lifecycle hooks cannot be inserted into `v-delete-web-domain` and friends.
- A panel nav item cannot be added to `panel.php`.

The last two need `dpkg-divert` or an upstream contribution, and each one
reintroduces an upgrade step for that file alone. **That count is currently
zero. Keep it there.** If a feature seems to need it, say so and get a decision
rather than quietly patching an upstream file.

## Conventions

**CLI commands.** Copy the shape of an existing `bin/v-*` exactly: the
`# info:` / `# options:` / `# example:` header, the three
`Variables & Functions` / `Verifications` / `Action` / `Hestia` banner blocks,
`source /etc/hestiacp/hestia.conf`, `source $HESTIA/func/main.sh`,
`source_conf "$HESTIA/conf/hestia.conf"`, then `check_args`, `is_format_valid`,
`is_object_valid`, `check_hestia_demo_mode`. End with `$BIN/v-log-action` and
`log_event "$OK" "$ARGUMENTS"`.

**Naming.** `v-<verb>-node-app`. Verbs follow Hestia: `add`, `delete`, `change`,
`list`, `start`, `stop`, `restart`, `rebuild`, `suspend`, `unsuspend`.

**Records.** Hestia's `KEY='value'` single-line format, one object per line, read
via `parse_object_kv_list` / `get_object_value` / `update_object_value` from
`func/main.sh`. Never invent JSON or SQLite storage.

**Listing commands** implement all four formats: `shell`, `json`, `plain`, `csv`.

**Validation.** Add new argument types as `case` entries in `is_format_valid`
rather than validating inline in the command.

## Source facts established by reading the tree

Re-verify before relying on any of these; do not trust general Hestia knowledge.

- `install/common/sudo/hestiaweb` is `hestiaweb ALL=NOPASSWD:/usr/local/hestia/bin/*`.
  **Any new `bin/v-*` is automatically callable from the panel. No sudoers change.**
- `bin/v-run-cli-cmd` has a hard command whitelist (ps, ls, wget, tar, php, wp,
  composer...). **`node` and `npm` are not on it.** Do not widen that whitelist —
  it grants every panel user the new command. Write a purpose-built
  `v-build-node-app` that does its own `runuser -u "$user"` with a fixed argv.
- `add_web_config()` in `func/domain.sh` substitutes a **fixed sed list** of
  `%var%` tokens. There is no `%node_port%`, and `func/domain.sh` is Hestia's,
  so one cannot be added. Use the per-domain include instead.
- Every stock nginx template ends with
  `include %home%/%user%/conf/web/%domain%/nginx.conf_*;` (HTTP) and
  `nginx.ssl.conf_*` (HTTPS). **Two separate include points — always write both files.**
- `rebuild_web_domain_conf()` in `func/rebuild.sh` regenerates `nginx.conf` /
  `nginx.ssl.conf` and clears the `/etc/nginx/conf.d/domains/` symlinks, but
  **never deletes `nginx.conf_*`**. Per-app proxy config placed there survives
  `v-rebuild-web-domains`. This is why the port lives in our subsystem, not in a
  template variable.
- `no-php.tpl` already defines `location / { ... }`, so an included file cannot
  add its own `location /` — nginx rejects the duplicate. A Node domain therefore
  needs its own `nodejs.tpl` / `nodejs.stpl` that deliberately omits `location /`
  and lets the include supply it.
- `prepare_web_domain_values()` always calls `prepare_web_backend` when
  `WEB_BACKEND` is set, and that hard-fails if no php-fpm pool exists. Node
  domains still need a valid `BACKEND` — use the shipped `no-php` template.
- `bin/v-update-web-templates` uses `cp -rf`, which copies over and never deletes.
  Custom templates in `$HESTIA/data/templates/web/nginx/` survive upstream
  template updates. Note those live under `data/`, which the package does not
  own, so they are placed at runtime rather than shipped.
- `src/hst_autocompile.sh` builds **Hestia's** deb and is not used here.
  `ivarse/build-package.sh` builds `hestia-ivarse` from
  `src/deb/ivarse/files.txt`, so nothing is added to a file upstream maintains.
- `src/deb/web-terminal/` is the working precedent for a Node service: unit file,
  deb, postinst that reloads systemd. **Copy that pattern rather than inventing one.**
- `bin/v-backup-user` captures a domain by `grep "DOMAIN='$domain'" web.conf` plus
  the domain conf dir. A separate registry file is **invisible to backup**, and
  `v-backup-user` is Hestia's so it cannot be patched — ship a separate
  `v-backup-node-apps` instead.
- `install/common/bubblewrap/jailbash` uses `--unshare-all --share-net`, so jailed
  shells do have network, but `--tmpfs /usr/local/hestia` hides the Hestia CLI
  from inside the jail.
- php-fpm's port scanner in `v-change-web-domain-backend-tpl` starts at 9000 and
  is php-fpm-specific. Node needs its own allocator over a separate range.

## Tag every finding

`ivarse/FINDINGS.md` is the register of every security or correctness hole
found, each tagged **FIXED**, **OPEN**, **DEFERRED** or **ACCEPTED**, with the
commit that closed it.

Whenever a review turns something up, add it there in the same change, and say
plainly in the report whether it is fixed or not. Never describe a problem
without stating its status — "noted", "worth knowing" and "a limitation" are not
statuses. If it is deferred, name the item that owns it and why waiting is
acceptable.

## Two standing hazards

Both were found by review and both bite again in F4, F5 and F7.

**Paths that root touches must be resolved first.** `APP_ROOT` is supplied by a
panel user and then created and chowned by commands running as root. A symlink
turns that into a privilege escalation — `ln -s /etc <app root>` followed by a
root `chown -R $user` hands `/etc` to that user, demonstrated on the test box.
`is_app_root_format_valid` resolves with `realpath -m` and requires the resolved
path to stay inside the owning user's home. **Use `app_root_resolve` for every
`mkdir`, `chown` and path written into config**, and prefer creating directories
as the user rather than as root. Validating the resolved path and then using the
raw one reintroduces the hole exactly.

**`%` is a systemd specifier.** Commands may contain `%` because it is harmless
as an argument, but a unit containing `ExecStart=npm start %n` expands it, and an
unknown specifier makes the unit fail to start. Whoever writes a unit file
escapes `%` as `%%`.

## Never run destructive root commands on the test box

Demonstrating a privilege-escalation bug by actually escalating on the shared
test box leaves it broken. `chown -R root:root /etc` does not undo
`chown -R someuser /etc` — group ownerships such as `/etc/bind` are lost, bind9
stops starting, and `v-delete-user` then fails, which fails half the suite for
reasons unrelated to the code under test. That has cost two full rebuilds.

Prove such a bug in a throwaway container, or prove it by showing the check
refuses the input. Never by performing the destructive operation on the box the
suite runs on.

## Verification

`ivarse/testbox.sh` runs a disposable **stock** Hestia in Docker:

```
./ivarse/testbox.sh up | hestia | install | verify | test | upgrade | down
```

`up` and `hestia` are slow and run once per box; `install` and `test` are the
fast inner loop. `upgrade` upgrades Hestia underneath the add-on and re-runs the
suite — run it before claiming anything about upgrade safety.

Anything touching systemd, nginx, file ownership or root-only behaviour must be
verified there, not reasoned about. State plainly what ran on the box and what
did not, and never describe something as verified when a different mechanism
happened to produce the same result.

## Delivery workflow — no direct commits to main

Every functionality ships as its own reviewed PR. This is a hard rule.

1. One roadmap item = one branch = one PR. Branch name `feat/<item-id>-<slug>`,
   e.g. `feat/f1-node-runtime`. Never bundle two roadmap items in one PR.
2. Branch off `main`. Never commit to `main` directly.
3. Build the item, and **only** that item. Anything else discovered becomes a new
   roadmap entry, not extra commits on this branch.
4. Open the PR with `gh pr create --repo puzzo-dev/hestiacp` — without
   `--repo` it targets upstream hestiacp/hestiacp. The body states: roadmap
   item, confirmation that every file is adds-only, the acceptance test, and
   what was actually verified on the test box versus what was not.
5. **Review the PR before merging** — run `/code-review` against it and report
   findings. Do not merge on your own initiative; the user merges or tells you to.
6. Only after merge: mark the roadmap item `DONE` and move to the next.

Scope discipline is the point. Phase 1 is Node hosting and nothing else. If a
change is not on the critical path to serving `ivarseltd.com` from the VPS, it
does not belong in this PR — write it into `ivarse/ROADMAP.md` and move on.
