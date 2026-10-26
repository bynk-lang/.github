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
  unset FAKE_ISSUES FAKE_LABEL FAKE_LATEST FAKE_RELEASES FAKE_FAIL_REPOS FAKE_PULLS FAKE_AUTOMERGE_FAIL FAKE_COMPARE FILTER
  unset ACTIONS_ID_TOKEN_REQUEST_URL ACTIONS_ID_TOKEN_REQUEST_TOKEN BOARD_URL FAKE_TOKEN FAKE_TOKEN_FAIL FAKE_CURL_FAIL
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
token_env() {
  export ACTIONS_ID_TOKEN_REQUEST_URL="https://token.test/request?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN="req-token"
}

t "without an OIDC token nothing is reported, even with the old report secrets"
FAKE_CURL_DIR="$work"
REPORT_URL="https://board.test/runs" REPORT_KEY=k report; status $? 0
[ ! -e "$work/url" ] || nope "posted without a token"
[ ! -e "$work/token_url" ] || nope "asked for a token without the token environment"
[ ! -s "$work/stdout" ] || nope "printed: $(cat "$work/stdout")"
ok

t "the body is the contract's seven fields, compact, with nothing after it"
FAKE_CURL_DIR="$work"
token_env; report; status $? 0
jq -e '
  .repo == "bynk-lang/example" and .kind == "example" and .bynk_version == "0.303.4"
  and .result == "pass" and .commit == "abc123"
  and .run_url == "https://github.com/bynk-lang/example/actions/runs/1"
  and (.finished_at | test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (keys | length == 7)' "$work/body" >/dev/null || nope "unexpected payload: $(cat "$work/body")"
[ "$(tail -c1 "$work/body" | od -An -c | tr -d ' ')" = "}" ] || nope "the body has trailing bytes"
grep -qx "Content-Type: application/json" "$work/headers" || nope "no JSON content type"
ok

t "the report goes to /v2/runs with the run's OIDC token"
FAKE_CURL_DIR="$work"
ACTIONS_ID_TOKEN_REQUEST_URL="https://token.test/request?api-version=2.0" ACTIONS_ID_TOKEN_REQUEST_TOKEN="req-token" \
  BOARD_URL="https://board.test/" report; status $? 0
grep -qxF "https://token.test/request?api-version=2.0&audience=https%3A%2F%2Fboard.test" "$work/token_url" || nope "token URL: $(cat "$work/token_url" 2>/dev/null)"
grep -qxF "Authorization: bearer req-token" "$work/token_headers" || nope "token request headers: $(cat "$work/token_headers" 2>/dev/null)"
[ "$(cat "$work/url")" = "https://board.test/v2/runs" ] || nope "posted to $(cat "$work/url")"
grep -qxF "Authorization: Bearer fake.oidc.token" "$work/headers" || nope "report headers: $(cat "$work/headers")"
jq -e '.repo == "bynk-lang/example" and .result == "pass"' "$work/body" >/dev/null || nope "body: $(cat "$work/body")"
grep -qxF "::add-mask::fake.oidc.token" "$work/stdout" || nope "the token was not masked"
grep -q "(oidc)" "$work/stdout" || nope "the log doesn't say which path: $(cat "$work/stdout")"
ok

t "without a board URL, OIDC reports to the compat board, with its URL as the audience"
FAKE_CURL_DIR="$work"
ACTIONS_ID_TOKEN_REQUEST_URL="https://token.test/request?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN="req-token" report; status $? 0
grep -qxF "https://token.test/request?x=1&audience=https%3A%2F%2Fcompat-board.bynk-lang.workers.dev" "$work/token_url" || nope "token URL: $(cat "$work/token_url" 2>/dev/null)"
[ "$(cat "$work/url")" = "https://compat-board.bynk-lang.workers.dev/v2/runs" ] || nope "posted to $(cat "$work/url")"
ok

t "a failed token request is a warning, and nothing is posted"
FAKE_CURL_DIR="$work"
FAKE_TOKEN_FAIL=1 ACTIONS_ID_TOKEN_REQUEST_URL="https://token.test/r?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN="t" report; status $? 0
grep -q "^::warning::canary report to the compat board failed: could not mint an OIDC token" "$work/stdout" || nope "no warning: $(cat "$work/stdout")"
[ ! -e "$work/url" ] || nope "posted anyway"
ok

t "a board refusing an OIDC report is a warning, not a failure"
FAKE_CURL_DIR="$work"
FAKE_CURL_FAIL=1 ACTIONS_ID_TOKEN_REQUEST_URL="https://token.test/r?x=1" ACTIONS_ID_TOKEN_REQUEST_TOKEN="t" report; status $? 0
grep -q "^::warning::canary report" "$work/stdout" || nope "no warning: $(cat "$work/stdout")"
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

# --- bump.sh ----------------------------------------------------------------

# A checkout of a repository whose origin is a local bare repository, so a
# push can be inspected. <pin> is BYNK_VERSION's content; "" for no file.
checkout() {
  git init -q --bare "$work/origin.git"
  git init -q -b main "$work/repo"
  (
    cd "$work/repo" || exit
    git config user.name t && git config user.email t@t
    if [ -n "$1" ]; then printf '%s\n' "$1" >BYNK_VERSION; fi
    mkdir -p .github/workflows docs
    printf 'version: 0.300.0   # bynk-pin\nfloor: 0.290.0\n' >docs/usage.md
    printf 'bynk-version: "v0.300.0", // bynk-pin\n' >metadata.typ
    printf 'name: CI\n' >.github/workflows/ci.yml
    git add -A && git commit -qm init
    git remote add origin "$work/origin.git" && git push -q origin main
  )
}
apply()   { (cd "$work/repo" && "$scripts/bump.sh" apply "$1") >"$work/stdout" 2>&1; }
propose() {
  (cd "$work/repo" && REPO=o/r BASE=main FROM="$1" TO="$2" RUN_URL=https://run/1 \
    BOT_NAME="bump[bot]" BOT_EMAIL="1+bump[bot]@users.noreply.github.com" \
    "$scripts/bump.sh" propose) >"$work/stdout" 2>&1
}
pinned() { tr -d '[:space:]' <"$work/repo/BYNK_VERSION"; }

t "a newer final release moves BYNK_VERSION, keeping its v"
checkout v0.300.0
apply v0.305.0; status $? 0
[ "$(pinned)" = v0.305.0 ] || nope "BYNK_VERSION is $(pinned)"
out "changed=true"; out "from=0.300.0"; out "to=0.305.0"
ok

t "a bare BYNK_VERSION stays bare"
checkout 0.300.0
apply 0.305.0; status $? 0
[ "$(pinned)" = 0.305.0 ] || nope "BYNK_VERSION is $(pinned)"
ok

t "marked lines move with it, and unmarked versions stay"
checkout v0.300.0
apply v0.305.0; status $? 0
grep -qx 'version: 0.305.0   # bynk-pin' "$work/repo/docs/usage.md" || nope "usage.md: $(cat "$work/repo/docs/usage.md")"
grep -qx 'floor: 0.290.0' "$work/repo/docs/usage.md" || nope "the unmarked floor moved"
grep -qx 'bynk-version: "v0.305.0", // bynk-pin' "$work/repo/metadata.typ" || nope "metadata.typ: $(cat "$work/repo/metadata.typ")"
ok

t "the same release, an older one, or a pre-release changes nothing"
checkout v0.300.0
for tag in v0.300.0 0.299.9 v0.310.0-rc1; do
  : >"$GITHUB_OUTPUT"
  apply "$tag"; status $? 0
  out "changed=false"
done
[ "$(pinned)" = v0.300.0 ] || nope "BYNK_VERSION is $(pinned)"
[ -z "$(git -C "$work/repo" status --porcelain)" ] || nope "the tree changed"
ok

t "versions compare as versions, not strings"
checkout v0.99.0
apply v0.100.0; status $? 0
out "changed=true"
ok

t "no BYNK_VERSION warns and changes nothing"
checkout ""
apply v0.305.0; status $? 0
out "changed=false"
grep -q "^::warning::bump is on, but there is no BYNK_VERSION" "$work/stdout" || nope "no warning: $(cat "$work/stdout")"
ok

t "a BYNK_VERSION that is not a version fails"
checkout latest
apply v0.305.0; status $? 1
ok

t "propose pushes the branch and opens the pull request"
checkout v0.300.0
apply v0.305.0 && propose 0.300.0 0.305.0; status $? 0
[ "$(git -C "$work/origin.git" show canary/bynk-v0.305.0:BYNK_VERSION)" = v0.305.0 ] || nope "the pushed branch has no bump"
git -C "$work/origin.git" log -1 --format='%an %s' canary/bynk-v0.305.0 | grep -qx 'bump\[bot\] Move to Bynk 0.305.0' || nope "commit: $(git -C "$work/origin.git" log -1 --format='%an %s' canary/bynk-v0.305.0)"
called "-X GET repos/o/r/pulls -f state=open"
called "-X POST repos/o/r/pulls -f title=Move to Bynk 0.305.0 -f head=canary/bynk-v0.305.0 -f base=main"
called "\`BYNK_VERSION\`: 0.300.0 → 0.305.0"
called "\`docs/usage.md\`: the lines marked \`bynk-pin\`"
not_called "Merging this deploys it"
not_called "graphql"
out "number=12"
ok

t "a repository that deploys says so"
checkout v0.300.0
printf 'name: Deploy\n' >"$work/repo/.github/workflows/deploy.yml"
git -C "$work/repo" add -A && git -C "$work/repo" commit -qm deploy
apply v0.305.0 && propose 0.300.0 0.305.0; status $? 0
called "Merging this deploys it with Bynk 0.305.0."
ok

t "an open pull request for the same release is updated, not duplicated"
checkout v0.300.0
apply v0.305.0 && FAKE_PULLS='[{"number":7,"head":{"ref":"canary/bynk-v0.305.0"}}]' propose 0.300.0 0.305.0; status $? 0
not_called "-X POST repos/o/r/pulls"
not_called "-X PATCH"
out "number=7"
ok

t "a bump for an older release is closed as superseded; other pull requests are not"
checkout v0.300.0
apply v0.305.0 && FAKE_PULLS='[{"number":5,"head":{"ref":"canary/bynk-v0.303.0"}},{"number":6,"head":{"ref":"feature"}}]' \
  propose 0.300.0 0.305.0; status $? 0
called "-X POST repos/o/r/issues/5/comments -f body=Superseded by #12, the move to Bynk 0.305.0."
called "-X PATCH repos/o/r/pulls/5 -f state=closed"
called "-X DELETE repos/o/r/git/refs/heads/canary/bynk-v0.303.0"
not_called "pulls/6"
ok

t "auto-merge is turned on when asked"
checkout v0.300.0
apply v0.305.0 && AUTO_MERGE=true propose 0.300.0 0.305.0; status $? 0
called "graphql -f query=mutation"
called "-f id=PR_node12"
ok

t "auto-merge that the repository refuses is a warning, not a failure"
checkout v0.300.0
apply v0.305.0 && FAKE_AUTOMERGE_FAIL=1 AUTO_MERGE=true propose 0.300.0 0.305.0; status $? 0
grep -q '^::warning::Could not turn on auto-merge' "$work/stdout" || nope "no warning: $(cat "$work/stdout")"
ok

t "a bump branch someone else pushed to is left alone"
checkout v0.300.0
apply v0.305.0 && propose 0.300.0 0.305.0; status $? 0
tip="$(git -C "$work/origin.git" rev-parse canary/bynk-v0.305.0)"
: >"$FAKE_GH_LOG"; : >"$GITHUB_OUTPUT"
git -C "$work/repo" switch -q main && git -C "$work/repo" branch -q -D canary/bynk-v0.305.0
apply v0.305.0 && FAKE_COMPARE='{"commits":[{"author":{"login":"bump[bot]"}},{"author":{"login":"alice"}}]}' \
  propose 0.300.0 0.305.0; status $? 0
[ "$(git -C "$work/origin.git" rev-parse canary/bynk-v0.305.0)" = "$tip" ] || nope "the branch was pushed over"
called "-X GET repos/o/r/compare/main...canary/bynk-v0.305.0"
grep -q '^::notice::canary/bynk-v0.305.0 has commits by alice' "$work/stdout" || nope "no notice: $(cat "$work/stdout")"
not_called "-X POST repos/o/r/pulls"
not_called "repos/o/r/pulls -f state=open"
ok

t "a bump branch with only the bot's commits is updated"
checkout v0.300.0
apply v0.305.0 && propose 0.300.0 0.305.0; status $? 0
: >"$FAKE_GH_LOG"
git -C "$work/repo" switch -q main && git -C "$work/repo" branch -q -D canary/bynk-v0.305.0
git -C "$work/repo" checkout -q -- . && git -C "$work/repo" commit -q --allow-empty -m "main moved on"
apply v0.305.0 && FAKE_COMPARE='{"commits":[{"author":{"login":"bump[bot]"}}]}' \
  FAKE_PULLS='[{"number":7,"head":{"ref":"canary/bynk-v0.305.0"}}]' propose 0.300.0 0.305.0; status $? 0
[ "$(git -C "$work/origin.git" rev-parse canary/bynk-v0.305.0^)" = "$(git -C "$work/repo" rev-parse main)" ] || nope "the branch was not rebuilt on main"
out "number=7"
ok

t "a commit with no GitHub user counts by its author name"
checkout v0.300.0
apply v0.305.0 && propose 0.300.0 0.305.0; status $? 0
git -C "$work/repo" switch -q main && git -C "$work/repo" branch -q -D canary/bynk-v0.305.0
apply v0.305.0 && FAKE_COMPARE='{"commits":[{"author":null,"commit":{"author":{"name":"Someone"}}}]}' \
  propose 0.300.0 0.305.0; status $? 0
grep -q 'has commits by Someone' "$work/stdout" || nope "no notice: $(cat "$work/stdout")"
ok

t "propose with nothing applied fails"
checkout v0.300.0
propose 0.300.0 0.305.0; status $? 1
ok

# --- the real registry ------------------------------------------------------

t "the dispatcher reads the committed registry"
REGISTRY="$here/../repos.json" send; status $? 0
calls "/dispatches" "$(jq '.repos | length' "$here/../repos.json")"
ok

echo
echo "${pass} passed, ${fail} failed checks"
[ "$fail" -eq 0 ]
