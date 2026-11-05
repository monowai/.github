#!/usr/bin/env bash
# Sets up an app repository for ios-testflight.yml: creates its `app-store`
# environment (deployable from main only) and sets the six secrets the release
# job reads. Run it from the laptop that holds the signing material.
#
# Usage: scripts/app-store-secrets.sh <owner/repo>
#   e.g. scripts/app-store-secrets.sh monowai/ruby
#
# The profiles come from the repository itself: its committed
# ExportOptions.plist (on the default branch) maps each bundle ID the archive
# signs, app and extensions, to its App Store profile name. That file is what
# the export signs with, so it is the one list; there is no second copy here to
# drift. Each profile must be found in Xcode's profile folders with that exact
# name AND that bundle ID, as an App Store profile that has not expired, or
# nothing is set. Download the profiles in Xcode first.
#
# Shared material, the same for every app, lives in one private folder:
#   $APP_STORE_CI_DIR (default ~/.appstoreconnect/ci)
#     AuthKey_<key id>.p8   the CI App Store Connect team key; exactly one
#     dist.p12              the Apple Distribution certificate and private key
#   APP_STORE_API_ISSUER    the team's issuer ID (environment variable)
#   login keychain item, service app-store-dist-p12: the .p12's password
#     (add it with: security add-generic-password -a "$USER" -s app-store-dist-p12 -w)
set -euo pipefail

if [[ $# -ne 1 ]]; then
  sed -n '6,7p' "$0" >&2
  exit 2
fi
repo="$1"

ci_dir="${APP_STORE_CI_DIR:-$HOME/.appstoreconnect/ci}"
: "${APP_STORE_API_ISSUER:?Set APP_STORE_API_ISSUER to the App Store Connect issuer ID}"

shopt -s nullglob
keys=("$ci_dir"/AuthKey_*.p8)
shopt -u nullglob
if [[ ${#keys[@]} -ne 1 ]]; then
  echo "Expected exactly one AuthKey_<id>.p8 in $ci_dir, found ${#keys[@]}" >&2
  exit 1
fi
key_file="${keys[0]}"
key_id="$(basename "$key_file" .p8)"
key_id="${key_id#AuthKey_}"

p12="$ci_dir/dist.p12"
[[ -f "$p12" ]] || { echo "Missing $p12" >&2; exit 1; }
p12_password="$(security find-generic-password -a "$USER" -s app-store-dist-p12 -w)" ||
  { echo "No keychain item app-store-dist-p12; see the header of $0" >&2; exit 1; }
# Fail here, not in CI, when the password does not open the file.
openssl pkcs12 -in "$p12" -passin "pass:$p12_password" -nokeys -noout 2>/dev/null ||
  openssl pkcs12 -legacy -in "$p12" -passin "pass:$p12_password" -nokeys -noout 2>/dev/null ||
  { echo "The keychain password does not open $p12" >&2; exit 1; }

# The repository's one ExportOptions.plist (ExportOptions-tvOS.plist and the
# like are other platforms' and not matched).
export_path="$(gh api "repos/$repo/git/trees/HEAD?recursive=1" \
  --jq '[.tree[].path | select(. == "ExportOptions.plist" or endswith("/ExportOptions.plist"))] | if length == 1 then .[0] else error("found \(length): \(join(", "))") end')" ||
  { echo "$repo needs exactly one committed ExportOptions.plist" >&2; exit 1; }
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
gh api "repos/$repo/contents/$export_path" --jq .content | base64 --decode > "$work/ExportOptions.plist"
echo "Profiles from $repo:$export_path"

# One path per line, in ExportOptions order; exits non-zero with the reason.
python3 - "$work/ExportOptions.plist" > "$work/profiles" <<'PY'
import datetime, glob, os, plistlib, subprocess, sys

export = plistlib.load(open(sys.argv[1], "rb"))
team = export.get("teamID")
wanted = export.get("provisioningProfiles") or {}
if not team or not wanted:
    sys.exit("ExportOptions.plist needs teamID and provisioningProfiles")

folders = [
    os.path.expanduser("~/Library/Developer/Xcode/UserData/Provisioning Profiles"),
    os.path.expanduser("~/Library/MobileDevice/Provisioning Profiles"),
]
installed = []
for path in sorted({p for folder in folders for p in glob.glob(os.path.join(folder, "*.mobileprovision"))}):
    decoded = subprocess.run(["security", "cms", "-D", "-i", path], capture_output=True)
    if decoded.returncode:
        continue
    profile = plistlib.loads(decoded.stdout)
    installed.append((path, profile))

now = datetime.datetime.now(datetime.timezone.utc)
problems = []
for bundle, name in wanted.items():
    app_id = f"{team}.{bundle}"
    same_bundle = [
        (path, p) for path, p in installed
        if p.get("Entitlements", {}).get("application-identifier") == app_id and "ProvisionedDevices" not in p
    ]
    matches = [(path, p) for path, p in same_bundle if p.get("Name") == name]
    if not matches:
        others = sorted({p.get("Name") for _, p in same_bundle})
        hint = f"; App Store profiles for {bundle} here are named: {', '.join(others)}" if others else ""
        problems.append(f"no App Store profile named '{name}' for {bundle}{hint}")
        continue
    path, profile = max(matches, key=lambda m: m[1]["ExpirationDate"])
    expiry = profile["ExpirationDate"].replace(tzinfo=datetime.timezone.utc)
    if expiry < now:
        problems.append(f"'{name}' for {bundle} expired {expiry:%Y-%m-%d}; regenerate it")
        continue
    print(f"  {bundle}: '{name}', expires {expiry:%Y-%m-%d}", file=sys.stderr)
    print(path)
if problems:
    sys.exit("\n".join(problems))
PY

echo "Environment app-store on $repo, main only"
gh api -X PUT "repos/$repo/environments/app-store" --silent --input - <<'JSON'
{"deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}
JSON
if ! gh api "repos/$repo/environments/app-store/deployment-branch-policies" --jq '.branch_policies[].name' | grep -qx main; then
  gh api -X POST "repos/$repo/environments/app-store/deployment-branch-policies" -f name=main -f type=branch --silent
fi

set_secret() { gh secret set "$1" -R "$repo" --env app-store; }
printf '%s' "$key_id" | set_secret ASC_KEY_ID
printf '%s' "$APP_STORE_API_ISSUER" | set_secret ASC_ISSUER_ID
set_secret ASC_KEY_P8 <"$key_file"
base64 -i "$p12" | set_secret IOS_DIST_CERT_P12
printf '%s' "$p12_password" | set_secret IOS_DIST_CERT_PASSWORD
while IFS= read -r file; do base64 -i "$file"; done <"$work/profiles" | set_secret IOS_PROVISIONING_PROFILES

gh secret list -R "$repo" --env app-store
