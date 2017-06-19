#!/bin/bash

###########################################################
# START SECRET DATA - ECHO DISABLED
###########################################################

# Fields for `azure.json`
KUBELET_PRIVATE_KEY="${1}"
NETWORK_POLICY="${2}"

KUBELET_PRIVATE_KEY_PATH="/etc/kubernetes/certs/client.key"
touch "${KUBELET_PRIVATE_KEY_PATH}"
chmod 0644 "${KUBELET_PRIVATE_KEY_PATH}"
chown root:root "${KUBELET_PRIVATE_KEY_PATH}"
echo "${KUBELET_PRIVATE_KEY}" | base64 --decode > "${KUBELET_PRIVATE_KEY_PATH}"

if [ -f /var/run/reboot-required ]; then
    REBOOTREQUIRED=true
else
    REBOOTREQUIRED=false
fi

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

function setAgentPool() {
    AGENTPOOL=`hostname | cut -d- -f2`
    sed -i "s/^KUBELET_NODE_LABELS=.*/KUBELET_NODE_LABELS=role=agent,agentpool=${AGENTPOOL}/" /etc/default/kubelet
}

function ensureKubelet() {
    systemctl enable kubelet
    systemctl restart kubelet
}
 
function setNetworkPlugin () { 
    sed -i "s/^KUBELET_NETWORK_PLUGIN=.*/KUBELET_NETWORK_PLUGIN=${1}/" /etc/default/kubelet 
}

function setDockerOpts () { 
    sed -i "s#^DOCKER_OPTS=.*#DOCKER_OPTS=${1}#" /etc/default/kubelet 
} 

function configNetworkPolicy() { 
    if [[ ! -z "${APISERVER_PRIVATE_KEY}" ]]; then 
        # on masters 
        ADDONS="calico-configmap.yaml calico-daemonset.yaml" 
        ADDONS_PATH=/etc/kubernetes/addons 
        CALICO_URL="https://github.com/simonswine/calico/raw/master/v2.0/getting-started/kubernetes/installation/hosted/k8s-backend-addon-manager" 
        if [[ "${NETWORK_POLICY}" = "calico" ]]; then 
            # download calico yamls 
            for addon in ${ADDONS}; do 
                curl -o "${ADDONS_PATH}/${addon}" -sSL --retry 12 --retry-delay 10 "${CALICO_URL}/${addon}" 
            done 
        else 
            # make sure calico yaml are removed 
            for addon in ${ADDONS}; do 
                rm -f "${ADDONS_PATH}/${addon}" 
            done 
        fi 
    else 
        # on agents 
        if [[ "${NETWORK_POLICY}" = "calico" ]]; then 
            setNetworkPlugin cni 
            setDockerOpts " --volume=/etc/cni/:/etc/cni:ro --volume=/opt/cni/:/opt/cni:ro" 
        else 
            setNetworkPlugin kubenet 
            setDockerOpts "" 
        fi 
    fi 
} 
 
ensureDocker
configNetworkPolicy
setAgentPool
ensureKubelet

echo "Install complete successfully"

if $REBOOTREQUIRED; then
  if [[ ! -z "${APISERVER_PRIVATE_KEY}" ]]; then
    # wait 1 minute to restart master
    echo 'reboot required, rebooting master in 1 minute'
    /bin/bash -c "shutdown -r 1 &"
  else
    echo 'reboot required, rebooting agent in 1 minute'
    shutdown -r now
  fi
fi
