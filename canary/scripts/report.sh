#!/usr/bin/env bash
# report.sh — POST one canary result to the compat board. The contract is
# canary/REPORTING.md.
#
# Two ways to authenticate, tried in this order:
#   1. OIDC: when the job may mint a GitHub Actions OIDC token (the workflow
#      grants `id-token: write`, so ACTIONS_ID_TOKEN_REQUEST_URL is set), mint
#      one for the board's URL as audience and POST to <board>/v2/runs with
#      `Authorization: Bearer`. No secret is involved.
#   2. HMAC (being retired): with REPORT_URL and REPORT_KEY set, sign the body
#      for Bynk's `Signature` actor and POST to REPORT_URL.
# Otherwise it skips silently. A failed report is a warning, never a canary
# failure: this script always exits 0 once it has its inputs.
#
# Environment:
#   BOARD_URL       the board, for OIDC (default https://compat-board.accuser.workers.dev)
#   ACTIONS_ID_TOKEN_REQUEST_URL, ACTIONS_ID_TOKEN_REQUEST_TOKEN   set by GitHub Actions
#   REPORT_URL, REPORT_KEY                       the HMAC endpoint and shared secret
#   REPO, KIND, BYNK_VERSION, RESULT, COMMIT_SHA, RUN_URL   the payload fields
#   CURL                                         the `curl` command (default: curl)
set -euo pipefail

CURL="${CURL:-curl}"
BOARD_URL="${BOARD_URL:-https://compat-board.accuser.workers.dev}"
BOARD_URL="${BOARD_URL%/}"

mode=""
if [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_TOKEN:-}" ]; then
  mode=oidc
elif [ -n "${REPORT_URL:-}" ] && [ -n "${REPORT_KEY:-}" ]; then
  mode=hmac
else
  exit 0
fi
: "${REPO:?}" "${KIND:?}" "${BYNK_VERSION:?}" "${RESULT:?}" "${COMMIT_SHA:?}" "${RUN_URL:?}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

warn() { echo "::warning::canary report to the compat board failed: $*"; exit 0; }

# The body is built once, compact, and sent byte for byte (as signed, for HMAC).
jq -cnj \
  --arg repo "$REPO" --arg kind "$KIND" --arg bynk_version "$BYNK_VERSION" \
  --arg result "$RESULT" --arg commit "$COMMIT_SHA" --arg run_url "$RUN_URL" \
  --arg finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{repo: $repo, kind: $kind, bynk_version: $bynk_version, result: $result,
    commit: $commit, run_url: $run_url, finished_at: $finished_at}' \
  > "$tmp/body.json"

if [ "$mode" = oidc ]; then
  # GitHub's token endpoint takes the audience URL-encoded, as @actions/core's
  # getIDToken does. The board checks `aud` against its own URL.
  audience="$(jq -rn --arg a "$BOARD_URL" '$a | @uri')"
  "$CURL" --silent --show-error --fail --max-time 30 \
       -H "Authorization: bearer ${ACTIONS_ID_TOKEN_REQUEST_TOKEN}" \
       "${ACTIONS_ID_TOKEN_REQUEST_URL}&audience=${audience}" \
       -o "$tmp/token.json" 2>"$tmp/error" \
    || warn "could not mint an OIDC token: $(tr '\n' ' ' <"$tmp/error")"
  token="$(jq -r '.value // empty' "$tmp/token.json" 2>/dev/null || true)"
  [ -n "$token" ] || warn "the OIDC token response had no value"
  echo "::add-mask::${token}"
  url="${BOARD_URL}/v2/runs"
  auth=(-H "Authorization: Bearer ${token}")
else
  # Bynk's Signature actor with a `timestamp` header verifies HMAC-SHA256, keyed
  # by the secret's UTF-8 bytes, over the string "<X-Timestamp>.<raw body>", and
  # accepts a bare hex digest in the signature header. See REPORTING.md.
  ts="$(date +%s)"
  sig="$( { printf '%s.' "$ts"; cat "$tmp/body.json"; } \
    | openssl dgst -sha256 -hmac "$REPORT_KEY" -binary | od -An -v -tx1 | tr -d ' \n')"
  url="$REPORT_URL"
  auth=(-H "X-Timestamp: ${ts}" -H "X-Signature: ${sig}")
fi

if "$CURL" --silent --show-error --fail-with-body --max-time 30 \
     --retry 2 \
     -X POST "$url" \
     -H "Content-Type: application/json" \
     "${auth[@]}" \
     --data-binary "@$tmp/body.json" \
     -o "$tmp/response" 2>"$tmp/error"; then
  echo "Reported ${RESULT} for ${REPO} with Bynk ${BYNK_VERSION} (${mode})"
else
  # The error and response are the receiver's, never the token, key or signature.
  warn "$(tr '\n' ' ' <"$tmp/error") $(head -c 500 "$tmp/response" 2>/dev/null | tr '\n' ' ')"
fi
