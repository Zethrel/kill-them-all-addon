#!/usr/bin/env bash
#
# Upload a built zip to CurseForge.
#
# Needs:
#   CF_API_KEY      from CurseForge account settings -> API Tokens
#   CF_PROJECT_ID   the numeric Project ID shown on the project page
#
# Usage: tools/curseforge-upload.sh dist/KillThemAll-1.7.0.zip
#
# The only fiddly part is that CurseForge wants its own numeric game-version ID
# rather than an interface number, so the interface number from the TOC is
# converted to a version name ("120007" -> "12.0.7") and looked up.
#
# Run with CF_DRY_RUN=1 to print what would be sent without uploading.

set -euo pipefail

cd "$(dirname "$0")/.."

ADDON="KillThemAll"
TOC="$ADDON.toc"

# Interface numbers are packed as MMmmpp: 120007 -> 12.0.7, 110205 -> 11.2.5.
interface_to_name() {
	local n="$1"
	printf '%d.%d.%d' $(( n / 10000 )) $(( (n / 100) % 100 )) $(( n % 100 ))
}

# Exercise the conversion without credentials, a zip, or a network. Runs in CI.
if [[ "${CF_SELFTEST:-}" == "1" ]]; then
	fails=0
	check() {
		local got; got="$(interface_to_name "$1")"
		if [[ "$got" != "$2" ]]; then
			echo "  FAIL $1 -> $got (expected $2)"; fails=1
		else
			echo "  ok   $1 -> $got"
		fi
	}
	check 120007 "12.0.7"
	check 120000 "12.0.0"
	check 110205 "11.2.5"
	check 100207 "10.2.7"
	check 11502  "1.15.2"
	check 50500  "5.5.0"
	check 40400  "4.4.0"
	exit "$fails"
fi

ZIP="${1:-}"
if [[ -z "$ZIP" || ! -f "$ZIP" ]]; then
	echo "usage: tools/curseforge-upload.sh <zip>" >&2
	exit 1
fi

VERSION="$(sed -n 's/^## Version:[[:space:]]*//p' "$TOC" | tr -d '\r')"
INTERFACE="$(sed -n 's/^## Interface:[[:space:]]*//p' "$TOC" | tr -d '\r')"
GAME_VERSION_NAME="$(interface_to_name "$INTERFACE")"

: "${CF_API_KEY:?set CF_API_KEY}"
: "${CF_PROJECT_ID:?set CF_PROJECT_ID}"

echo "$ADDON $VERSION -> CurseForge project $CF_PROJECT_ID"
echo "  interface $INTERFACE = game version $GAME_VERSION_NAME"
echo "  zip $ZIP ($(du -h "$ZIP" | cut -f1 | tr -d ' '))"

# Checked before any network call so a dry run works entirely offline.
if [[ "${CF_DRY_RUN:-}" == "1" ]]; then
	echo "  dry run: would resolve the game version id for $GAME_VERSION_NAME,"
	echo "           then POST the zip to project $CF_PROJECT_ID. Nothing sent."
	exit 0
fi

versions_json="$(curl -sS --fail-with-body \
	-H "X-Api-Token: $CF_API_KEY" \
	https://wow.curseforge.com/api/game/versions)"

GAME_VERSION_ID="$(GAME_VERSION_NAME="$GAME_VERSION_NAME" python3 -c '
import json, os, sys
target = os.environ["GAME_VERSION_NAME"]
for entry in json.load(sys.stdin):
    if entry.get("name") == target:
        print(entry["id"])
        break
' <<<"$versions_json")"

if [[ -z "$GAME_VERSION_ID" ]]; then
	echo "error: CurseForge lists no game version named $GAME_VERSION_NAME." >&2
	echo "       Available names close to it:" >&2
	python3 -c '
import json, sys
names = sorted(e.get("name", "") for e in json.load(sys.stdin))
print("      ", ", ".join(n for n in names if n.startswith("12.") or n.startswith("11."))[:400])
' <<<"$versions_json" >&2 || true
	exit 1
fi
echo "  resolved game version id $GAME_VERSION_ID"

metadata="$(ADDON="$ADDON" VERSION="$VERSION" GAME_VERSION_ID="$GAME_VERSION_ID" python3 -c '
import json, os
print(json.dumps({
    "changelog": os.environ.get("CF_CHANGELOG", "See the GitHub release for details."),
    "changelogType": "markdown",
    "displayName": os.environ["ADDON"] + " " + os.environ["VERSION"],
    "gameVersions": [int(os.environ["GAME_VERSION_ID"])],
    "releaseType": os.environ.get("CF_RELEASE_TYPE", "release"),
}))
')"

curl -sS --fail-with-body \
	-H "X-Api-Token: $CF_API_KEY" \
	-F "metadata=$metadata" \
	-F "file=@$ZIP" \
	"https://wow.curseforge.com/api/projects/$CF_PROJECT_ID/upload-file"
echo
echo "  uploaded."
