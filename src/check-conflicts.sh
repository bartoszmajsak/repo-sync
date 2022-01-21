#!/bin/bash

ID=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1)
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -euo pipefail

# shellcheck disable=SC1091
source "${DIR}/func.sh"
dryRun=false

source_repo="${SOURCE_REPO:-}" # required

main="${MAIN_BRANCH:-main}"
dev_branch="${DEV_BRANCH:-"_______undefined"}"

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
    *)
            die "unknown flag $(echo $1 | sed -e 's/^[^=]*=//g')"
            exit 1
            ;;
  esac
done

GITHUB_TOKEN="${GITHUB_TOKEN:-$gh_token}"
if [[ -z $GITHUB_TOKEN ]]; then
  echo "Please provide GITHUB_TOKEN environment variable (or pass using --token flag ${gh_token})" && exit 1
fi

TMP_DIR=$(mktemp -d -t "patchset.XXXXXXXXXX")
# trap '{ rm -rf -- "$TMP_DIR"; }' EXIT

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

if [[ "${dev_branch}" == "_______undefined" ]]; then
  repo_slug="${source_repo#*/}"
  dev_branch=$(gh api repos/"${repo_slug}" -q '.default_branch')
fi

git switch "${main}"

MAIN_REF=$(git rev-parse HEAD)

patch_branch="patch_update_${ID}"
patch_head="head_${ID}"

skipInDryRun git switch -c "${patch_head}"
skipInDryRun git switch -c "${patch_branch}"

for patch in "${patchset_dir}/${dev_branch}/"*.patch
do
    [[ -e "${patch}" ]] || break  # handle the case of no *.patch files
    patch_name=$(basename "${patch}")
    patch_raw_url="https://${patchset_repo}/blob/main/${dev_branch}/${patch_name}?raw=true"
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

        skipInDryRun gh api --silent repos/"${source_repo#*/}"/labels -f name="do-not-merge" -f color="E11218" || true


        prOutput=$(skipInDryRun gh pr create \
          --base "${patch_head}" \
          --head  "${patch_branch}" \
          --title "fix: resolving patchset on ${main}@${MAIN_REF}" \
          --label "do-not-merge" \
          --body-file - << EOF 
## Why this PR?

This pull request is indented for resolving conflicts between \`upstream/${main}\` and changes done on ongoing development branch \`${dev_branch}\`.

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

You can find all the relevant patches in [patchset](https://${patchset_repo}/tree/main/${dev_branch}) repository.

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
        pr_nr=$(echo "${prOutput}" | grep -oP "pull/\K.*")
        patch_label="patch/${dev_branch}/${patch_name%%-*}"
        repo_slug="${source_repo#*/}"
        skipInDryRun gh api --silent repos/"${repo_slug}"/labels -f name="${patch_label}" -f color="c0ff00" || true
        skipInDryRun gh api --silent --method POST repos/"${repo_slug}"/issues/"${pr_nr}"/labels --input - <<EOF
{ "labels": ["${patch_label}"] }
EOF
        exit $git_am_exit # is there a distinction between failed and errored job?
    fi
done


