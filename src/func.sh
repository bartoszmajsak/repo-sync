#!/bin/bash

die () {
    echo >&2 "$@"
    exit 1
}

dryRun=false
skipInDryRun() {
  if $dryRun; then echo "# $*"; fi
  if ! $dryRun; then "$@";  fi
}


configure_git() {
  GIT_USER="${GIT_USER:-}" 
  if [[ -z $GIT_USER ]]; then
    echo "Please provide GIT_USER environment variable" && exit 1
  fi

  GIT_EMAIL="${GIT_EMAIL:-}" 
  if [[ -z $GIT_EMAIL ]]; then
    echo "Please provide GIT_EMAIL environment variable" && exit 1
  fi

  cd "${1}" || exit
  git config --local user.name "${GIT_USER}"
  git config --local user.email "${GIT_EMAIL}"
  cd - || exit
}