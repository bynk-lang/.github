#!/usr/bin/env bash
# report.sh — POST one canary result to the compat board, signed for Bynk's
# `Signature` actor. The contract is canary/REPORTING.md.
#
# Skips silently unless both REPORT_URL and REPORT_KEY are set. A failed report
# is a warning, never a canary failure: this script always exits 0 once it has
# its inputs.
#
# Environment:
#   REPORT_URL, REPORT_KEY                       endpoint and shared secret
#   REPO, KIND, BYNK_VERSION, RESULT, COMMIT_SHA, RUN_URL   the payload fields
#   CURL                                         the `curl` command (default: curl)
set -euo pipefail

CURL="${CURL:-curl}"

if [ -z "${REPORT_URL:-}" ] || [ -z "${REPORT_KEY:-}" ]; then
  exit 0
fi
: "${REPO:?}" "${KIND:?}" "${BYNK_VERSION:?}" "${RESULT:?}" "${COMMIT_SHA:?}" "${RUN_URL:?}"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# The body is built once, compact, and sent byte for byte as signed.
jq -cnj \
  --arg repo "$REPO" --arg kind "$KIND" --arg bynk_version "$BYNK_VERSION" \
  --arg result "$RESULT" --arg commit "$COMMIT_SHA" --arg run_url "$RUN_URL" \
  --arg finished_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{repo: $repo, kind: $kind, bynk_version: $bynk_version, result: $result,
    commit: $commit, run_url: $run_url, finished_at: $finished_at}' \
  > "$tmp/body.json"

# Bynk's Signature actor with a `timestamp` header verifies HMAC-SHA256, keyed
# by the secret's UTF-8 bytes, over the string "<X-Timestamp>.<raw body>", and
# accepts a bare hex digest in the signature header. See REPORTING.md.
ts="$(date +%s)"
sig="$( { printf '%s.' "$ts"; cat "$tmp/body.json"; } \
  | openssl dgst -sha256 -hmac "$REPORT_KEY" -binary | od -An -v -tx1 | tr -d ' \n')"

if "$CURL" --silent --show-error --fail-with-body --max-time 30 \
     --retry 2 \
     -X POST "$REPORT_URL" \
     -H "Content-Type: application/json" \
     -H "X-Timestamp: ${ts}" \
     -H "X-Signature: ${sig}" \
     --data-binary "@$tmp/body.json" \
     -o "$tmp/response" 2>"$tmp/error"; then
  echo "Reported ${RESULT} for ${REPO} with Bynk ${BYNK_VERSION}"
else
  # The error and response are the receiver's, never the key or signature.
  echo "::warning::canary report to the compat board failed: $(tr '\n' ' ' <"$tmp/error") $(head -c 500 "$tmp/response" 2>/dev/null | tr '\n' ' ')"
fi
