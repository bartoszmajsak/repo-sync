#!/bin/bash

# default logic for patch post-processing
# TODO make it extensible :)

post_file_ext="*.post.patch"
exclusion="*/vendor/*"

post_processing() {
    # post-processing in case of success
    go mod vendor
    git add .
    git commit --amend --no-edit
} 