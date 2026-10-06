#!/usr/bin/env bash
# run.sh — unit tests for canary/scripts, with GitHub and the compat board
# replaced by the fakes in canary/test/bin. Needs bash, jq, openssl and node.
#
#   canary/test/run.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
scripts="$(cd "$here/../scripts" && pwd)"
export PATH="$here/bin:$PATH"
export GH="$here/bin/gh"

pass=0 fail=0 current="" failed_before=0

# A test passes if none of its checks called `nope`.
ok()   { if [ "$fail" -eq "$failed_before" ]; then pass=$((pass + 1)); echo "  ✓ ${current}"; fi; }
nope() { fail=$((fail + 1)); echo "  ✗ ${current}: $*"; }

# Each test runs in a fresh temp dir with a fresh call log.
t() {
  current="$1" failed_before="$fail"
  work="$(mktemp -d)"
  export FAKE_GH_LOG="$work/gh.log" GITHUB_OUTPUT="$work/output" GITHUB_STEP_SUMMARY="$work/summary"
  : >"$FAKE_GH_LOG"
  unset FAKE_ISSUES FAKE_LABEL FAKE_LATEST FAKE_RELEASES FAKE_FAIL_REPOS FILTER
}

called()     { grep -qF -- "$1" "$FAKE_GH_LOG" || nope "expected a call matching '$1'"; }
not_called() { if grep -qF -- "$1" "$FAKE_GH_LOG"; then nope "unexpected call matching '$1'"; fi; }
calls()      { local n; n="$(grep -cF -- "$1" "$FAKE_GH_LOG" || true)"; [ "$n" = "$2" ] || nope "expected $2 calls matching '$1', got $n"; }
status()     { [ "$1" = "$2" ] || nope "exit status $1, expected $2"; }

# --- issue.sh ---------------------------------------------------------------

export REPO=bynk-lang/example BYNK_VERSION=0.303.4 COMMIT_SHA=abc123 RUN_URL=https://github.com/bynk-lang/example/actions/runs/1

issue() { "$scripts/issue.sh" "$@" >"$work/stdout" 2>&1; }

t "fail with no open issue opens one"
issue fail; status $? 0
called "-X GET repos/bynk-lang/example/issues -f labels=canary -f state=open"
called "-X POST repos/bynk-lang/example/issues -f title=Canary: fails with Bynk 0.303.4"
called "labels[]=canary"
not_called "-X POST repos/bynk-lang/example/labels"
not_called "/comments"
ok

t "fail with no open issue and no label creates the label first"
FAKE_LABEL=0 issue fail; status $? 0
called "-X POST repos/bynk-lang/example/labels -f name=canary"
called "-X POST repos/bynk-lang/example/issues -f title=Canary: fails with Bynk 0.303.4"
ok

t "fail with an open issue comments instead of opening another"
FAKE_ISSUES='[{"number":7}]' issue fail; status $? 0
called "-X POST repos/bynk-lang/example/issues/7/comments"
called "fail with Bynk **0.303.4**"
not_called "-f title="
not_called "-X PATCH"
ok

t "fail with several open issues comments on the newest only"
FAKE_ISSUES='[{"number":9},{"number":7}]' issue fail; status $? 0
calls "/comments" 1
called "issues/9/comments"
ok

t "a pull request labelled canary is not an issue"
FAKE_ISSUES='[{"number":5,"pull_request":{"url":"x"}}]' issue fail; status $? 0
not_called "issues/5/comments"
called "-f title=Canary: fails with Bynk 0.303.4"
ok

t "pass with open issues comments on and closes each"
FAKE_ISSUES='[{"number":9},{"number":7}]' issue pass; status $? 0
called "issues/9/comments -f body=The canary passes again with Bynk **0.303.4**"
called "-X PATCH repos/bynk-lang/example/issues/9 -f state=closed"
called "issues/7/comments"
called "-X PATCH repos/bynk-lang/example/issues/7 -f state=closed"
ok

t "pass with no open issue does nothing"
issue pass; status $? 0
calls "api" 1
not_called "-X POST"
not_called "-X PATCH"
ok

t "an unknown result is refused"
issue maybe; status $? 1
calls "api" 0
ok

# --- report.sh --------------------------------------------------------------

export KIND=example RESULT=pass FAKE_CURL_DIR
report() { "$scripts/report.sh" >"$work/stdout" 2>&1; }

t "no report-url or report-key skips silently"
FAKE_CURL_DIR="$work"
REPORT_URL="" REPORT_KEY="" report; status $? 0
[ ! -e "$work/body" ] || nope "curl was called"
[ ! -s "$work/stdout" ] || nope "printed: $(cat "$work/stdout")"
REPORT_URL="https://board.test/runs" REPORT_KEY="" report; status $? 0
[ ! -e "$work/body" ] || nope "curl was called without a key"
ok

