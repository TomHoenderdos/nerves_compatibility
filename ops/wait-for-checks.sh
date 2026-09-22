#!/usr/bin/env bash
# Gate production on all security workflows for the exact main push being
# deployed. Never use a PR run, an older commit or a missing check as success.
set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_SHA:?}"
: "${GITHUB_OUTPUT:?}"

deadline=$((SECONDS + 1200))
while (( SECONDS < deadline )); do
  latest=$(gh api "repos/$GITHUB_REPOSITORY/commits/main" --jq .sha)
  if [[ "$latest" != "$GITHUB_SHA" ]]; then
    echo 'A newer commit is on main; skipping this superseded deployment.'
    echo 'deploy=false' >> "$GITHUB_OUTPUT"
    exit 0
  fi

  ready=true
  for workflow in audit.yml codeql.yml credo.yml sobelow.yml; do
    result=$(gh api --method GET \
      "repos/$GITHUB_REPOSITORY/actions/workflows/$workflow/runs" \
      -f head_sha="$GITHUB_SHA" -f branch=main -f event=push -f per_page=20)
    run=$(jq -c --arg sha "$GITHUB_SHA" --arg repo "$GITHUB_REPOSITORY" \
      '[.workflow_runs[] | select(.head_sha == $sha and .head_repository.full_name == $repo)]
       | sort_by(.id) | last' <<< "$result")
    status=$(jq -r '.status // "missing"' <<< "$run")
    conclusion=$(jq -r '.conclusion // "pending"' <<< "$run")
    echo "$workflow: $status ($conclusion)"

    if [[ "$status" != completed ]]; then
      ready=false
    elif [[ "$conclusion" != success ]]; then
      echo "::error::$workflow did not pass for $GITHUB_SHA"
      exit 1
    fi
  done

  if [[ "$ready" == true ]]; then
    echo 'deploy=true' >> "$GITHUB_OUTPUT"
    exit 0
  fi
  sleep 15
done

echo "::error::Timed out waiting for security checks for $GITHUB_SHA"
exit 1
