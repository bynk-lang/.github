#!/usr/bin/env bash
# dispatch.sh — the central canary dispatcher's two steps.
#
# Subcommands:
#   resolve   Turn REQUESTED ("latest", "0.303.4" or "v0.303.4") into one exact
#             release version of BYNK_REPOSITORY, bare ("0.303.4"), checking that
#             the release exists. Writes `version` to GITHUB_OUTPUT.
#   send      Send `repository_dispatch` (type bynk-canary, client_payload
#             {version, reason}) to every registry entry, or to those named in
#             FILTER. A failed dispatch is recorded and the rest continue; the
#             results go to the job summary, and the exit status is 1 if any
#             dispatch failed.
#
# Environment:
#   resolve: REQUESTED, BYNK_REPOSITORY (default accuser/bynk)
#   send:    VERSION, REASON, REGISTRY (default canary/repos.json),
#            FILTER (optional; repos separated by commas and/or whitespace)
#   both:    GH (the `gh` command, default gh); tests point it at a fake
set -euo pipefail

GH="${GH:-gh}"

die() { echo "::error::canary dispatch: $*" >&2; exit 1; }

summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then cat >>"$GITHUB_STEP_SUMMARY"; else cat >/dev/null; fi; }

cmd_resolve() {
  local repo="${BYNK_REPOSITORY:-accuser/bynk}" want="${REQUESTED:-latest}" tag
  [ -n "$want" ] || want=latest
  if [ "$want" = latest ]; then
    tag="$("$GH" api "repos/${repo}/releases/latest" --jq .tag_name)" \
      || die "could not resolve the latest release of ${repo}"
  else
    [[ "$want" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+([-+][0-9A-Za-z.+-]+)?$ ]] \
      || die "'${want}' is not 'latest' or a version like 0.303.4"
    tag="v${want#v}"
    "$GH" api "repos/${repo}/releases/tags/${tag}" --silent \
      || die "${repo} has no release ${tag}"
  fi
  local version="${tag#v}"
  echo "version=${version}" >>"${GITHUB_OUTPUT:?}"
  echo "Bynk ${want} → ${version}"
}

cmd_send() {
  local registry="${REGISTRY:-canary/repos.json}"
  : "${VERSION:?}" "${REASON:?}"
  [ -f "$registry" ] || die "no registry at ${registry}"

  local -a known targets
  mapfile -t known < <(jq -r '.repos[].repo' "$registry")

  if [ -n "${FILTER:-}" ]; then
    IFS=$', \t\n' read -r -d '' -a targets <<<"$FILTER" || true
  else
    targets=("${known[@]}")
  fi

  {
    echo "### Canary dispatch: Bynk ${VERSION}"
    echo
    echo "Reason: ${REASON}"
    echo
  } | summary

  if [ "${#targets[@]}" -eq 0 ]; then
    echo "No repositories to dispatch to." | summary
    echo "No repositories to dispatch to"
    return 0
  fi

  local body
  body="$(jq -cn --arg version "$VERSION" --arg reason "$REASON" \
    '{event_type: "bynk-canary", client_payload: {version: $version, reason: $reason}}')"

  local failed=0 repo out
  printf '| Repository | Dispatch |\n| --- | --- |\n' | summary
  for repo in "${targets[@]}"; do
    if ! printf '%s\n' "${known[@]}" | grep -qxF -- "$repo"; then
      echo "::error::${repo} is not in ${registry}"
      echo "| ${repo} | ❌ not in the registry |" | summary
      failed=$((failed + 1))
      continue
    fi
    if out="$("$GH" api -X POST "repos/${repo}/dispatches" --input - <<<"$body" 2>&1)"; then
      echo "Dispatched to ${repo}"
      echo "| [${repo}](https://github.com/${repo}/actions) | ✅ sent |" | summary
    else
      out="$(tr '\n' ' ' <<<"$out")"
      echo "::error::dispatch to ${repo} failed: ${out}"
      echo "| ${repo} | ❌ ${out//|/\\|} |" | summary
      failed=$((failed + 1))
    fi
  done

  if [ "$failed" -gt 0 ]; then
    printf '\n%d of %d dispatches failed.\n' "$failed" "${#targets[@]}" | summary
    die "${failed} of ${#targets[@]} dispatches failed"
  fi
}

case "${1:-}" in
  resolve) cmd_resolve ;;
  send)    cmd_send ;;
  *) die "unknown subcommand: ${1:-<none>}" ;;
esac
