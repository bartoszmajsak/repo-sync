#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -euo pipefail

# shellcheck disable=SC1091
source "${DIR}/func.sh"
dryRun=false

PULL_BASE_REF="${PULL_BASE_REF:-}"
if [[ -z $PULL_BASE_REF ]]; then
  die "Please provide PULL_BASE_REF environment variable in old_branch:new_branch format."
fi

previous_branch="${PULL_BASE_REF%:*}"
current_branch="${PULL_BASE_REF#*:}"
patchset_repo="${PATCHSET_REPO:-}" # required
patchset_dir="${PATCHSET_DIR:-patchset}"

gh_token="null"

while test $# -gt 0; do
  case "$1" in
    -h|--help)
            show_help "propagates patches from commits between previous and current development branch and pushes them to dedicated repository"
            exit 0
            ;;
    --previous_branch*)
            previous_branch=$(echo $1 | sed -e 's/^[^=]*=//g')
            shift
            ;;
    --current_branch*)
            current_branch=$(echo $1 | sed -e 's/^[^=]*=//g')
            shift
            ;;
    -p)
            shift
            if test $# -gt 0; then
              patchset_repo=$1
            else
              die "Please provide patchset repository"
            fi
            shift
            ;;
    --patchset*)
            patchset_repo=$(echo $1 | sed -e 's/^[^=]*=//g')
            shift
            ;;
    --token*)
            gh_token=$(echo $1 | sed -e 's/^[^=]*=//g')
            shift
            ;;
    --dry-run)
            dryRun=true
            shift
            ;;
    *)
            die "$(basename "$0"): unknown flag $(echo $1 | cut -d'=' -f 1)"
            exit 1
            ;;
  esac
done

GITHUB_TOKEN="${GITHUB_TOKEN:-$gh_token}"
if [[ -z $GITHUB_TOKEN || $GITHUB_TOKEN == "null" ]]; then
  die "Please provide GITHUB_TOKEN environment variable (or pass using --token flag)"
fi

TMP_DIR=$(mktemp -d -t "patchset.XXXXXXXXXX")
trap '{ rm -rf -- "$TMP_DIR"; }' EXIT

cd "${TMP_DIR}"

mkdir patchset
patchset_dir=$(pwd)/patchset

git clone "https://oauth2:${GITHUB_TOKEN}@${patchset_repo}.git" "${patchset_dir}"
configure_git "${patchset_dir}"

cd "${patchset_dir}"
mkdir -p "${current_branch}" "${previous_branch}"

cd "${previous_branch}"
cp -R . "../${current_branch}/"

cd "${patchset_dir}"
if [ -n "$(git status --porcelain)" ]; then
  git add .
  git commit -am"feat: migrates patchset from ${previous_branch} to ${current_branch}"
  skipInDryRun git push
else
  die "Nothing to commit. Are you sure '${previous_branch}' is the right source branch?"
fi
