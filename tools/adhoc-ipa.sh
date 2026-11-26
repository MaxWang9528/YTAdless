#!/usr/bin/env bash
# adhoc-ipa.sh — builds an ad hoc–signed YTadless.ipa for the iPhones in a provisioning profile.
#
#   P12_PASSWORD=… tools/adhoc-ipa.sh [profile.mobileprovision] [p12] [https://base.url/for/ota]
#
# Defaults: the only *.mobileprovision in the repo root, AdHoc-Certificates.p12, no OTA manifest.
# Output: dist/YTadless.ipa, plus dist/manifest.plist and dist/install.html when a base URL is
# given (host all three at that URL; install link = itms-services://?action=download-manifest&url=<base>/manifest.plist).
#
# The bundle ID and entitlements come from the profile (e.g. com.cloudgravity.maxsyta), so the
# ad hoc app installs beside the xtool dev build (com.example.YTadless) and never replaces it.
# The signing files are gitignored; the password is read from P12_PASSWORD, never from a file in the repo.
# Needs: xtool, rcodesign (apple-codesign 0.29+), openssl, python3.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root"

profile="${1:-}"
if [[ -z "$profile" ]]; then
    shopt -s nullglob; candidates=(*.mobileprovision); shopt -u nullglob
    [[ ${#candidates[@]} -eq 1 ]] || { echo "error: pass the profile path (found ${#candidates[@]} .mobileprovision files in the repo root)" >&2; exit 1; }
    profile="${candidates[0]}"
fi
p12="${2:-AdHoc-Certificates.p12}"
base_url="${3:-}"
: "${P12_PASSWORD:?set P12_PASSWORD to the .p12 password}"
[[ -f "$profile" ]] || { echo "error: no profile at $profile" >&2; exit 1; }
[[ -f "$p12" ]] || { echo "error: no .p12 at $p12" >&2; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
umask 077
printf '%s' "$P12_PASSWORD" > "$work/p12pass"

# 1. Profile → plist → bundle ID, team, entitlements (wildcard keychain group made concrete, as Xcode does).
openssl smime -inform der -verify -noverify -in "$profile" -out "$work/profile.plist" 2>/dev/null
read -r bundle_id team expiry < <(python3 -I - "$work/profile.plist" "$work/entitlements.plist" <<'PY'
import plistlib, sys
p = plistlib.load(open(sys.argv[1], "rb"))
ent = dict(p["Entitlements"])
team = p["TeamIdentifier"][0]
app_id = ent["application-identifier"]
bundle_id = app_id.split(".", 1)[1]
if "*" in bundle_id:
    sys.exit("error: wildcard profile; use an explicit App ID profile")
if ent.get("get-task-allow", False):
    sys.exit("error: this is a development profile (get-task-allow); use the ad hoc profile")
groups = ent.get("keychain-access-groups")
if groups:
    ent["keychain-access-groups"] = [g.replace(team + ".*", app_id) for g in groups]
plistlib.dump(ent, open(sys.argv[2], "wb"))
print(bundle_id, team, p["ExpirationDate"].date())
PY
)
devices="$(python3 -I -c 'import plistlib,sys; print(len(plistlib.load(open(sys.argv[1],"rb")).get("ProvisionedDevices",[])))' "$work/profile.plist")"
echo "profile: $bundle_id (team $team), $devices devices, expires $expiry"

# 2. Release build (unsigned .app).
xtool dev build --configuration release
app_src="xtool/YTadless.app"
[[ -d "$app_src" ]] || { echo "error: $app_src not found after build" >&2; exit 1; }

# 3. Copy into Payload/, set the bundle ID, embed the profile.
mkdir -p "$work/Payload"
cp -R "$app_src" "$work/Payload/"
app="$work/Payload/YTadless.app"
rm -rf "$app/_CodeSignature" "$app/embedded.mobileprovision"
cp "$profile" "$app/embedded.mobileprovision"
read -r short_version build_version < <(python3 -I - "$app/Info.plist" "$bundle_id" <<'PY'
import plistlib, sys
path, bundle_id = sys.argv[1], sys.argv[2]
info = plistlib.load(open(path, "rb"))
info["CFBundleIdentifier"] = bundle_id
plistlib.dump(info, open(path, "wb"))
print(info.get("CFBundleShortVersionString", "1.0"), info.get("CFBundleVersion", "1"))
PY
)

# 4. Sign.
rcodesign sign \
    --p12-file "$p12" --p12-password-file "$work/p12pass" \
    --entitlements-xml-file "$work/entitlements.plist" \
    "$app"
rcodesign verify "$app/YTadless" >/dev/null

# 5. Package.
mkdir -p dist
rm -f dist/YTadless.ipa
(cd "$work" && zip -qr -y "$root/dist/YTadless.ipa" Payload)
echo "wrote dist/YTadless.ipa ($bundle_id $short_version ($build_version))"

# 6. Optional over-the-air install files.
if [[ -n "$base_url" ]]; then
    base_url="${base_url%/}"
    [[ "$base_url" == https://* ]] || { echo "error: the base URL must be https://" >&2; exit 1; }
    python3 -I - "$base_url" "$bundle_id" "$short_version" <<'PY'
import plistlib, sys, html, urllib.parse
base, bundle_id, version = sys.argv[1:]
manifest = {"items": [{
    "assets": [{"kind": "software-package", "url": base + "/YTadless.ipa"}],
    "metadata": {"bundle-identifier": bundle_id, "bundle-version": version, "kind": "software", "title": "YTadless"},
}]}
plistlib.dump(manifest, open("dist/manifest.plist", "wb"))
link = "itms-services://?action=download-manifest&url=" + urllib.parse.quote(base + "/manifest.plist", safe=":/")
open("dist/install.html", "w").write(
    '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
    '<title>Install YTadless</title><body style="font:17px -apple-system,sans-serif;text-align:center;padding:3em 1em">'
    f'<p><a href="{html.escape(link)}" style="font-size:1.4em">Install YTadless</a></p>'
    '<p>Open this page in Safari on your iPhone. After installing, open the app from the Home Screen.</p></body>\n')
print("wrote dist/manifest.plist and dist/install.html; install link:", link)
PY
fi
