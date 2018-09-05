#!/usr/bin/env bash

set -e -o pipefail

GIT_URL="$1"
GIT_BRANCH="$2"
GIT_DIR="$3"

if [ -z "$GIT_URL" ] || [ -z "$GIT_BRANCH" ] || [ -z "$GIT_DIR" ]; then
  ( >&2 echo "Usage: $0 <git url> <git branch> <target directory>" )
  exit 1
fi

function update() {
  git -C "$GIT_DIR" status &> /dev/null && {
    # Ensure remote is set up
    local remote=''
    git -C "$GIT_DIR" remote | while read remote; do
      if [[ "$(git -C "$GIT_DIR" remote get-url "$remote")" == "$GIT_URL" ]]; then
        break
      fi
      unset remote
    done
    if [[ -z "$remote" ]]; then
      remote="$(echo "${GIT_URL}§${GIT_BRANCH}§${GIT_DIR}" | md5sum | egrep -o '[a-fA-F0-9]{32}')"
      git -C "$GIT_DIR" remote add "$remote" "$GIT_URL"
    fi
    # Try ff first
  } && \
  git -C "$GIT_DIR" fetch --all && git -C "$GIT_DIR" checkout "$GIT_BRANCH" && git -C "$GIT_DIR" pull "$remote" "$GIT_BRANCH" --ff-only || {
    # Kill it with fire
    echo "Fast-Forward failed, killing it with fire"
    rm -rf "$GIT_DIR"
    git clone "$GIT_URL" -b "$GIT_BRANCH" "$GIT_DIR"
    echo updated
  }
}

(
  if ! [[ -e "$GIT_DIR" ]]; then
    echo "git dir nonexistent, updating"
    update
    exit 0
  fi

  REMOTE_REFS="$(git ls-remote -qht "$GIT_URL" | grep "$GIT_BRANCH" | cut -f1)"

  set +e
  LOCAL_REF=$(git -C "$GIT_DIR" rev-parse HEAD)
  GIT_EXIT=$?
  set -e

  if [[ $GIT_EXIT -ne 0 ]]; then
    echo "Local repo damaged, forcing update"
    update
    exit 0
  fi

  # There can be multiple objects describing the same state, we need to check them all
  for ref in $REMOTE_REFS; do
    echo "Checking $ref == $LOCAL_REF"
    if [[ "$ref" == "$LOCAL_REF" ]]; then
      echo "Local repo is up to date"
      exit 0
    fi
  done

  echo "Local state does not reflect latest remote state, updating"
  update
)
