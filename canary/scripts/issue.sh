#!/usr/bin/env bash
# issue.sh — keep one `canary` issue per break in the repository under test.
#
#   issue.sh pass|fail
#
# fail, no open canary issue  → create the `canary` label if missing, open
#                               "Canary: fails with Bynk <version>"
# fail, an open canary issue  → comment on it (one issue per break, not per run)
# pass, open canary issue(s)  → comment that it now passes, and close each
# pass, none open             → nothing
#
# Environment:
#   REPO           owner/name of the repository under test (required)
#   BYNK_VERSION   the Bynk version that was tested, e.g. 0.303.4 (required)
#   COMMIT_SHA     the commit that was tested (required)
#   RUN_URL        the workflow run URL (required)
#   GH             the `gh` command to call (default: gh); tests point it at a fake
#
# Only REST endpoints, through `gh api`.
set -euo pipefail

LABEL=canary
GH="${GH:-gh}"

die() { echo "::error::canary issue: $*" >&2; exit 1; }

api() { "$GH" api "$@"; }

# Open `canary` issues, newest first, one number per line. The issues endpoint
# also returns pull requests, which carry a `pull_request` key; drop them.
open_issues() {
  api -X GET "repos/${REPO}/issues" \
    -f labels="$LABEL" -f state=open -f sort=created -f direction=desc -f per_page=100 \
    --jq '.[] | select(.pull_request == null) | .number'
}

ensure_label() {
  if api "repos/${REPO}/labels/${LABEL}" --silent 2>/dev/null; then
    return 0
  fi
  # Missing (or unreadable): create it. If another run created it meanwhile,
  # the POST fails with 422 and the issue below still gets the label.
  api -X POST "repos/${REPO}/labels" \
    -f name="$LABEL" -f color=d73a4a \
    -f description="A new Bynk release broke this repository's checks" --silent \
    || echo "::warning::could not create the '${LABEL}' label; continuing"
}

comment() { # <number> <body>
  api -X POST "repos/${REPO}/issues/$1/comments" -f body="$2" --silent
}

main() {
  local result="${1:-}"
  case "$result" in pass|fail) ;; *) die "usage: issue.sh pass|fail (got '${result}')" ;; esac
  : "${REPO:?}" "${BYNK_VERSION:?}" "${COMMIT_SHA:?}" "${RUN_URL:?}"

  local issues
  issues="$(open_issues)"

  if [ "$result" = fail ]; then
    local body
    body="$(printf 'The canary checks fail with Bynk **%s**.\n\n- Commit: %s\n- Run: %s\n' \
      "$BYNK_VERSION" "$COMMIT_SHA" "$RUN_URL")"
    if [ -n "$issues" ]; then
      local n; n="$(head -n1 <<<"$issues")"
      comment "$n" "$body"
      echo "Commented on open canary issue #${n}"
    else
      ensure_label
      local n
      n="$(api -X POST "repos/${REPO}/issues" \
        -f title="Canary: fails with Bynk ${BYNK_VERSION}" \
        -f body="$body" -f "labels[]=${LABEL}" --jq .number)"
      echo "Opened canary issue #${n}"
    fi
    return 0
  fi

  if [ -z "$issues" ]; then
    echo "No open canary issue"
    return 0
  fi
  local n
  while read -r n; do
    comment "$n" "$(printf 'The canary passes again with Bynk **%s**.\n\n- Commit: %s\n- Run: %s\n' \
      "$BYNK_VERSION" "$COMMIT_SHA" "$RUN_URL")"
    api -X PATCH "repos/${REPO}/issues/${n}" -f state=closed -f state_reason=completed --silent
    echo "Closed canary issue #${n}"
  done <<<"$issues"
}

main "$@"
