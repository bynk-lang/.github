#!/usr/bin/env bash
# bump.sh — propose moving a repository's Bynk pin to a release the canary
# just passed. Run from the root of a checkout of the default branch.
#
#   bump.sh apply <tag>   edit the pins, if <tag> is a final release newer
#                         than BYNK_VERSION; writes step outputs changed
#                         (true/false), from and to
#   bump.sh propose       commit the edits to canary/bynk-<to>, push it, open
#                         a pull request onto BASE (or leave the open one,
#                         now updated), close any bump pull request for an
#                         older release, and optionally enable auto-merge
#
# The pin is the BYNK_VERSION file at the root: one exact version, such as
# v0.404.0, that every workflow reads (setup-bynk, bynk-ci and bynk-deploy
# take it as version-file). A version that can't come from that file, in a
# README sample or a book's metadata say, sits on a line that also says
# `bynk-pin`; apply rewrites the first version on each such line, and leaves
# every other version alone.
#
# Environment for propose:
#   REPO         owner/name (required)
#   BASE         the branch to open the pull request onto (required)
#   FROM, TO     the versions apply wrote (required)
#   RUN_URL      the canary run (required)
#   BOT_NAME     the commit author's name, the App's bot (required)
#   BOT_EMAIL    the commit author's email (required)
#   AUTO_MERGE   true to enable auto-merge on the pull request (default false)
#   GH           the `gh` command to call (default: gh); tests point it at a fake
#
# GitHub is called through REST (and GraphQL for auto-merge) with `gh api`;
# the branch is pushed with git, to the checkout's origin.
set -euo pipefail

GH="${GH:-gh}"
PIN=BYNK_VERSION
MARKER=bynk-pin
PREFIX=canary/bynk-

die() { echo "::error::canary bump: $*" >&2; exit 1; }
api() { "$GH" api "$@"; }
out() { echo "$1=$2" >>"${GITHUB_OUTPUT:?}"; }

semver='[0-9]+\.[0-9]+\.[0-9]+'

# Files other than the pin with a marked line, tracked by git.
marked_files() {
  git grep -lI -e "$MARKER" -- . ":(exclude)$PIN" 2>/dev/null || true
}

cmd_apply() {
  local tag="${1:?usage: bump.sh apply <tag>}" pinned bare newest file
  out changed false
  bare="${tag#v}"
  if ! [[ "$bare" =~ ^${semver}$ ]]; then
    echo "::notice::Bynk ${tag} is not a final release; the pin only moves to one"
    return 0
  fi
  if [ ! -f "$PIN" ]; then
    echo "::warning::bump is on, but there is no ${PIN} file to move to ${tag}. Add one holding the current pin (see canary/README.md)."
    return 0
  fi
  pinned="$(tr -d '[:space:]' <"$PIN")"
  [[ "${pinned#v}" =~ ^${semver}([-+][0-9A-Za-z.-]+)?$ ]] \
    || die "${PIN} must hold an exact version, not '${pinned}'"
  newest="$(printf '%s\n%s\n' "${pinned#v}" "$bare" | sort -V | tail -n1)"
  if [ "${pinned#v}" = "$bare" ] || [ "$newest" != "$bare" ]; then
    echo "::notice::${PIN} is ${pinned}; Bynk ${bare} is not newer"
    return 0
  fi

  # Keep the file's own form: a leading v stays, and so does its absence.
  case "$pinned" in v*) echo "v${bare}" ;; *) echo "$bare" ;; esac >"$PIN"
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    sed -E -i.bak "/${MARKER}/ s/(v?)${semver}(-[0-9A-Za-z.]+)?/\\1${bare}/" "$file"
    rm -f "${file}.bak"
  done < <(marked_files)

  out changed true
  out from "${pinned#v}"
  out to "$bare"
  echo "Moving ${PIN} from ${pinned#v} to ${bare}"
}

