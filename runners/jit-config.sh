#!/usr/bin/env bash
# Print a single-use (just-in-time) runner config for one slot, using the thirdline-runners
# GitHub App (docs/progress.md, A5a). Run as root on the runner host; only the supervisor calls it.
#
#   jit-config.sh <slot>             prints the encoded JIT config on stdout (a secret: never log it)
#   jit-config.sh <slot> --dry-run   gets a config, prints the runner it would create, then
#                                    deletes that runner again, so nothing is left registered
#
# Reads /etc/thirdline-runners/app.env (APP_ID, INSTALLATION_ID), the key
# /etc/thirdline-runners/app.pem, and the slot file /etc/thirdline-runners/slots/<slot>.env
# (RUNNER_NAME, RUNNER_GROUP_ID, RUNNER_LABELS as a comma list).
set -euo pipefail

ORG=Thirdline-LLC
API=https://api.github.com
CONF=/etc/thirdline-runners
slot=${1:?usage: jit-config.sh <slot> [--dry-run]}
dry_run=${2:-}

die() { echo "jit-config: $*" >&2; exit 1; }
[[ "$slot" =~ ^[a-z0-9-]+$ ]] || die "bad slot name '$slot'"
# shellcheck source=/dev/null
source "$CONF/app.env"
# shellcheck source=/dev/null
source "$CONF/slots/$slot.env"
: "${APP_ID:?}" "${INSTALLATION_ID:?}" "${RUNNER_NAME:?}" "${RUNNER_GROUP_ID:?}" "${RUNNER_LABELS:?}"
[ -r "$CONF/app.pem" ] || die "can't read $CONF/app.pem"

# WSL's clock can drift after Windows sleeps, and GitHub refuses a JWT from the future or past.
# Compare with GitHub's own clock first, so the error says what is actually wrong.
gh_date=$(curl -fsSI "$API" | tr -d '\r' | sed -n 's/^[Dd]ate: //p')
skew=$(( $(date +%s) - $(date -d "$gh_date" +%s) ))
[ "${skew#-}" -le 30 ] || die "this machine's clock is ${skew}s off GitHub's; fix the time (hwclock -s or wsl --shutdown) and retry"

b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }
now=$(date +%s)
header=$(printf '{"alg":"RS256","typ":"JWT"}' | b64url)
payload=$(printf '{"iat":%d,"exp":%d,"iss":"%s"}' "$((now - 60))" "$((now + 540))" "$APP_ID" | b64url)
sig=$(printf '%s.%s' "$header" "$payload" | openssl dgst -sha256 -sign "$CONF/app.pem" -binary | b64url)
jwt="$header.$payload.$sig"

api() {  # api METHOD PATH TOKEN [JSON]
  curl -fsS -X "$1" "$API$2" -H "Authorization: Bearer $3" \
    -H "Accept: application/vnd.github+json" -H "X-GitHub-Api-Version: 2022-11-28" \
    ${4:+-d "$4"}
}

token=$(api POST "/app/installations/$INSTALLATION_ID/access_tokens" "$jwt" | jq -r .token) \
  || die "couldn't get an installation token (App id $APP_ID, installation $INSTALLATION_ID)"

body=$(jq -cn --arg n "$RUNNER_NAME" --argjson g "$RUNNER_GROUP_ID" --arg l "$RUNNER_LABELS" \
  '{name: $n, runner_group_id: $g, labels: ($l | split(",")), work_folder: "_work"}')
resp=$(api POST "/orgs/$ORG/actions/runners/generate-jitconfig" "$token" "$body") \
  || die "GitHub refused a JIT config for $RUNNER_NAME (is a runner with that name still registered?)"

if [ "$dry_run" = --dry-run ]; then
  jq -r '.runner | "would run: id \(.id), \(.name), labels \([.labels[].name] | join(","))"' <<< "$resp"
  id=$(jq -r .runner.id <<< "$resp")
  api DELETE "/orgs/$ORG/actions/runners/$id" "$token" > /dev/null && echo "removed test registration $id"
  exit 0
fi
jq -r .encoded_jit_config <<< "$resp"
