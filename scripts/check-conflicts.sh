#!/bin/bash

ID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -euo pipefail

# shellcheck disable=SC1091
source "${DIR}/func.sh"
# shellcheck disable=SC1091
source "${DIR}/hook.sh" # holds post-processing logic
# shellcheck disable=SC1091
source "${DIR}/msgs.sh"

dryRun=false
skipPr=false

source_repo="${SOURCE_REPO:-}" # required

main="${MAIN_BRANCH:-main}"
dev_branch="${DEV_BRANCH:-"${PULL_BASE_REF:-"_______undefined"}"}"

patchset_repo="${PATCHSET_REPO:-}" # required
patchset_dir="${PATCHSET_DIR:-patchset}"

gh_token="null"

if [[ "$#" -eq 0 ]]; then
  show_help
  exit 0
fi

while test $# -gt 0; do
  case "$1" in
    -h|--help)
            show_help "verifies if set of patches can be applied against a HEAD of main development branch"
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
    --skip-pr)
            skipPr=true
            shift
            ;;
    *)
            die "$(basename "$0"): unknown flag $(echo $1 | cut -d'=' -f 1)"
            exit 1
            ;;
  esac
done

GITHUB_TOKEN="${GITHUB_TOKEN:-$gh_token}"
if [[ -z $GITHUB_TOKEN ]]; then
  echo "Please provide GITHUB_TOKEN environment variable (or pass using --token flag ${gh_token})" && exit 1
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

## Start patch process

repo_slug="${source_repo#*/}"

if [[ "${dev_branch}" == "_______undefined" ]]; then
  dev_branch=$(gh api repos/"${repo_slug}" -q '.default_branch')
fi

git switch "${main}"

MAIN_REF=$(git rev-parse HEAD)

patch_branch="patch_update_${ID}"
patch_head="head_${ID}"

git branch "${patch_head}"
git branch "${patch_branch}"
git switch "${patch_branch}"

patchset_folder="${repo_slug}/${dev_branch}"

for patch in "${patchset_dir}/${patchset_folder}/"*.patch
do
    [[ -e "${patch}" ]] || break  # handle the case of no *.patch files
    patch_name=$(basename "${patch}")
    patch_raw_url="https://${patchset_repo}/blob/main/${patchset_folder}/${patch_name}?raw=true"
    set +e ## turn off exit on error to capture git am failure.. any other way?
    echo "Applying ${patch}"
    apply_status="$(git am "${patch}" -k -3 2>&1)"
    git_am_exit=$?
    set -e

    if [ $git_am_exit -ne 0 ]; then
        err_diff=$(trim --source "$(git diff)" --trim_msg "[...] diff too long. Please check the details while resolving it." --max_lines 100 || true) # not sure why it ends with PIPE error
        git am --abort
        skipInDryRun git push origin "${patch_branch}"        

        git switch "${patch_head}"
        skipInDryRun git push origin "${patch_head}"
        
        git switch "${patch_branch}"

        skipInDryRun gh api --silent repos/"${repo_slug}"/labels -f name="do-not-merge" -f color="E11218" || true
        patch_hint="git checkout ${patch_branch}
curl -L ${patch_raw_url}  | git am -k -3"

        post_processing_hint=""
        if [[ $patch ==  $post_file_ext ]]; then
            post_processing_body="$(type post_processing | sed '1,3d;$d')"
            post_processing_hint="Since it's a special patch which needs post processing step you should also invoke following steps:

\`\`\`
${post_processing_body}
\`\`\`
"
        fi

        if ! $skipPr; then
                if git diff --quiet "${patch_head}".."${patch_branch}"; then
                        git switch "${patch_branch}"
                        git commit --allow-empty -am'empty: marker commit to trigger conflict resolution through PR when first patch fails'        
                        skipInDryRun git push origin "${patch_branch}"
                        git switch - 
                fi

                prMsg=$(conflict_detected --main "${main}" \
                --dev_branch "${dev_branch}" \
                --patchset_repo "${patchset_repo}" \
                --patchset_folder "${patchset_folder}" \
                --apply_status "${apply_status}" \
                --err_diff "${err_diff}" \
                --patch_hint "${patch_hint}" \
                --post_processing_hint "${post_processing_hint}")

                prOutput=$(skipInDryRun gh pr create \
                        --base "${patch_head}" \
                        --head  "${patch_branch}" \
                        --title "fix: resolving patchset on ${main}@${MAIN_REF}" \
                        --label "do-not-merge" \
                        --body "${prMsg}")

                pr_nr=$(echo "${prOutput}" | grep -oP "pull/\K.*")
                patch_label="patch/${dev_branch}/${patch_name%%-*}"
                skipInDryRun gh api --silent repos/"${repo_slug}"/labels -f name="${patch_label}" -f color="c0ff00" || true
                skipInDryRun gh api --silent --method POST repos/"${repo_slug}"/issues/"${pr_nr}"/labels --input - <<EOF
{ "labels": ["${patch_label}"] }
EOF
        fi
        exit $git_am_exit # is there a distinction between failed and errored job?
    elif [[ $patch == $post_file_ext ]]; then
        # alternatively https://git-scm.com/docs/githooks#_pre_applypatch
        # but this would require changing git hooks path (git version >= 2.9)
        # git config core.hooksPath .githook
        # note: upstream does not have this folder
        post_processing
    fi

done
