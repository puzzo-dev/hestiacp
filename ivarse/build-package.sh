#!/usr/bin/env bash
#
# Build the hestia-ivarse package.
#
# This is deliberately not part of src/hst_autocompile.sh. Keeping the build
# separate means the fork adds no files to the upstream source tree that
# upstream also maintains, so there is nothing to merge when Hestia releases.
#
#   ./ivarse/build-package.sh [OUTPUT_DIR]
#
# Every path in src/deb/ivarse/files.txt is checked against dpkg's file
# database when one is available: shipping a path the hestia package owns
# would make the add-on replace part of Hestia, which is the exact failure
# mode this packaging exists to avoid.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PKG_DIR="$REPO_ROOT/src/deb/ivarse"
OUT_DIR="${1:-$REPO_ROOT/build}"
HESTIA_PREFIX="usr/local/hestia"

die() {
	echo "error: $*" >&2
	exit 1
}

[ -f "$PKG_DIR/control" ] || die "missing $PKG_DIR/control"
[ -f "$PKG_DIR/files.txt" ] || die "missing $PKG_DIR/files.txt"

version="$(awk '/^Version:/ {print $2; exit}' "$PKG_DIR/control")"
[ -n "$version" ] || die "no Version in control"

staging="$(mktemp -d)"
trap 'rm -rf "$staging"' EXIT

mkdir -p "$staging/DEBIAN" "$staging/$HESTIA_PREFIX"
cp "$PKG_DIR/control" "$staging/DEBIAN/control"
for script in postinst prerm postrm preinst; do
	if [ -f "$PKG_DIR/$script" ]; then
		install -m 755 "$PKG_DIR/$script" "$staging/DEBIAN/$script"
	fi
done

shipped=0
conflicts=0

while read -r entry; do
	entry="${entry%%#*}"
	entry="$(echo "$entry" | xargs || true)"
	[ -n "$entry" ] || continue

	src="$REPO_ROOT/$entry"
	[ -e "$src" ] || die "listed in files.txt but not present: $entry"

	# Refuse to ship anything the hestia package already owns.
	if command -v dpkg > /dev/null 2>&1; then
		while IFS= read -r f; do
			rel="${f#$REPO_ROOT/}"
			owner="$(dpkg -S "/$HESTIA_PREFIX/$rel" 2> /dev/null | cut -d: -f1 || true)"
			if [ -n "$owner" ] && [ "$owner" != "hestia-ivarse" ]; then
				echo "  CONFLICT: $rel is owned by '$owner'" >&2
				conflicts=$((conflicts + 1))
			fi
		done < <(find "$src" -type f 2> /dev/null)
	fi

	mkdir -p "$staging/$HESTIA_PREFIX/$(dirname "$entry")"
	cp -a "$src" "$staging/$HESTIA_PREFIX/$(dirname "$entry")/"
	shipped=$((shipped + 1))
done < "$PKG_DIR/files.txt"

if [ "$conflicts" -gt 0 ]; then
	die "$conflicts path(s) are owned by another package; this package must only add files"
fi

find "$staging/$HESTIA_PREFIX" -type d -exec chmod 755 {} +
if [ -d "$staging/$HESTIA_PREFIX/bin" ]; then
	chmod 755 "$staging/$HESTIA_PREFIX/bin/"*
fi

mkdir -p "$OUT_DIR"
deb="$OUT_DIR/hestia-ivarse_${version}_all.deb"
dpkg-deb --build --root-owner-group "$staging" "$deb" > /dev/null

echo "built $deb"
echo "  entries shipped: $shipped"
echo "  files: $(dpkg-deb -c "$deb" | grep -c '^-' || true)"
