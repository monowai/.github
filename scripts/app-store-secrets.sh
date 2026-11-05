#!/usr/bin/env bash
# Sets up an app repository for ios-testflight.yml: creates its `app-store`
# environment (deployable from main only) and sets the six secrets the release
# job reads. Run it from the laptop that holds the signing material.
#
# Usage: scripts/app-store-secrets.sh <owner/repo> <profile name>...
#   e.g. scripts/app-store-secrets.sh monowai/ruby RunRuby
#        scripts/app-store-secrets.sh monowai/bc-mobile Beancounter BeancounterWidget
#
# The profile names are the App Store provisioning profiles the archive signs
# with, app and extensions, as named in the developer portal. They are read
# from Xcode's profile folders, so download them in Xcode first.
#
# Shared material, the same for every app, lives in one private folder:
#   $APP_STORE_CI_DIR (default ~/.appstoreconnect/ci)
#     AuthKey_<key id>.p8   the CI App Store Connect team key; exactly one
#     dist.p12              the Apple Distribution certificate and private key
#   APP_STORE_API_ISSUER    the team's issuer ID (environment variable)
#   login keychain item, service app-store-dist-p12: the .p12's password
#     (add it with: security add-generic-password -a "$USER" -s app-store-dist-p12 -w)
set -euo pipefail

if [[ $# -lt 2 ]]; then
  sed -n '6,8p' "$0" >&2
  exit 2
fi
repo="$1"
shift

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

# Each named profile: the App Store one (no device list) that expires last.
profile_dirs=("$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" "$HOME/Library/MobileDevice/Provisioning Profiles")
profiles=()
for wanted in "$@"; do
  best="" best_expiry=""
  for dir in "${profile_dirs[@]}"; do
    [[ -d "$dir" ]] || continue
    for file in "$dir"/*.mobileprovision; do
      [[ -f "$file" ]] || continue
      plist="$(security cms -D -i "$file" 2>/dev/null)" || continue
      [[ "$(plutil -extract Name raw - <<<"$plist" 2>/dev/null)" == "$wanted" ]] || continue
      plutil -extract ProvisionedDevices raw - <<<"$plist" >/dev/null 2>&1 && continue
      expiry="$(plutil -extract ExpirationDate raw - <<<"$plist")"
      if [[ -z "$best" || "$expiry" > "$best_expiry" ]]; then
        best="$file" best_expiry="$expiry"
      fi
    done
  done
  [[ -n "$best" ]] || { echo "No App Store profile named '$wanted'; download it in Xcode first" >&2; exit 1; }
  if [[ "$best_expiry" < "$(date -u +%Y-%m-%dT%H:%M:%SZ)" ]]; then
    echo "Profile '$wanted' expired $best_expiry; regenerate it first" >&2
    exit 1
  fi
  echo "Profile $wanted: $(basename "$best"), expires $best_expiry"
  profiles+=("$best")
done

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
for file in "${profiles[@]}"; do base64 -i "$file"; done | set_secret IOS_PROVISIONING_PROFILES

gh secret list -R "$repo" --env app-store
