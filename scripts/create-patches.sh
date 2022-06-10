#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -euo pipefail

# shellcheck disable=SC1091
source "${DIR}/func.sh"
# shellcheck disable=SC1091
source "${DIR}/hook.sh" # holds post-processing logic

dryRun=false

source_repo="${SOURCE_REPO:-}" # required

source="${SOURCE_BRANCH:-source}" # branch from which dev branch has been created (typically release-x.y branch which gets hotfixes ported back from master)
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
    -s)
            shift
            if test $# -gt 0; then
              source=$1
            else
              die "Please provide source branch name"
            fi
            shift
            ;;
    --source*) # it's not main branch, it's the one we are forking from - rethink the name
            source=$(echo $1 | sed -e 's/^[^=]*=//g')
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

git checkout "${source}"
git checkout "${dev_branch}"

repo_slug="${source_repo#*/}"
patchset_folder="${repo_slug}/${dev_branch}"
mkdir -p "${patchset_dir}/${patchset_folder}" 

patches=$(find "${patchset_dir}/${patchset_folder}/" -maxdepth 1 -name '*.patch' -printf x | wc -c)
patches=${patches##+(0)}

if [ "${patches}" -eq 0 ]; then
  echo "No patches created yet for '${patchset_folder}'"
fi 

mapfile -t commits <<< "$(git cherry "${source}" | grep '+' | cut -d' ' -f 2)" # This way we only take commits unique to dev branch which cannot be skipped (marked with + instead of -)
commits=("${commits[@]:patches}") ## Take only new commits since last time the patchset was updated

if [ "${#commits[@]}" -eq 0 ]; then
  echo "No new commits... nothing to do... moving on :)"
  exit 0
fi

for index in "${!commits[@]}"; do
  commit="${commits[$index]}"
  git format-patch -k -1 -M -C "${commit}"~.."${commit}" --start-number $((index+patches+1)) --ignore-if-in-upstream -o "${patchset_dir}/${patchset_folder}"
done;

cd "${patchset_dir}/${patchset_folder}"

if [ -n "$(git status --porcelain)" ]; then  
  files=()
  git add .
  mapfile -t files <<< "$(git status -s | cut -c4-)"
  for i in "${files[@]}"; do
      set +e
      found=$(lsdiff "${i}" | grep -c '.*\/vendor\/.*\|go.sum')
      if [ "${found}" -ne 0 ];
      then
        filterdiff --exclude "${exclusion}" "${i}" > "${i%.*}.${post_file_ext:2}" # defined in hook.sh
        rm "${i}"
      fi
      set -e
  done;
  git add .
  git commit -am"feat: updates patchset from ${dev_branch}"
  skipInDryRun git push
fi
