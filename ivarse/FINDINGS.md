# Security and correctness findings

Every hole found so far, with its status. Verified against the code in `main`,
not from memory. **Update this in the same change that fixes or introduces
something** — the point is that nobody has to ask.

Status is one of:

- **FIXED** — closed, with a test, merged into `main`
- **OPEN** — a real problem, not yet closed
- **DEFERRED** — real, deliberately not closed yet, with the item that owns it
- **ACCEPTED** — understood and not being closed, with the reason

---

## FIXED

| # | Finding | Impact | Closed by |
|---|---|---|---|
| 1 | Checksum-only trust of nodejs.org releases. A mirror serving a tarball, a matching `SHASUMS256.txt` and a valid signature over it passed. | **Critical.** A hostile mirror's payload installed as `node` and made the default runtime. Demonstrated. | `dfc6527` — signature verified against bundled Node release keys via `gpgv` |
| 2 | `APP_ROOT` symlink not resolved. `ln -s /etc <app root>` passed validation. | **Critical, root escalation.** A root `chown -R` then handed `/etc` to an unprivileged user. Demonstrated. | `71a58d6` — `realpath -m`, resolved path must be inside the home |
| 3 | `APP_ROOT` accepted a newline. | **Critical, root escalation.** It becomes `WorkingDirectory=` in a unit; an appended `User=root` wins because systemd honours the last one. | `de44adb` — restricted to `[A-Za-z0-9/._-]` |
| 4 | TOCTOU between validating `APP_ROOT` and using it. User owns the parent and can swap the final component for a symlink. | **Critical, root escalation.** Every `chown` variant follows it — `-h`, `-P`, `--no-dereference` all measured to escalate. | `7e38458` — `app_root_create` drops privileges via Hestia's `v-add-fs-directory` |
| 5 | `app_root_create` created before validating, and trusted its caller to have validated the path format. | High. A rejected call left a stray directory; a malformed path was refused only by luck. | `47d7564` — validates its own contract first |
| 6 | `HOMEDIR` / `BIN` read without checking they are set. | High. Home computed as `/$user`, so every containment check answers the wrong question. | `47d7564` — `app_env_required` refuses to run |
| 7 | `APP_ROOT` accepted shell metacharacters, quotes and spaces. | High. The value reaches shell commands (F7) and nginx config (F6). | `de44adb` — same charset restriction |
| 8 | Application name used as a `grep` pattern without validation. `.*` matched every record. | Medium. Merged unrelated records into one malformed object and **exited 0**. Would have become path and unit-name derivation in F4/F5. | `2d3a9be` — name validated first, `grep -m 1` |
| 9 | `mv` nested the runtime inside a pre-existing directory. | Medium. **Exit 0** with nothing runnable at the expected path, so `v-list-sys-nodejs` showed no runtime right after reporting success. | `4b7c6f5` — path refused if present, plus `mv -T` |
| 10 | Fork shipped the `hestia` package under upstream's version. | **Critical availability.** The nightly `v-update-sys-hestia-all` at 04:41 would have replaced the whole I-Varse install unattended. | `945d9cd` — add-on packaging; the fork was abandoned entirely |
| 11 | `testbox.sh verify` matched paths with a regex requiring a dot, checking 2 of 6 files. | Medium. Skipped every `bin/` command — the files most likely to collide — while reporting success. | `0d3c503` — selects real files with `-f` |
| 12 | Staging in `/tmp` made the install move cross-filesystem. | Medium. Not atomic, so a failure could leave a partial runtime at the final path; also buffered ~230MB through tmpfs. | `fbf6307` — staged inside `NODE_ROOT` |
| 13 | `mktemp` result used unchecked. | Medium. On failure the download would have been written to `/`. | `4b7c6f5` |
| 14 | Resolved path compared against an **unresolved** home. | Medium availability. Rejected every legitimate app root where the home sits behind a symlink (`/home -> /srv/home`). | `de44adb` — both sides resolved |
| 15 | `xz-utils` undeclared. | Low. `Priority: standard`, so absent on a minimal image. | Declared in the add-on's `Depends` |
| 16 | `[ -f x ] && install` at top level under `set -e`. | Low. Works only because bash exempts the left side of `&&`; one edit from a silent early exit. | `0d3c503` |

---

## DEFERRED

| # | Finding | Owner | Why not now |
|---|---|---|---|
| D1 | `%` is permitted in commands but is a systemd specifier prefix. `ExecStart=npm start %n` expands, and an unknown specifier makes the unit fail to start. | **F5** | Harmless as an argument. Nothing generates a unit file yet, so there is nothing to escape. F5 must write `%` as `%%` and carries this as an acceptance requirement with a test. **Not a security issue** — it breaks the unit, it does not cross a privilege boundary. |

---

## ACCEPTED

| # | Finding | Reason |
|---|---|---|
| A1 | Residual TOCTOU: a symlink can still be swapped after `app_root_assert_safe` returns. | Not closable in shell. Mitigated structurally: `assert_safe` **echoes the resolved path** so callers work with a concrete path rather than one traversing an attacker-controlled symlink, and the rule is that no root operation is performed on it. F4/F5/F7 are bound to `app_root_create` / `app_root_assert_safe` rather than to a rule someone has to remember. |
| A2 | The bundled Node release keyring is a point-in-time snapshot. | A release signed by a newly added Node team member fails until the keyring is refreshed. The error names the cause and `NODE_RELEASE_KEYRING` overrides it without waiting for a package update. Failing closed is the correct behaviour. |
| A3 | An explicit `apt-get install --allow-downgrades hestia=<version>` can still install a stock Hestia over an add-on box. | Only relevant to the abandoned fork model. Under add-on packaging the add-on survives that anyway, which is the whole point. |

---

## Open

None.
