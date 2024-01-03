#!/bin/bash

PROFILE_IN=$(pwd)/profiles/profile.yaml.in

PY_PROFILE_FILE=$(pwd)/profiles/profile-python.yaml
PY_PROFILE_NAME=python-test-profile

############
# Functions
############

sed_inplace() {
    local os_name=$(uname)

    if [ "$os_name" = "Linux" ]; then
        sed -i "$@"
    elif [ "$os_name" = "Darwin" ]; then
        sed -i "" "$@"
    else
        echo "Unsupported operating system: $os_name"
        return 1
    fi
}

replace_profile_variables() {
    local file_path=$1

    local name="${NAME}"
    local ecosystem="${ECOSYSTEM}"
    local depfile="${DEPFILE}"
    local artifact_tags="${ARTIFACT_TAGS}"
    local artifact_name="${ARTIFACT_NAME}"

    # Use sed to replace the variables in the file
    sed_inplace \
        -e "s/\$NAME/$name/g" \
        -e "s/\$ECOSYSTEM/$ecosystem/g" \
        -e "s/\$DEPFILE/$depfile/g" \
        -e "s/\$ARTIFACT_TAGS/$artifact_tags/g" \
        -e "s/\$ARTIFACT_NAME/$artifact_name/g" \
        "$file_path"
}

expand_python_profile() {
    local profile_file=$1

    local NAME=$PY_PROFILE_NAME
    local ECOSYSTEM=pip
    local DEPFILE=requirements.txt
    local ARTIFACT_TAGS="[main]"
    local ARTIFACT_NAME=bad-python

    cp -f $PROFILE_IN $profile_file

    replace_profile_variables $profile_file
}

