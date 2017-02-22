#!/bin/bash

###########################################################
# START SECRET DATA - ECHO DISABLED
###########################################################

# Fields for `azure.json`
KUBELET_PRIVATE_KEY="${1}"

KUBELET_PRIVATE_KEY_PATH="/etc/kubernetes/certs/client.key"
touch "${KUBELET_PRIVATE_KEY_PATH}"
chmod 0644 "${KUBELET_PRIVATE_KEY_PATH}"
chown root:root "${KUBELET_PRIVATE_KEY_PATH}"
echo "${KUBELET_PRIVATE_KEY}" | base64 --decode > "${KUBELET_PRIVATE_KEY_PATH}"

###########################################################
# END OF SECRET DATA
###########################################################

set -x

function ensureDocker() {
    systemctl enable docker
    systemctl restart docker
    dockerStarted=1
    for i in {1..600}; do
        if ! /usr/bin/docker info; then
            echo "status $?"
            /bin/systemctl restart docker
        else
            echo "docker started"
            dockerStarted=0
            break
        fi
        sleep 1
    done
    if [ $dockerStarted -ne 0 ]
    then
        echo "docker did not start"
        exit 1
    fi
}

function ensureKubelet() {
    systemctl enable kubelet
    systemctl restart kubelet
}

ensureDocker
ensureKubelet

echo "Install complete successfully"

