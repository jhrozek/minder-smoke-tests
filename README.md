# minder-smoke-tests

This repo contains simple shell scripts for smoke testing Minder, based on demo scripts used on conferences.
These will be replaced with proper e2e tests later, but as Evan said "This is the fire engine we built on the way to the fire".

## Environment

Right now the tests expect a GH org and under the org, a repo with a Python project underneath.
The scripts handle enrollment and repo registration, but they DO DELETE THE ACCOUNT AFTER THE TEST RUN.

##  Running the tests

You can run the tests against a prepared test org with repos already set up:
```bash
TEST_ORG=stacklok-minder-tests bash -x test-run.sh
```

Or your own org, but then you need to set the repo as well:
```bash
TEST_ORG=jakubtestorg PY_TEST_REPO=bad-python bash -x test-run.sh
```

More details tbd.