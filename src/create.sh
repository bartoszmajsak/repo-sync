#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -euo pipefail

# shellcheck disable=SC1091
source "${DIR}/func.sh"
dryRun=false

show_help() {
  echo "create - ..."
  echo " "
  echo "./create.sh [flags|version]"
  echo " "
  echo "Options:"
}

source_repo="${SOURCE_REPO:-}" # required

main="${MAIN_BRANCH:-master}"
dev_branch="${DEV_BRANCH:-dev}"

patchset_repo="${PATCHSET_REPO:-}" # required
patchset_dir="${PATCHSET_DIR:-patchset}"

gh_token="null"

while test $# -gt 0; do
  case "$1" in
    -h|--help)
            show_help
            exit 0
            ;;
    -m)
            shift
            if test $# -gt 0; then
              main=$1
            else
              die "Please provide branch name"
            fi
            shift
            ;;
    --main*)
            main=$(echo $1 | sed -e 's/^[^=]*=//g')
            shift
            ;;
    --dev*)
            dev_branch=$(echo $1 | sed -e 's/^[^=]*=//g')
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
    -r)
            shift
            if test $# -gt 0; then
              source_repo=$1
            else
              die "Please provide source repository"
            fi
            shift
            ;;
    --repo*)
            source_repo=$(echo $1 | sed -e 's/^[^=]*=//g')
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
            die "unknown flag $(echo $1 | sed -e 's/^[^=]*=//g')"
            exit 1
            ;;
  esac
done

GITHUB_TOKEN="${GITHUB_TOKEN:-$gh_token}"
if [[ -z $GITHUB_TOKEN || $GITHUB_TOKEN == "null" ]]; then
  echo "Please provide GITHUB_TOKEN environment variable (or pass using --token flag)" && exit 1
fi

TMP_DIR=$(mktemp -d -t "patchset.XXXXXXXXXX")
trap '{ rm -rf -- "$TMP_DIR"; }' EXIT

cd "${TMP_DIR}"

mkdir patchset
patchset_dir=$(pwd)/patchset

mkdir source_repo
source_repo_dir=$(pwd)/source_repo

configure_git "${patchset_dir}"
configure_git "${source_repo_dir}"

git clone "https://oauth2:${GITHUB_TOKEN}@${patchset_repo}.git" "${patchset_dir}" 
git clone "https://oauth2:${GITHUB_TOKEN}@${source_repo}.git" "${source_repo_dir}" 

cd "${source_repo_dir}"

git checkout "${dev_branch}"

patches=$(find "${patchset_dir}/${dev_branch}/" -maxdepth 1 -name '*.patch'| wc -l)
patches=${patches##+(0)}

if [ "${patches}" -eq 0 ]; then
  first_commit=$(git log "${main}".."${dev_branch}" --oneline --pretty=format:'%h' | tail -1) 
  git format-patch -k "${first_commit}~"..HEAD -o "${patchset_dir}/${dev_branch}"  
else  
  total_commits=$(git rev-list --no-merges --count "${main}"..)
  total_commits=${total_commits##+(0)}
  start_from=$((total_commits - patches))
  skipInDryRun git format-patch -k HEAD~"${start_from}" --start-number "$((patches + 1))" -o "${patchset_dir}/${dev_branch}"  
fi 

cd "${patchset_dir}"
git add .
git commit -am"feat: updates patchset from ${dev_branch}"

skipInDryRun git push
