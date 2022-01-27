setup() {
    # get the containing directory of this file
    # use $BATS_TEST_FILENAME instead of ${BASH_SOURCE[0]} or $0,
    # as those will point to the bats executable's location or the preprocessed file respectively
    DIR="$( cd "$( dirname "$BATS_TEST_FILENAME" )" >/dev/null 2>&1 && pwd )"
    PATH="$DIR/../scripts:$PATH"

    load 'test_helper/bats-support/load'
    load 'test_helper/bats-assert/load'
}

function git() {
    local subcmd=$1
    if [[ "${subcmd}" == "rev-list" ]]; then
        echo 2
        exit
    fi
    echo "git ${*}"
}

function gh() {
    echo "gh ${*}"
}

script_under_test="create-patches.sh"

@test "should fail when github token is not provided" {
    # given
    unset GH_TOKEN
    unset GITHUB_TOKEN
        
    # when
    run $script_under_test
    
    # then
    assert_line 'Please provide GITHUB_TOKEN environment variable (or pass using --token flag)'
    assert_failure
}

@test "should prompt for git user if not specified" {
    export -f git gh

    # given
    export GITHUB_TOKEN="1231232"
    
    # when
    run $script_under_test
    
    # then
    assert_line 'Please provide GIT_USER environment variable'
    assert_failure
}

@test "should prompt for git user email if not specified" {
    export -f git gh

    # given
    export GITHUB_TOKEN="1231232"
    export GIT_USER="git-bot"
    
    # when
    run $script_under_test
    
    # then
    assert_line 'Please provide GIT_EMAIL environment variable'
    assert_failure
}

@test "should fail when dev branch not specified" {
    # stubs result of finding patch files
    function find() {
        echo "0001-patch-1"
    }
    export -f git find gh

    # given
    export GITHUB_TOKEN="1231232"
    export GIT_USER="git-bot"
    export GIT_EMAIL="git@github.com"
    
    # when
    run $script_under_test
    
    # then
    assert_line 'Unspecified development branch. Please set DEV_BRANCH environment variable.'
    assert_failure
}

@test "should configure git user locally" {
    # stubs result of finding patch files
    function find() {
        echo "0001-patch-1"
    }
    export -f git find gh

    # given
    export GITHUB_TOKEN="1231232"
    export GIT_USER="git-bot"
    export GIT_EMAIL="git@github.com"
    export DEV_BRANCH="dev"
    
    # when
    run $script_under_test
    
    # then
    assert_line 'git config --local user.name git-bot'
    assert_line 'git config --local user.email git@github.com'
    assert_success
}