cmd_propose() {
  : "${REPO:?}" "${BASE:?}" "${FROM:?}" "${TO:?}" "${RUN_URL:?}" "${BOT_NAME:?}" "${BOT_EMAIL:?}"
  local branch="${PREFIX}v${TO}" title files number url node created marked=()
  title="Move to Bynk ${TO}"

  files="$(git status --porcelain --untracked-files=no | wc -l | tr -d ' ')"
  [ "$files" -gt 0 ] || die "nothing to commit; run apply first"
  mapfile -t marked < <(git diff --name-only -- . ":(exclude)$PIN")

  git switch -q -c "$branch"
  git add -- "$PIN" ${marked[@]+"${marked[@]}"}
  git -c user.name="$BOT_NAME" -c user.email="$BOT_EMAIL" \
    commit -q -m "$title" -m "The Bynk canary passed with ${TO}: ${RUN_URL}"
  git push -q --force origin "$branch"

  # Open bump pull requests, as "<number> <branch>" lines.
  local open
  open="$(api -X GET "repos/${REPO}/pulls" -f state=open -f per_page=100 \
    --jq ".[] | select(.head.ref | startswith(\"${PREFIX}\")) | \"\(.number) \(.head.ref)\"")"

  number="$(awk -v b="$branch" '$2 == b { print $1; exit }' <<<"$open")"
  if [ -n "$number" ]; then
    echo "Updated the open pull request #${number}"
  else
    local body list deploys=""
    list="- \`${PIN}\`: ${FROM} → ${TO}"
    for f in ${marked[@]+"${marked[@]}"}; do
      list+=$'\n'"- \`${f}\`: the lines marked \`${MARKER}\`"
    done
    if ls .github/workflows/deploy.y*ml >/dev/null 2>&1; then
      deploys=$'\n\n'"Merging this deploys it with Bynk ${TO}."
    fi
    body="The [Bynk canary](${RUN_URL}) passed with [Bynk ${TO}](https://github.com/bynk-lang/bynk/releases/tag/v${TO}), so this moves the pin to it:

${list}

This pull request's own checks run at ${TO}.${deploys}

A newer release that passes replaces this pull request with its own."
    created="$(api -X POST "repos/${REPO}/pulls" \
      -f title="$title" -f head="$branch" -f base="$BASE" -f body="$body" \
      --jq '"\(.number) \(.html_url) \(.node_id)"')"
    read -r number url node <<<"$created"
    echo "::notice::Opened ${url}"
    if [ "${AUTO_MERGE:-false}" = true ]; then
      # Needs "Allow auto-merge" in the repository's settings; without it,
      # the pull request waits for a person, which is the safe failure.
      # shellcheck disable=SC2016 # $id is GraphQL's variable, not the shell's
      if api graphql -f query='mutation($id: ID!) { enablePullRequestAutoMerge(input: {pullRequestId: $id}) { clientMutationId } }' \
          -f id="$node" >/dev/null; then
        echo "Auto-merge is on for #${number}"
      else
        echo "::warning::Could not turn on auto-merge for #${number}; is \"Allow auto-merge\" set in the repository's settings?"
      fi
    fi
  fi
  out number "$number"

  # One bump open at a time: this one supersedes any for an older release.
  while read -r n ref; do
    [ -n "$n" ] && [ "$ref" != "$branch" ] || continue
    api -X POST "repos/${REPO}/issues/${n}/comments" -f body="Superseded by #${number}, the move to Bynk ${TO}." >/dev/null
    api -X PATCH "repos/${REPO}/pulls/${n}" -f state=closed >/dev/null
    api -X DELETE "repos/${REPO}/git/refs/heads/${ref}" >/dev/null || true
    echo "Closed #${n} (${ref}), superseded"
  done <<<"$open"
}

case "${1:-}" in
  apply) shift; cmd_apply "$@" ;;
  propose) cmd_propose ;;
  *) die "usage: bump.sh apply <tag> | bump.sh propose" ;;
esac
