#!/bin/bash

minder auth whoami 1>/dev/null 2>&1 || minder auth login

profile_id_list=$(minder profile list -ojson | jq 'if .profiles then .profiles[].id else empty end')
for id in $profile_id_list; do
   minder profile delete -i $id;
done
minder ruletype delete --all --yes

repo_list=$(minder repo list --output=json 2>/dev/null | jq -r '.results[] | "\(.owner)/\(.name)"')
for repo in $repo_list; do
   minder repo delete -n $repo --provider github
done
minder auth delete --yes-delete-my-account