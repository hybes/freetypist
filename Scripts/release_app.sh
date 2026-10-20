#!/bin/bash
# Run on the Mac holding the Developer ID certificate and Sparkle Keychain key.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
app="${1:-$root/dist/FreeTypist.app}"
out="${RELEASE_DIRECTORY:-$root/dist/releases}"
tools="${SPARKLE_TOOLS:-/tmp/freetypist-build/artifacts/sparkle/Sparkle/bin}"
profile="${NOTARY_PROFILE:?Set NOTARY_PROFILE to an existing notarytool Keychain profile}"
export SIGNING_IDENTITY="${SIGNING_IDENTITY:?Set SIGNING_IDENTITY to your Developer ID Application identity}"
[[ "$SIGNING_IDENTITY" == *"Developer ID Application"* ]] || { echo 'A Developer ID Application identity is required.' >&2; exit 1; }
mkdir -p "$out"
out="$(cd "$out" && pwd)"
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")
public_key=$("$tools/generate_keys" --account com.freetypist.app -p)
embedded_key=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")
[ "$public_key" = "$embedded_key" ] || { echo 'The app does not contain the public key for this signing account.' >&2; exit 1; }
bash "$root/Scripts/sign_app.sh" "$app"
work=$(mktemp -d "${TMPDIR:-/tmp}/freetypist-release.XXXXXX")
trap 'rm -rf "$work"' EXIT

notarise() {
    local result="$work/notarisation.json"
    xcrun notarytool submit "$1" --keychain-profile "$profile" --wait --output-format json > "$result"
    if [ "$(plutil -extract status raw -o - "$result")" != Accepted ]; then
        cat "$result" >&2
        echo 'Apple did not accept this release. Nothing has been published.' >&2
        exit 1
    fi
    plutil -extract id raw -o - "$result"
}

ditto -c -k --keepParent "$app" "$work/notarise.zip"
notarise "$work/notarise.zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
zip_name="FreeTypist-$version-arm64.zip"
dmg_name="FreeTypist-$version-arm64.dmg"
ditto -c -k --keepParent "$app" "$out/$zip_name"
mkdir "$work/dmg"
ditto "$app" "$work/dmg/FreeTypist.app"
ln -s /Applications "$work/dmg/Applications"
hdiutil create -quiet -volname FreeTypist -srcfolder "$work/dmg" -format UDZO -ov "$out/$dmg_name"
codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$out/$dmg_name"
notarise "$out/$dmg_name"
xcrun stapler staple "$out/$dmg_name"
xcrun stapler validate "$out/$dmg_name"
spctl --assess --type execute --verbose=2 "$app"

mkdir "$work/appcast"
cp -X "$out/$zip_name" "$work/appcast/$zip_name"
if [ -f "$out/appcast.xml" ]; then cp -X "$out/appcast.xml" "$work/appcast/appcast.xml"; fi
"$tools/generate_appcast" --account com.freetypist.app --maximum-deltas 0 \
    --download-url-prefix https://type.cnnct.uk/releases/ --link https://type.cnnct.uk/ "$work/appcast"
cp -X "$work/appcast/appcast.xml" "$out/appcast.xml"
python3 - "$app" "$out" "$version" "$build" "$dmg_name" "$zip_name" <<'PY'
import hashlib, json, pathlib, plistlib, sys
app, out, version, build, dmg, archive = sys.argv[1:]
out = pathlib.Path(out)
with open(pathlib.Path(app) / 'Contents/Info.plist', 'rb') as f:
    info = plistlib.load(f)
assets = []
for name in [dmg, archive]:
    path = out / name
    digest = hashlib.sha256()
    with path.open('rb') as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b''): digest.update(chunk)
    sha = digest.hexdigest()
    (out / (name + '.sha256')).write_text(f'{sha}  {name}\n')
    assets.append(dict(file=name, size=path.stat().st_size, sha256=sha))
release = dict(version=version, build=int(build), notarised=True, architecture='arm64',
               minimumSystemVersion=info['LSMinimumSystemVersion'], assets=assets, **assets[0])
(out / 'mac.json').write_text(json.dumps(release, indent=2) + '\n')
print(f'Ready to publish FreeTypist {version} ({build}): {out}')
PY