get_profile_status() {
    local profile_name=$1
    prf_status=$(minder profile status list -n $profile_name -d -ojson | jq -r '.profileStatus.profileStatus' | tr -d \")
    if [ $? -eq 0 ]; then
        echo "$prf_status"
    else
        echo "Error: Unable to fetch profile status." >&2
        return 1 # Return a non-zero exit status to indicate failure
    fi
}

wait_for_profile_reconcile() {
    local profile_name=$1
    local expected_state=$2

    local max_attempts=10
    local attempt=1
    local pStatus

    while [ $attempt -le $max_attempts ]; do
        echo "Attempt $attempt of $max_attempts"
        
        minder profile status list -n $PY_PROFILE_NAME -d
        prf_status=$(get_profile_status $profile_name)
        if [ "$prf_status" == $expected_state ]; then
            echo "$prf_status"
            return 0
        fi

        sleep 1

        ((attempt++))
    done

    echo "Profile status is still not $expected_state after $max_attempts attempts." >&2
    return 1
}

create_rule_types() {
    rule_dir=$(mktemp -d)
    git clone https://github.com/stacklok/minder-rules-and-profiles.git $rule_dir
    minder ruletype create -f $rule_dir/rule-types/github
}

create_repo_clone() {
    py_repo_dir=$(mktemp -d)

    git clone git@github.com:$TEST_ORG/$PY_TEST_REPO.git $py_repo_dir
    pushd $py_repo_dir
    git branch add-vulnerable-requests origin/add-vulnerable-requests
    git branch python-oauth2 origin/python-oauth2
    git branch restore origin/main
    popd
}

cleanup_profiles() {
    echo rm -f $PY_PROFILE_FILE
}

cleanup_script() {
    bash $(pwd)/test-teardown.sh
}

cleanup_rule_clone() {
    rm -rf $rule_dir
}

cleanup_py_repo_clone() {
    pushd $py_repo_dir || return 1

    this_repo=$(gh repo view --json name,owner --jq '.owner.login + "/" + .name')
    if [ "$this_repo" != "$TEST_ORG/$PY_TEST_REPO" ]; then
        echo "Unexpected repo"
        return 1
    fi

    for pr_num in $(gh pr list --state open --limit 1000 | awk '{print $1}'); do
        gh pr close $pr_num
    done

    # restore the CVE branch
    git checkout add-vulnerable-requests
    git push origin add-vulnerable-requests --force
    git checkout python-oauth2
    git push origin python-oauth2 --force
    # restore main
    git checkout main
    gh api -X DELETE /repos/{owner}/{repo}/branches/{branch}/protection
    git reset --hard restore
    git push origin main --force
    popd

    rm -rf $py_repo_dir
}

cleanup() {
    cleanup_profiles
    cleanup_py_repo_clone
    cleanup_rule_clone

    cleanup_script
}

############
# Test
############

# Make sure we clean up after ourselves
trap cleanup EXIT INT TERM

# Pre-flight checks
if [ -z "$TEST_ORG" ]; then
    echo "Error: The environment variable TEST_ORG is not set. Don't know what org to test against."
    exit 1
fi

# This is just a convenience so that the user only sets the org
if [ "$TEST_ORG" = "stacklok-minder-tests" ]; then
    PY_TEST_REPO="bad-python"
fi

if [ -z "$PY_TEST_REPO" ]; then
    echo "Error: The environment variable PY_TEST_REPO is not set. Don't know what repo to test against."
    exit 1
fi
echo "python test repo is '$PY_TEST_REPO'"

# Create a profile
expand_python_profile $PY_PROFILE_FILE

# Check if we're logged in
minder auth whoami || minder auth login

# enroll the provider
minder provider enroll --owner $TEST_ORG --yes

# register the repos
minder repo register --name $TEST_ORG/$PY_TEST_REPO

# register rule_types
# TODO: add a switch to use a local copy
create_rule_types

# clone the repo so we can open PRs against it
create_repo_clone

# create the test profile
minder profile create -f $PY_PROFILE_FILE

prf_status=$(wait_for_profile_reconcile $PY_PROFILE_NAME "failure")
if [ $? -ne 0 ]; then
    echo "Expected profile to fail"
    exit 1
fi

# show the profile, should show failure now and open a open a Dependabot PR
minder profile status list -n $PY_PROFILE_NAME -d

# merge this PR, the profile should flip into success
# TODO: this should probably be a more generic function, e.g. merge a PR whose
# title matches XYZ or maybe "do an action in a repo"
pushd $py_repo_dir || return 1
dependabot_pr_num=$(gh pr list --json title,number,url --jq '.[] | select(.title | startswith("Add Dependabot configuration")) | .number')
gh pr merge -s $dependabot_pr_num
popd

# TODO: Instead of checking for the profile status, we should be using for a combination of rule
# status in this repo only. Let's write a function for this.
prf_status=$(wait_for_profile_reconcile $PY_PROFILE_NAME "success")
if [ $? -ne 0 ]; then
    echo "TEST FAILURE: Expected profile to succeed"
    exit 1
fi

# OSV integration
# open a PR from the add-vulnerable-requests branch
pushd $py_repo_dir || return 1
git push origin add-vulnerable-requests --force
gh pr create --base main --head add-vulnerable-requests --title 'add-vulnerable-requests' --body 'adds vulnerable requests'
osv_pr_num=$(gh pr list --json title,number,url --jq '.[] | select(.title | startswith("add-vulnerable-requests")) | .number')

# wait until minder has had time to comment
prf_status=$(wait_for_profile_reconcile $PY_PROFILE_NAME "failure")
if [ $? -ne 0 ]; then
    echo "TEST FAILURE: Expected profile to fail"
    exit 1
fi

gh pr view $osv_pr_num --repo "$TEST_ORG/$PY_TEST_REPO" --json reviews | jq '.reviews[].body' | grep "Minder found vulnerable dependencies in this PR"
osv_test_rv=$?
gh pr close $osv_pr_num
popd

if [ $osv_test_rv -ne 0 ]; then
    echo "TEST FAILURE: Did not find the expected review from minder"
    exit 1
fi

# TODO: Ho-hoo! Looks like we found a bug! If we close the PR without fixing the issues, the status appears
# to be stuck at Failure..
#prf_status=$(wait_for_profile_reconcile $PY_PROFILE_NAME "success")
#if [ $? -ne 0 ]; then
#    echo "Expected profile to succeed"
#    exit 1
#fi

# Trusty integration
# open a PR from the python-oauth2 branch
pushd $py_repo_dir || return 1
gh pr create --base main --head python-oauth2 --title 'add python-oauth2' --body 'adds python-oauth2'
trusty_pr_num=$(gh pr list --json title,number,url --jq '.[] | select(.title | startswith("add python-oauth2")) | .number')

# wait until minder has had time to comment
prf_status=$(wait_for_profile_reconcile $PY_PROFILE_NAME "failure")
if [ $? -ne 0 ]; then
    echo "TEST FAILURE: Expected profile to fail"
    exit 1
fi

# TODO: Because the flip between failure and success seems to be broken, let's just sleep
sleep 5

gh pr view $trusty_pr_num --repo "$TEST_ORG/$PY_TEST_REPO" --json comments | jq '.comments[].body' | grep "Summary of packages with low scores"
trusty_test_rv=$?

gh pr close $trusty_pr_num
popd

if [ $trusty_test_rv -ne 0 ]; then
    echo "TEST FAILURE: Did not find the expected comment from minder"
    exit 1
fi

echo "TEST SUCCESS"