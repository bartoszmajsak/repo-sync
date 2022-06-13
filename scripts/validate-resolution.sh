#!/bin/bash

DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

set -euo pipefail

# shellcheck disable=SC1091
source "${DIR}/func.sh"
# shellcheck disable=SC1091
source "${DIR}/hook.sh" # holds post-processing logic
# shellcheck disable=SC1091
source "${DIR}/msgs.sh"

dryRun=false
skipPatchMode=false

source_repo="${SOURCE_REPO:-}" # required
current_branch="${CURRENT_BRANCH:-dev}" # TODO validate

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
            show_help "continues patch verification process after conflicts are resolved"
            exit 0
            ;;   
    --branch*)
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
    -s|--skip-patch)
           skipPatchMode=true
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
if [[ -z $GITHUB_TOKEN ]]; then # TODO or == null
  echo "Please provide GITHUB_TOKEN environment variable (or pass using --token flag ${gh_token})" && exit 1
fi

PULL_NUMBER="${PULL_NUMBER:-}" 
if [[ -z $PULL_NUMBER ]]; then
  echo "Please provide pull request number by setting PULL_NUMBER environment variable" && exit 1
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

## Start patch process

cd "${source_repo_dir}"

export PAGER=more
repo_slug="${source_repo#*/}"

pr=$(gh api repos/"${repo_slug}"/pulls/"${PULL_NUMBER}")

current_branch=$(jq -r '.head.ref' - << EOF
$pr
EOF
)

base_branch=$(jq -r '.base.ref' - << EOF
$pr
EOF
)

git switch "${current_branch}"

label=$(jq -c -r '.labels[] | select(.name | contains("patch/")) | .name' - << EOF
$pr
EOF
)

if [[ -z $label ]]; then
  die "Pull request does not have label starting with 'patch/'. Please check if it's set up correctly."
fi

label_prefix=${label#*/}
patch_branch=${label_prefix%/*}
failed_patch_nr=${label##*/}
failed_patch_nr=$((10#$failed_patch_nr))

patchset_folder="${repo_slug}/${patch_branch}"

if $skipPatchMode; then
  echo "skipping failed patch ${failed_patch_nr}"
  failed_patch_nr=$((failed_patch_nr + 1))
else
  ### update resolved patch
  git format-patch -k -1 --start-number "${failed_patch_nr}" -o "${patchset_dir}/${patchset_folder}"  
  cd "${patchset_dir}/${patchset_dir}" && skipInDryRun git commit -am"feat: resolved in ${current_branch}" && skipInDryRun git push
fi

cd "${source_repo_dir}"

patches=$(find "${patchset_dir}/${patchset_folder}" -maxdepth 1 -name '*.patch')
total_patches=$(echo "${patches}" | wc -l)

### continue applying existing patches
for patch in $(echo "${patches}" | sort | tail -"$((total_patches - failed_patch_nr + 1))")
do
    [[ -e "${patch}" ]] || break  # handle the case of no *.patch files

    patch_name=$(basename "${patch}")

    patch_raw_url="https://${patchset_repo}/blob/main/${patchset_folder}/${patch_name}?raw=true"
    set +e ## turn off exit on error to capture git am failure.. any other way?
    echo "Applying ${patch_name}"
    apply_status="$(git am "${patch}" -k -3 2>&1)"
    git_am_exit=$?
    set -e

    if [ $git_am_exit -ne 0 ];
    then
        err_diff=$(trim --source "$(git diff)" --trim_msg "[...] diff too long. Please check the details while resolving it." --max_lines 100 || true) # not sure why it ends with PIPE error
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

        skipInDryRun git am --abort
        skipInDryRun git push origin "${current_branch}"        

        prComment=$(validation_failed --patch_name "${patch_name}" \
                    --patch_raw_url "${patch_raw_url}" \
                    --apply_status "${apply_status}" \
                    --err_diff "${err_diff}" \
                    --patch_hint "${patch_hint}" \
                    --post_processing_hint "${post_processing_hint}")

        skipInDryRun gh pr comment "${PULL_NUMBER}" \
          --body "${prComment}"

        patch_label="patch/${patch_branch}/${patch_name%%-*}"
        # remove old label        
        skipInDryRun gh api --method DELETE repos/"${repo_slug}"/issues/"${PULL_NUMBER}"/labels/"${label}" || true
        skipInDryRun gh api --method DELETE repos/"${repo_slug}"/labels/"${label}" || true
        # mark currently failing patch through new label
        skipInDryRun gh api repos/"${repo_slug}"/labels -f name="${patch_label}" -f color="c0ff00" || true
        skipInDryRun gh api --method POST repos/"${repo_slug}"/issues/"${PULL_NUMBER}"/labels --input - <<EOF
{ "labels": ["${patch_label}"] }
EOF
        exit $git_am_exit # is there a distinction between failed and errored job
    elif [[ $patch == $post_file_ext ]]; then
        post_processing
    fi
   
done

skipInDryRun gh pr comment "${PULL_NUMBER}" \
          --body-file - << EOF 

:robot: All subsequent patches were applied without conflicts. Closing this PR.

EOF

### Remove remaining patch label

skipInDryRun gh api --silent --method DELETE repos/"${repo_slug}"/issues/"${PULL_NUMBER}"/labels/"${label}"
skipInDryRun gh pr close "${PULL_NUMBER}"

skipInDryRun git push origin ":${current_branch}"
skipInDryRun git push origin ":${base_branch}"
