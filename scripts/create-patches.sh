#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -euo pipefail

# shellcheck disable=SC1091
source "${DIR}/func.sh"
dryRun=false

source_repo="${SOURCE_REPO:-}" # required

main="${MAIN_BRANCH:-main}"
dev_branch="${DEV_BRANCH:-"${PULL_BASE_REF:-"_______undefined"}"}"
patchset_repo="${PATCHSET_REPO:-}" # required
patchset_dir="${PATCHSET_DIR:-patchset}"

gh_token="null"

while test $# -gt 0; do
  case "$1" in
    -h|--help)
            show_help "creates patches from commits on the development branch and pushes them to dedicated repository"
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

mkdir source_repo
source_repo_dir=$(pwd)/source_repo

git clone "https://oauth2:${GITHUB_TOKEN}@${patchset_repo}.git" "${patchset_dir}" 
configure_git "${patchset_dir}"

git clone "https://oauth2:${GITHUB_TOKEN}@${source_repo}.git" "${source_repo_dir}"
configure_git "${source_repo_dir}"

cd "${source_repo_dir}"

if [[ "${dev_branch}" == "_______undefined" ]]; then
  die "Unspecified development branch. Please set DEV_BRANCH environment variable."
fi

git checkout "${main}"
git checkout "${dev_branch}"

mkdir -p "${patchset_dir}/${dev_branch}/" 

patches=$(find "${patchset_dir}/${dev_branch}/" -maxdepth 1 -name '*.patch'| wc -l)
patches=${patches##+(0)}

if [ "${patches}" -eq 0 ]; then
  echo "No patches created yet for '${dev_branch}'"
  first_commit=$(git log "${main}".."${dev_branch}" --oneline --pretty=format:'%h' | tail -1)
  if [ "$(echo "${first_commit}" | tr -d '[:space:]' | wc -w)" -gt 0 ]; then
    git format-patch -k "${first_commit}~"..HEAD -o "${patchset_dir}/${dev_branch}"
  fi
else  
  echo "Adding patches for '${dev_branch}'"
  total_commits=$(git rev-list --no-merges --count "${main}"..)
  total_commits=${total_commits##+(0)}
  start_from=$((total_commits - patches))
  git format-patch -k HEAD~"${start_from}" --start-number "$((patches + 1))" -o "${patchset_dir}/${dev_branch}"
fi 

cd "${patchset_dir}"

if [ -n "$(git status --porcelain)" ]; then  
  files=()
  git add .
  mapfile -t files <<< "$(git status -s | cut -c4-)"
  for i in "${files[@]}"; do
      set +e
      found=$(lsdiff "${i}" | grep -c '.*\/vendor\/.*')
      if [ "${found}" -ne 0 ];
      then
        filterdiff --exclude '*/vendor/*' "${i}" > "${i%.*}.post.patch"
        rm "${i}"
      fi
      set -e
  done;
  git add .
  git commit -am"feat: updates patchset from ${dev_branch}"
  skipInDryRun git push
fi
