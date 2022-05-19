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
  local GIT_USER="${GIT_USER:-}" 
  if [[ -z $GIT_USER ]]; then
    echo "Please provide GIT_USER environment variable" && exit 1
  fi

  local GIT_EMAIL="${GIT_EMAIL:-}" 
  if [[ -z $GIT_EMAIL ]]; then
    echo "Please provide GIT_EMAIL environment variable" && exit 1
  fi

  cd "${1}" || exit
  git config --local user.name "${GIT_USER}"
  git config --local user.email "${GIT_EMAIL}"
  cd - || exit
}

show_help() {
  local usage
  usage="
$(basename "$0") - $1

Usage:
  ./$(basename "$0") [flags]
   
Options:
  -r, --repo       
    URL to the repository where actual work is happening.

  -m,  --main
    Name of the main development branch where changes from upstream are synced (defaults to main).

  --dev
    Name of the branch with ongoing development streap (defaults to dev).

  -p, --patchset    
    URL to the repository where patches are stored.

  --token
    GitHub token used to perform pushes etc (required; can be defined through environment variable GITHUB_TOKEN)

  --dry-run        
    Boolean flag indicating if actual changes (e.g. pushes to GitHub) should be performed.

  -h, --help       
    Help message.

Example:
  ./$(basename "$0") --repo=github.com/bartoszmajsak-test/template-golang --patchset=github.com/bartoszmajsak-test/patchset \\
    --token='ghp_TOKEN' --dev=release-2.1    
"

  echo "$usage"
}
