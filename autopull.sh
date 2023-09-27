#!/bin/bash
cd $PWD

pull_result=$(git pull | base64)
local_commit_hash=$(git rev-parse --short HEAD)

if [[ $pull_result != "QWxyZWFkeSB1cCB0byBkYXRlLgo=" ]]; then
    echo "NEW COMMIT $local_commit_hash `date`" >> /var/log/git.log
    docker-compose pull
    docker-compose up --detach
    echo "APP RESTARTED `date`" >> /var/log/git.log
fi

