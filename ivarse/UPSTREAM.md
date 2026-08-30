# Taking upstream Hestia updates

**Nothing to do.** Hestia updates itself through its own normal channels — the
nightly `v-update-sys-hestia-all` cron job, or `apt` by hand — and the I-Varse
add-on is untouched.

There is no merge step, no rebuild, and no procedure to follow on a release.

## Why this works

The I-Varse work ships as its own package, `hestia-ivarse`, which **adds** files
under `/usr/local/hestia/` and replaces none of Hestia's:

```
$ dpkg -S /usr/local/hestia/bin/v-add-sys-nodejs
hestia-ivarse: /usr/local/hestia/bin/v-add-sys-nodejs

$ dpkg -S /usr/local/hestia/func/main.sh
hestia: /usr/local/hestia/func/main.sh
```

When dpkg upgrades a package it removes the files *that package's* previous
version owned and the new one does not ship. It has no reason to touch files
owned by a different package, so upgrading `hestia` leaves `hestia-ivarse`
alone.

Verified on the test box: with the add-on installed, an unattended
`v-update-sys-hestia-all` upgraded Hestia and left every I-Varse command,
`func/node.sh`, the release keyring, and the installed Node runtimes in place
and working — a new runtime installed cleanly *after* the upgrade.

## The rule that keeps it true

**The add-on must never ship a file the `hestia` package owns.**

Break that rule and two things happen: dpkg refuses the install outright if
Hestia is already installed, and if it did land, the next Hestia upgrade would
silently revert it.

Enforced in two places:

- `ivarse/build-package.sh` checks every path in `src/deb/ivarse/files.txt`
  against dpkg's file database at build time and refuses to build on a conflict.
- `ivarse/testbox.sh verify` checks every installed file is owned by
  `hestia-ivarse`.

Before adding a path to `files.txt`:

```sh
dpkg -S /usr/local/hestia/<path>
```

If that names `hestia`, the file cannot be shipped, and the feature needs a
different design.

## What this costs

Features that genuinely need to change Hestia's own behaviour — a nav item in
`web/templates/includes/panel.php`, a hook inside `bin/v-delete-web-domain` —
cannot be done by adding a file. Those need `dpkg-divert` or an upstream
contribution, and each one is a deliberate decision that reintroduces an upgrade
step for that file alone. Keep the list at zero for as long as possible.

## An earlier approach, and why it was dropped

The first attempt forked the `hestia` package itself: same package name, a
`+ivarse1` version suffix, and an apt pin to stop upstream replacing it.

It worked, but it made every upstream release a manual event — merge upstream's
source, resolve the `src/deb/hestia/control` version conflict that happened
every time, rebuild the deb, reinstall. It also meant pinning Hestia away from
its own updates, so security fixes only arrived when someone remembered to
merge.

Measured on the test box: installing upstream's `hestia` package over that fork
took the Node commands from four to zero.

The add-on model removes the pin, the version suffix, the conflict and the
procedure at the cost of one rule — add files, never replace them.
