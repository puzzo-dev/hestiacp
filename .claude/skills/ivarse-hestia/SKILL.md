---
name: ivarse-hestia
description: Use for ALL work on this I-Varse HestiaCP fork - adding runtimes (Node/Python/Docker/Cloudflare), v-* CLI commands, web templates, panel pages, or anything touching bin/, func/, install/deb/templates/, web/, src/deb/. Enforces the fixed architecture, the merge-risk tiers that keep the fork mergeable with upstream, and the track-before-you-build workflow.
---

# I-Varse Hestia

Fork of HestiaCP (`puzzo-dev/hestiacp`, base `hestiacp/hestiacp` v1.10.4) that adds
first-class application runtimes to Hestia. Node.js first, then Python, Docker,
Cloudflare Workers.

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
6. **Ship as a fork built into a deb**, never as edits to a live
   `/usr/local/hestia`. Build with `src/hst_autocompile.sh`.
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

## Merge-risk tiers

The stated top engineering risk is the fork becoming unmergeable. Every change
must be classified, and the tier must be stated in the roadmap entry.

- **Tier 0 — new files.** New `bin/v-*`, `func/node.sh`, new templates under
  `install/deb/templates/web/nginx/`, new panel pages, new `src/deb/` package.
  Zero conflict. **~95% of the work belongs here. Push work down into Tier 0.**
- **Tier 1 — one-to-three-line additions to a list.** A nav item in
  `web/templates/includes/panel.php`, a `case` in `is_format_valid`
  (`func/main.sh`), a key in `v-list-sys-config`. Acceptable.
- **Tier 2 — logic inserted into upstream control flow.** `v-delete-web-domain`,
  `v-suspend-web-domain`, `v-backup-user`, `v-restore-user`, `func/rebuild.sh`.
  **Required mitigation:** add exactly one hook line to the upstream file and put
  all logic in `func/ivarse-hooks.sh`. Five multi-line diffs become five
  one-line diffs.
- **Tier 3 — editing upstream logic in place.** Above all the sed variable list
  in `add_web_config()` (`func/domain.sh`). **Avoid.** Requires explicit user
  sign-off recorded in the roadmap entry.

Every Tier 1+ change gets a comment marker so it is greppable:
`# IVARSE: <one-line reason>`.

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
  `%var%` tokens. There is no `%node_port%` and adding one is Tier 3.
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
  template updates.
- `src/hst_autocompile.sh` ships `bin func install web` wholesale into
  `/usr/local/hestia/`. New files in those trees need no packaging changes.
- `src/deb/web-terminal/` is the working precedent for a Node service: unit file,
  deb, postinst that reloads systemd. **Copy that pattern rather than inventing one.**
- `bin/v-backup-user` captures a domain by `grep "DOMAIN='$domain'" web.conf` plus
  the domain conf dir. A separate registry file is **invisible to backup** unless
  explicitly hooked. Same for restore.
- `install/common/bubblewrap/jailbash` uses `--unshare-all --share-net`, so jailed
  shells do have network, but `--tmpfs /usr/local/hestia` hides the Hestia CLI
  from inside the jail.
- php-fpm's port scanner in `v-change-web-domain-backend-tpl` starts at 9000 and
  is php-fpm-specific. Node needs its own allocator over a separate range.

## Verification

There is no Hestia running on this machine. Bash-level work is verified by
`bash -n`, `shellcheck`, and unit-style tests under `test/`; anything touching
nginx, systemd, or a live panel is verified on the user's **test** Hestia
install, never on production. State plainly which of the two happened.

## Delivery workflow — no direct commits to main

Every functionality ships as its own reviewed PR. This is a hard rule.

1. One roadmap item = one branch = one PR. Branch name `feat/<item-id>-<slug>`,
   e.g. `feat/f1-node-runtime`. Never bundle two roadmap items in one PR.
2. Branch off `main`. Never commit to `main` directly.
3. Build the item, and **only** that item. Anything else discovered becomes a new
   roadmap entry, not extra commits on this branch.
4. Open the PR with `gh pr create`. The body states: roadmap item, merge-risk
   tier of every file touched, the acceptance test, and what was actually
   verified versus what still needs the test Hestia box.
5. **Review the PR before merging** — run `/code-review` against it and report
   findings. Do not merge on your own initiative; the user merges or tells you to.
6. Only after merge: mark the roadmap item `DONE` and move to the next.

Scope discipline is the point. Phase 1 is Node hosting and nothing else. If a
change is not on the critical path to serving `ivarseltd.com` from the VPS, it
does not belong in this PR — write it into `ivarse/ROADMAP.md` and move on.
