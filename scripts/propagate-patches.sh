#!/bin/bash

ID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -euo pipefail

# shellcheck disable=SC1091
source "${DIR}/func.sh"
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

cd "${patchset_dir}"
mkdir -p "${current_branch}" "${previous_branch}"

cd "${previous_branch}"
cp -R . "../${current_branch}/"

### Patchset migration

cd "${patchset_dir}"
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

skipInDryRun git branch "${patch_head}"
skipInDryRun git branch "${patch_branch}"
skipInDryRun git switch "${patch_branch}"

for patch in "${patchset_dir}/${current_branch}/"*.patch
do
    [[ -e "${patch}" ]] || break  # handle the case of no *.patch files
    patch_name=$(basename "${patch}")
    patch_raw_url="https://${patchset_repo}/blob/main/${current_branch}/${patch_name}?raw=true"
    set +e ## turn off exit on error to capture git am failure.. any other way?
    echo "Applying ${patch}"
    apply_status="$(git am "${patch}" -k -3 2>&1)"
    git_am_exit=$?
    set -e

    if [ $git_am_exit -ne 0 ];
    then
        err_diff=$(git am --show-current-patch=diff)
        skipInDryRun git am --abort
        skipInDryRun git push origin "${patch_branch}"

        skipInDryRun git switch "${patch_head}"
        skipInDryRun git push origin "${patch_head}"

        skipInDryRun git switch "${patch_branch}"

        skipInDryRun gh api --silent repos/"${source_repo#*/}"/labels -f name="do-not-merge" -f color="E11218" || echo " label exists"

        if ! $skipPr; then
                prOutput=$(skipInDryRun gh pr create \
                        --base "${patch_head}" \
                        --head  "${patch_branch}" \
                        --title "fix: resolving patchset on ${current_branch}@${MAIN_REF}" \
                        --label "do-not-merge" \
                        --body-file - << EOF
## Why this PR?

This pull request is indented for resolving conflicts in patchset between \`${previous_branch}\` and changes done on ongoing development branch \`${current_branch}\`.

### Resolving the conflict

Apply the patch from the patchset repository

\`\`\`
git checkout ${patch_branch}
curl -L ${patch_raw_url}  | git am -k -3
\`\`\`

resolve the conflict and push back to the branch as a single commit.

### Next steps

Now you can continue verification process by invoking one of the commands:

 * \`/test\` will run unit tests
 * \`/lint\` will run perform lint checks on the code
 * \`/resolved\` will update the patch in the patchset and continue verification process if there are more patches.

You can find all the relevant patches in [patchset](https://${patchset_repo}/tree/main/${current_branch}) repository.

## Details

### Message
\`\`\`
${apply_status}
\`\`\`
### Conflict
\`\`\`diff
${err_diff}
\`\`\`

EOF
)

                pr_nr=$(echo "${prOutput}" | grep -oP "pull/\K.*" || echo "0")
                patch_label="patch/${current_branch}/${patch_name%%-*}"
                repo_slug="${source_repo#*/}"
                skipInDryRun gh api --silent repos/"${repo_slug}"/labels -f name="${patch_label}" -f color="c0ff00" || echo " label exists"
                skipInDryRun gh api --silent --method POST repos/"${repo_slug}"/issues/"${pr_nr}"/labels --input - <<EOF
{ "labels": ["${patch_label}"] }
EOF
        fi
        echo "Failed applying patches. Opened PR ${prOutput}"
        exit $git_am_exit # is there a distinction between failed and errored job?
    fi

done