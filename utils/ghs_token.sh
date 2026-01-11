#!/usr/bin/env bash
set -euo pipefail

# Dependencies
for bin in openssl curl jq date; do
  command -v "$bin" >/dev/null 2>&1 || { echo "Missing dependency: $bin" >&2; exit 1; }
done

usage() {
  cat >&2 <<'EOF'
Usage:
  ghs_token.sh
    --issuer <ISSUER>
    --installation-id <ID>
    [--api-url <URL>]
    [--repo-ids <CSV>]
    [--permissions <JSON>]
    [--pem-file <PATH>]
    [--pem-env <ENVVAR>]

Required:
  --issuer            GitHub App issuer claim (recommended: client_id; alternatively app_id)
  --installation-id   Installation ID

Optional:
  --api-url            GitHub API base URL (default: https://api.github.com)
  --repo-ids           Comma-separated repository IDs to scope the token (max 500)
  --permissions        JSON object to downscope permissions (subset of app permissions)
  --pem-file           Path to PEM file (for local testing)
  --pem-env            Env var name containing PEM (default: GITHUB_APP_PEM)

PEM input priority (no disk in CI):
  1) --pem-file        (local testing only)
  2) --pem-env         (default: GITHUB_APP_PEM)
  3) stdin             (pipe/redirect)

Notes:
  - PEM is never written to disk by the script.
  - JWT uses RS256 with iat = now-60s and exp <= now+600s.
  - Prints the installation token to stdout; expiry is printed to stderr.

Examples:
  Local:
    ghs_token.sh \
      --issuer <CLIENT_ID> \
      --installation-id <ID> \
      --pem-file ./github-app.pem

  CI (env):
    export GITHUB_APP_PEM="${GH_APP_PRIVATE_KEY}"
    ghs_token.sh --issuer <CLIENT_ID> --installation-id <ID>

  CI (stdin):
    printf '%s\n' "$GH_APP_PRIVATE_KEY" | \
      ghs_token.sh --issuer <CLIENT_ID> --installation-id <ID>
EOF
}

ISSUER=""
INSTALLATION_ID=""
API_URL="https://api.github.com"
REPO_IDS=""
PERMISSIONS_JSON=""
PEM_ENV="GITHUB_APP_PEM"
PEM_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issuer) ISSUER="$2"; shift 2;;
    --installation-id) INSTALLATION_ID="$2"; shift 2;;
    --api-url) API_URL="$2"; shift 2;;
    --repo-ids) REPO_IDS="$2"; shift 2;;
    --permissions) PERMISSIONS_JSON="$2"; shift 2;;
    --pem-env) PEM_ENV="$2"; shift 2;;
    --pem-file) PEM_FILE="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown arg: $1" >&2; usage; exit 1;;
  esac
done

if [[ -z "$ISSUER" || -z "$INSTALLATION_ID" ]]; then
  echo "Error: --issuer and --installation-id are required" >&2
  usage
  exit 1
fi

# Read PEM (priority: --pem-file -> env -> stdin)
PEM=""
if [[ -n "$PEM_FILE" ]]; then
  if [[ ! -r "$PEM_FILE" ]]; then
    echo "Error: --pem-file is not readable: $PEM_FILE" >&2
    exit 1
  fi
  PEM="$(cat "$PEM_FILE")"
else
  PEM="${!PEM_ENV:-}"
  if [[ -z "$PEM" ]]; then
    # Only read stdin if it's not an interactive TTY (i.e., piped/redirected)
    if [[ -t 0 ]]; then
      echo "Error: PEM not provided. Use --pem-file, set ${PEM_ENV}, or pipe PEM via stdin." >&2
      exit 1
    fi
    PEM="$(cat)"
  fi
fi

if [[ -z "$PEM" ]]; then
  echo "Error: PEM is empty." >&2
  exit 1
fi

b64url() {
  # base64url without padding
  openssl base64 -A | tr '+/' '-_' | tr -d '='
}

now="$(date +%s)"
iat="$((now - 60))"
exp="$((now + 600))" # <= 10 min

header='{"typ":"JWT","alg":"RS256"}'
payload="$(jq -nc --arg iat "$iat" --arg exp "$exp" --arg iss "$ISSUER" \
  '{iat:($iat|tonumber), exp:($exp|tonumber), iss:$iss}')"

header_b64="$(printf '%s' "$header" | b64url)"
payload_b64="$(printf '%s' "$payload" | b64url)"
unsigned="${header_b64}.${payload_b64}"

# Sign WITHOUT writing PEM to disk
signature_b64="$(
  printf '%s' "$unsigned" \
  | openssl dgst -sha256 -sign <(printf '%s\n' "$PEM") \
  | b64url
)"

jwt="${unsigned}.${signature_b64}"

# Build request body (optionally downscope)
body='{}'
if [[ -n "$REPO_IDS" ]]; then
  # CSV -> JSON array of numbers
  repo_ids_json="$(jq -nc --arg csv "$REPO_IDS" '
    $csv
    | split(",")
    | map(gsub("\\s+";""))
    | map(select(length>0))
    | map(tonumber)
  ')"
  body="$(jq -c --argjson repo_ids "$repo_ids_json" '. + {repository_ids:$repo_ids}' <<<"$body")"
fi

if [[ -n "$PERMISSIONS_JSON" ]]; then
  # Expect a JSON object string, e.g. {"contents":"write","pull_requests":"write"}
  # Validate it's JSON object
  jq -e 'type=="object"' >/dev/null <<<"$PERMISSIONS_JSON" || {
    echo "Error: --permissions must be a JSON object" >&2
    exit 1
  }
  body="$(jq -c --argjson perms "$PERMISSIONS_JSON" '. + {permissions:$perms}' <<<"$body")"
fi

resp="$(
  curl -fsS -X POST \
    -H "Accept: application/vnd.github+json" \
    -H "Authorization: Bearer ${jwt}" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "${API_URL}/app/installations/${INSTALLATION_ID}/access_tokens" \
    -d "$body"
)"

token="$(jq -r '.token // empty' <<<"$resp")"
expires_at="$(jq -r '.expires_at // empty' <<<"$resp")"

if [[ -z "$token" ]]; then
  echo "Error: No token in response:" >&2
  echo "$resp" >&2
  exit 1
fi

# Optional: mask in GitHub Actions logs if running there
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  echo "::add-mask::${token}"
fi

# Print expiry to stderr, token to stdout (so you can capture cleanly)
echo "expires_at=${expires_at}" >&2
printf '%s\n' "$token"
