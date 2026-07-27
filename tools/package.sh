#!/usr/bin/env bash
#
# Build a release zip that can be dropped straight into Interface/AddOns.
#
# The zip contains a single top-level KillThemAll/ folder, which is what both a
# manual install and every addon manager expect. Development files -- the test
# suite, this script, CI config -- are left out.
#
# Unlike a fresh addon, the payload lives at the repository root rather than in
# a subfolder, so the staging step works by exclusion. That layout is deliberate:
# this is a fork, and keeping paths identical to upstream is what makes pulling
# future upstream changes a plain merge.
#
# Usage:  tools/package.sh [output-dir]     (default: dist/)

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
ADDON="KillThemAll"
TOC="$ADDON.toc"
OUT_DIR="${1:-dist}"

# Everything at the root that is tooling rather than addon payload.
EXCLUDES=(.git .github Tests tools dist .gitignore)

if [[ ! -f "$TOC" ]]; then
	echo "error: $TOC not found; run this from the repository." >&2
	exit 1
fi

VERSION="$(sed -n 's/^## Version:[[:space:]]*//p' "$TOC" | tr -d '\r')"
INTERFACE="$(sed -n 's/^## Interface:[[:space:]]*//p' "$TOC" | tr -d '\r')"
if [[ -z "$VERSION" ]]; then
	echo "error: no '## Version:' line in $TOC." >&2
	exit 1
fi

echo "$ADDON $VERSION  (Interface $INTERFACE)"

# --- Validate before packaging -------------------------------------------------
#
# A Lua file present on disk but missing from the TOC is never loaded by the
# game, even though the test harness would load it happily. That mismatch would
# ship a silently broken addon, so it is a hard failure here.

toc_list="$(mktemp)"
disk_list="$(mktemp)"
cleanup() { rm -f "$toc_list" "$disk_list"; [[ -n "${STAGE:-}" ]] && rm -rf "$STAGE"; }
trap cleanup EXIT

# The TOC lists .xml files too; those pull in Lua of their own, so expand them.
expand_toc() {
	while IFS= read -r line; do
		line="${line%$'\r'}"
		[[ -z "$line" || "$line" == \#* ]] && continue
		local path="${line//\\//}"
		case "$path" in
			*.lua) echo "$path" ;;
			*.xml)
				local dir="${path%/*}"
				grep -o 'file="[^"]*"' "$path" | sed 's/file="//;s/"$//' | tr '\\' '/' \
					| while IFS= read -r script; do echo "$dir/$script"; done
				;;
		esac
	done < "$TOC"
}

expand_toc | sort > "$toc_list"

find_args=()
for item in "${EXCLUDES[@]}"; do
	find_args+=(-path "./$item" -prune -o)
done
find . "${find_args[@]}" -name '*.lua' -print | sed 's|^\./||' | sort > "$disk_list"

if ! diff -q "$toc_list" "$disk_list" >/dev/null; then
	echo "error: the TOC and the files on disk disagree." >&2
	echo "  '<' is in the TOC only, '>' is on disk only:" >&2
	diff "$toc_list" "$disk_list" >&2 || true
	exit 1
fi
echo "  $(wc -l < "$toc_list" | tr -d ' ') Lua files, TOC matches disk"

# Every listed file must also parse. WoW runs Lua 5.1, so prefer that compiler.
if command -v luac5.1 >/dev/null 2>&1; then LUAC=luac5.1
elif command -v luac >/dev/null 2>&1; then LUAC=luac
else LUAC=""; fi

if [[ -n "$LUAC" ]]; then
	while IFS= read -r file; do
		if ! "$LUAC" -p "$file" 2>/dev/null; then
			echo "error: $file does not parse." >&2
			exit 1
		fi
	done < "$toc_list"
	echo "  all files parse"
else
	echo "  warning: no luac found, skipping the syntax check" >&2
fi

# --- Build ---------------------------------------------------------------------

STAGE="$(mktemp -d)"
mkdir -p "$STAGE/$ADDON"

tar_excludes=()
for item in "${EXCLUDES[@]}"; do
	tar_excludes+=(--exclude="./$item")
done
tar "${tar_excludes[@]}" --exclude='*.DS_Store' -cf - . | tar -C "$STAGE/$ADDON" -xf -

mkdir -p "$OUT_DIR"
ZIP="$ROOT/$OUT_DIR/$ADDON-$VERSION.zip"
rm -f "$ZIP"
(cd "$STAGE" && zip -qr9 "$ZIP" "$ADDON" -x '*.DS_Store' -x '__MACOSX*')

# The folder inside the zip must match the TOC name or the game will not load it.
#
# Tested with a bash string match rather than `unzip -l | grep -q`: grep -q
# exits on the first match, which kills unzip with SIGPIPE, and under
# `set -o pipefail` that turns a healthy zip into an intermittent failure.
listing="$(unzip -l "$ZIP")"
if [[ "$listing" != *" $ADDON/$TOC"* ]]; then
	echo "error: $ADDON/$TOC is missing from the zip." >&2
	exit 1
fi

file_count="$(printf '%s\n' "$listing" | tail -1 | awk '{print $2}')"
echo "  wrote $OUT_DIR/$ADDON-$VERSION.zip ($(du -h "$ZIP" | cut -f1 | tr -d ' '), $file_count files)"
echo
echo "Install: unzip into World of Warcraft/_retail_/Interface/AddOns/"