t "a report is signed the way a Bynk Signature actor verifies it"
FAKE_CURL_DIR="$work"
REPORT_URL="https://board.test/runs" REPORT_KEY='s3cr€t key' report; status $? 0
[ "$(cat "$work/url")" = "https://board.test/runs" ] || nope "posted to $(cat "$work/url")"
ts="$(sed -n 's/^X-Timestamp: //p' "$work/headers")"
sig="$(sed -n 's/^X-Signature: //p' "$work/headers")"
[[ "$ts" =~ ^[0-9]+$ ]] || nope "X-Timestamp '$ts' is not Unix seconds"
[[ "$sig" =~ ^[0-9a-f]{64}$ ]] || nope "X-Signature '$sig' is not 64 hex digits"
node "$here/verify-signature.mjs" 's3cr€t key' "$work/body" "$ts" "$sig" || nope "the receiver rejects the signature"
node "$here/verify-signature.mjs" 'wrong key' "$work/body" "$ts" "$sig" && nope "a wrong key verifies"
node "$here/verify-signature.mjs" 's3cr€t key' "$work/body" "$((ts - 301))" "$sig" && nope "a stale timestamp verifies"
jq -e --arg ts "$ts" '
  .repo == "bynk-lang/example" and .kind == "example" and .bynk_version == "0.303.4"
  and .result == "pass" and .commit == "abc123"
  and .run_url == "https://github.com/bynk-lang/example/actions/runs/1"
  and (.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (keys | length == 7)' "$work/body" >/dev/null || nope "unexpected payload: $(cat "$work/body")"
[ "$(tail -c1 "$work/body" | od -An -c | tr -d ' ')" = "}" ] || nope "the body has trailing bytes"
grep -qx "Content-Type: application/json" "$work/headers" || nope "no JSON content type"
ok

t "a failed report is a warning, not a failure"
FAKE_CURL_DIR="$work"
FAKE_CURL_FAIL=1 REPORT_URL="https://board.test/runs" REPORT_KEY=k report; status $? 0
grep -q '^::warning::canary report' "$work/stdout" || nope "no warning: $(cat "$work/stdout")"
grep -q "bad signature" "$work/stdout" || nope "the warning omits the receiver's answer"
ok

# --- dispatch.sh: resolve ---------------------------------------------------

resolve() { REQUESTED="$1" "$scripts/dispatch.sh" resolve >"$work/stdout" 2>&1; }
out() { grep -qx "$1" "$GITHUB_OUTPUT" || nope "expected output '$1', got '$(cat "$GITHUB_OUTPUT")'"; }

t "latest resolves to the newest release, bare"
FAKE_LATEST=v0.310.0 resolve latest; status $? 0
out "version=0.310.0"
ok

t "an empty request means latest"
resolve ""; status $? 0
out "version=0.303.4"
ok

t "an exact version is checked and normalised, with or without v"
FAKE_RELEASES="v0.290.0 v0.303.4" resolve 0.290.0; status $? 0
out "version=0.290.0"
ok

t "an exact version is checked and normalised, with or without v (v)"
resolve v0.303.4; status $? 0
out "version=0.303.4"
ok

t "a version with no release is refused"
resolve 9.9.9; status $? 1
grep -q "has no release v9.9.9" "$work/stdout" || nope "unclear error: $(cat "$work/stdout")"
ok

t "a malformed version is refused before any API call"
resolve '1.2; rm -rf /'; status $? 1
calls "api" 0
ok

# --- dispatch.sh: send ------------------------------------------------------

registry() { # repo...
  printf '%s\n' "$@" | jq -R . | jq -s '{repos: map({repo: ., kind: "example"})}' >"$work/repos.json"
  printf '{"repos": []}' >"$work/empty.json"
}
send() { VERSION=0.303.4 REASON="release v0.303.4" "$scripts/dispatch.sh" send >"$work/stdout" 2>&1; }

t "an empty registry dispatches nothing and succeeds"
registry
REGISTRY="$work/empty.json" send; status $? 0
calls "api" 0
grep -q "No repositories" "$GITHUB_STEP_SUMMARY" || nope "summary does not say so"
ok

t "every registry entry gets a bynk-canary dispatch with version and reason"
registry bynk-lang/a bynk-lang/b
REGISTRY="$work/repos.json" send; status $? 0
called '-X POST repos/bynk-lang/a/dispatches --input - <<< {"event_type":"bynk-canary","client_payload":{"version":"0.303.4","reason":"release v0.303.4"}}'
called "-X POST repos/bynk-lang/b/dispatches"
grep -qF "| [bynk-lang/b](https://github.com/bynk-lang/b/actions) | ✅ sent |" "$GITHUB_STEP_SUMMARY" || nope "summary: $(cat "$GITHUB_STEP_SUMMARY")"
ok

t "one failed dispatch does not stop the others, and fails the run at the end"
registry bynk-lang/a bynk-lang/b bynk-lang/c
FAKE_FAIL_REPOS=bynk-lang/b REGISTRY="$work/repos.json" send; status $? 1
called "repos/bynk-lang/a/dispatches"
called "repos/bynk-lang/b/dispatches"
called "repos/bynk-lang/c/dispatches"
grep -qF "| bynk-lang/b | ❌ gh: Not Found (HTTP 404)" "$GITHUB_STEP_SUMMARY" || nope "failure not in summary: $(cat "$GITHUB_STEP_SUMMARY")"
grep -qF "1 of 3 dispatches failed" "$GITHUB_STEP_SUMMARY" || nope "no tally in summary"
grep -q "^::error::dispatch to bynk-lang/b failed" "$work/stdout" || nope "no ::error:: for b"
ok

t "a filter dispatches only to the named repos"
registry bynk-lang/a bynk-lang/b bynk-lang/c
FILTER="bynk-lang/c, bynk-lang/a" REGISTRY="$work/repos.json" send; status $? 0
calls "/dispatches" 2
not_called "repos/bynk-lang/b/dispatches"
ok

t "a filter naming a repo outside the registry fails without dispatching to it"
registry bynk-lang/a
FILTER="bynk-lang/a bynk-lang/zzz" REGISTRY="$work/repos.json" send; status $? 1
called "repos/bynk-lang/a/dispatches"
not_called "bynk-lang/zzz"
grep -q "bynk-lang/zzz is not in" "$work/stdout" || nope "unclear error"
ok

# --- the real registry ------------------------------------------------------

t "the dispatcher reads the committed registry"
REGISTRY="$here/../repos.json" send; status $? 0
calls "/dispatches" "$(jq '.repos | length' "$here/../repos.json")"
ok

echo
echo "${pass} passed, ${fail} failed checks"
[ "$fail" -eq 0 ]
