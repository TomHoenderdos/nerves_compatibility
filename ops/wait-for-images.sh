#!/usr/bin/env bash
# Before CI's builder deploy, wait for the jobs of this same workflow run that
# push the commit's worker and toolchain images (deploy.yml's two manifest
# jobs). They start beside the deploy job, once `test` passes, so without this
# the builder could ask the registry for images not pushed yet.
#
# Never fails the deploy: a job that did not pass, or one still running at the
# deadline, is a warning, and the builder falls back for what it cannot pull
# (ops/builder-deploy.sh, builder_build_image).
set -euo pipefail

: "${GITHUB_REPOSITORY:?}"
: "${GITHUB_RUN_ID:?}"

timeout=${NCC_IMAGES_WAIT_SECONDS:-1200}
[[ $timeout =~ ^[0-9]+$ ]] || { echo "invalid NCC_IMAGES_WAIT_SECONDS: $timeout" >&2; exit 2; }

# deploy.yml's job names; ops/test_wait_for_images.py pins them to it.
names=('ncc-worker manifest list' 'toolchain manifest list')

deadline=$((SECONDS + timeout))
while true; do
  # The latest attempt of each job, so a rerun job counts, not its first try.
  result=$(gh api --method GET \
    "repos/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID/jobs" \
    -f filter=latest -f per_page=100) || result='{"jobs": []}'

  ready=true
  failed=()
  for name in "${names[@]}"; do
    # An answer jq cannot read counts as no job yet: this never fails the step.
    job=$(jq -c --arg name "$name" \
      '[.jobs[]? | select(.name == $name)] | sort_by(.id) | last' <<< "$result" 2>/dev/null) ||
      job=null
    status=$(jq -r '.status // "missing"' <<< "$job" 2>/dev/null) || status=missing
    conclusion=$(jq -r '.conclusion // "pending"' <<< "$job" 2>/dev/null) || conclusion=pending
    echo "$name: $status ($conclusion)"
    if [[ $status != completed ]]; then
      ready=false
    elif [[ $conclusion != success ]]; then
      failed+=("$name")
    fi
  done

  if [[ $ready == true ]]; then
    if [[ ${#failed[@]} -eq 0 ]]; then
      echo "the worker and toolchain images for ${GITHUB_SHA:-this commit} are pushed"
    else
      for name in "${failed[@]}"; do
        echo "::warning::$name did not pass; the builder falls back for its images"
      done
    fi
    exit 0
  fi

  if (( SECONDS >= deadline )); then
    echo "::warning::the image jobs had not finished after ${timeout}s; deploying the builder anyway, which falls back for any image not pushed yet"
    exit 0
  fi
  sleep 15
done
