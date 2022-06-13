#!/bin/bash

ID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -euo pipefail

# shellcheck disable=SC1091
source "${DIR}/hook.sh"
# shellcheck disable=SC1091
source "${DIR}/func.sh"
# shellcheck disable=SC1091
source "${DIR}/msgs.sh"

dryRun=false
skipPr=false

PULL_BASE_REF="${PULL_BASE_REF:-}"
if [[ -z $PULL_BASE_REF ]]; then
  die "Please provide PULL_BASE_REF environment variable in old_branch:new_branch format."
fi

previous_branch="${PULL_BASE_REF%:*}"
current_branch="${PULL_BASE_REF#*:}"
patchset_repo="${PATCHSET_REPO:-}" # required
source_repo="${SOURCE_REPO:-}" # required
patchset_dir="${PATCHSET_DIR:-patchset}"

gh_token="null"

while test $# -gt 0; do
  case "$1" in
    -h|--help)
            show_help "propagates patches from commits between previous and current development branch and pushes them to the dedicated repository"
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

mkdir source_repo
source_repo_dir=$(pwd)/source_repo

git clone "https://oauth2:${GITHUB_TOKEN}@${source_repo}.git" "${source_repo_dir}"
configure_git "${source_repo_dir}"

repo_slug="${source_repo#*/}"

cd "${patchset_dir}"
mkdir -p "${repo_slug}/${current_branch}" "${repo_slug}/${previous_branch}"

cd "${repo_slug}/${previous_branch}"
cp -R . "../${current_branch}/"

cd - 

### Patchset migration
patchset_folder="${repo_slug}/${current_branch}"

cd "${patchset_folder}"
if [ -n "$(git status --porcelain)" ]; then
  git add .
  git commit -am"feat: migrates patchset from ${previous_branch} to ${current_branch}"
  skipInDryRun git push
fi

cd "${source_repo_dir}"

## Start patch migration process
git switch "${current_branch}"

MAIN_REF=$(git rev-parse HEAD)

patch_branch="patch_update_${ID}"
patch_head="head_${ID}"

git branch "${patch_head}"
git branch "${patch_branch}"
git switch "${patch_branch}"

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

    if [ $git_am_exit -ne 0 ];
    then 
        err_diff=$(trim --source "$(git diff)" --trim_msg "[...] diff too long. Please check the details while resolving it." --max_lines 100 || true) # not sure why it ends with PIPE error
        git am --abort
        skipInDryRun git push origin "${patch_branch}"

        git switch "${patch_head}"
        skipInDryRun git push origin "${patch_head}"

        git switch "${patch_branch}"

        skipInDryRun gh api --silent repos/"${repo_slug}"/labels -f name="do-not-merge" -f color="E11218" || echo " label exists"

        if ! $skipPr; then
                patch_hint="Apply the [failed patch](${patch_raw_url}) from the patchset repository

\`\`\`
git checkout ${patch_branch}
curl -L ${patch_raw_url}  | git am -k -3
\`\`\`"

                post_processing_hint=""
                if [[ $patch ==  $post_file_ext ]]; then
                post_processing_body="$(type post_processing | sed '1,3d;$d')"
                post_processing_hint="Since it's a special patch which needs post processing step you should also invoke following steps:

\`\`\`
${post_processing_body}
\`\`\`
        "
                fi

                propagationFailed=$(patch_propagation_failed --previous_branch "${previous_branch}" \
                        --current_branch "${current_branch}" \
                        --patchset_repo "${patchset_repo}" \
                        --patchset_folder "${patchset_folder}" \
                        --apply_status "${apply_status}" \
                        --err_diff "${err_diff}" \
                        --patch_hint "${patch_hint}" \
                        --post_processing_hint "${post_processing_hint}")

                prOutput=$(skipInDryRun gh pr create \
                        --base "${patch_head}" \
                        --head  "${patch_branch}" \
                        --title "fix: resolving patchset on ${current_branch}@${MAIN_REF}" \
                        --label "do-not-merge" \
                        --body "${propagationFailed}")

                pr_nr=$(echo "${prOutput}" | grep -oP "pull/\K.*" || echo "0")
                patch_label="patch/${current_branch}/${patch_name%%-*}"
                
                skipInDryRun gh api --silent repos/"${repo_slug}"/labels -f name="${patch_label}" -f color="c0ff00" || echo " label exists"
                skipInDryRun gh api --silent --method POST repos/"${repo_slug}"/issues/"${pr_nr}"/labels --input - <<EOF
{ "labels": ["${patch_label}"] }
EOF
        fi
        echo "Failed applying patches. Opened PR ${prOutput}"
        exit $git_am_exit # is there a distinction between failed and errored job?
    elif [[ $patch == $post_file_ext ]]; then
        post_processing
    fi

done
