#!/bin/bash

# This file contains templates for PR description and comments


patch_propagation_failed() {
    while [ $# -gt 0 ]; do
        if [[ $1 == "--"* ]]; then
            v="${1/--/}"
            local "$v"="$2"
            shift
        fi
        shift
    done

    read -r -d '' msg << EOF 
## Why this PR?

This pull request is indented for resolving conflicts in patchset between \`${previous_branch}\` and changes done on ongoing development branch \`${current_branch}\`.

### Resolving the conflict

Apply the patch from the patchset repository

${patch_hint}

${post_processing_hint}

Then resolve the conflict and push back to the branch as a single commit.

### Next steps

Now you can continue verification process by invoking one of the commands:

* \`/test\` will run unit tests
* \`/lint\` will run perform lint checks on the code
* \`/resolved\` will update the patch in the patchset and continue verification process if there are more patches.

You can find all the relevant patches in [patchset](https://${patchset_repo}/tree/main/${patchset_folder}) repository.

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

    echo "${msg}"
}

conflict_detected() {
    while [ $# -gt 0 ]; do
        if [[ $1 == "--"* ]]; then
            v="${1/--/}"
            local "$v"="$2"
            shift
        fi
        shift
    done

    read -r -d '' msg << EOF 
## Why this PR?

This pull request is indented for resolving conflicts between \`upstream/${main}\` and changes done on ongoing development branch \`${dev_branch}\`.

### Resolving the conflict

${patch_hint}

${post_processing_hint}

Then resolve the conflict and push back to the branch as a single commit.

### Next steps

Now you can continue verification process by invoking one of the commands:

* \`/test\` will run unit tests
* \`/lint\` will run perform lint checks on the code
* \`/resolved\` will update the patch in the patchset and continue verification process if there are more patches.

You can find all the relevant patches in [patchset](https://${patchset_repo}/tree/main/${patchset_folder}) repository.

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

    echo "${msg}"
}

validation_failed() {
    while [ $# -gt 0 ]; do
        if [[ $1 == "--"* ]]; then
            v="${1/--/}"
            local "$v"="$2"
            shift
        fi
        shift
    done

    read -r -d '' msg << EOF 
Failed applying [\`${patch_name}\`](${patch_raw_url}).

## Details

### Message
\`\`\`
${apply_status}
\`\`\`

### Conflict
\`\`\`diff
${err_diff}
\`\`\`

### Resolving the conflict

${patch_hint}

${post_processing_hint}

Then resolve the conflict and push back to the branch as a single commit.
EOF
    echo "${msg}"
}

# TODO write some tests for it
# TODO should it make some params required?

# validation_failed --patch_name 0001-patch \
#     --patch_raw_url URL \
#     --apply_status OK \
#     --err_diff DIFF \
#     --patch_hint HINT \
#     --post_processing_hint EXTRA123123123123

