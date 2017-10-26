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

# Install the Clear Containers runtime
installClearContainersRuntime() {
	# Add Clear Containers repository key
	echo "Adding Clear Containers repository key..."
	curl -sSL "https://download.opensuse.org/repositories/home:clearcontainers:clear-containers-3/xUbuntu_16.04/Release.key" | apt-key add -

	# Add Clear Container repository
	echo "Adding Clear Containers repository..."
	echo 'deb http://download.opensuse.org/repositories/home:/clearcontainers:/clear-containers-3/xUbuntu_16.04/ /' > /etc/apt/sources.list.d/cc-runtime.list

	# Install Clear Containers runtime
	echo "Installing Clear Containers runtime..."
	apt-get update
	apt-get install --no-install-recommends -y \
		cc-runtime

	# Install thin tools for devicemapper configuration
	echo "Installing thin tools to provision devicemapper..."
	apt-get install --no-install-recommends -y \
		lvm2 \
		thin-provisioning-tools

	# Load systemd changes
	echo "Loading changes to systemd service files..."
	systemctl daemon-reload

	# Enable and start Clear Containers proxy service
	echo "Enabling and starting Clear Containers proxy service..."
	systemctl enable cc-proxy
	systemctl start cc-proxy
}

# Install Go from source
installGo() {
	export GO_SRC=/usr/local/go
	export GOPATH="${HOME}/.go"

	# Remove any old version of Go
	if [[ -d "$GO_SRC" ]]; then
		rm -rf "$GO_SRC"
	fi

	# Remove any old GOPATH
	if [[ -d "$GOPATH" ]]; then
		rm -rf "$GOPATH"
	fi

	# Get the latest Go version
	GO_VERSION=$(curl -sSL "https://golang.org/VERSION?m=text")

	echo "Installing Go version $GO_VERSION..."

	# subshell
	(
	curl -sSL "https://storage.googleapis.com/golang/${GO_VERSION}.linux-amd64.tar.gz" | sudo tar -v -C /usr/local -xz
	)

	# Set GOPATH and update PATH
	echo "Setting GOPATH and updating PATH"
	export PATH="${GO_SRC}/bin:${PATH}:${GOPATH}/bin"
}

# Build and install runc
buildRunc() {
	# Clone the runc source
	echo "Cloning the runc source..."
	mkdir -p "${GOPATH}/src/github.com/opencontainers"
	(
	cd "${GOPATH}/src/github.com/opencontainers"
	git clone "https://github.com/opencontainers/runc.git"
	cd runc
	git reset --hard v1.0.0-rc4
	make BUILDTAGS="seccomp apparmor"
	make install
	)

	echo "Successfully built and installed runc..."
}

# Build and install CRI-O
buildCRIO() {
	installGo;

	# Add CRI-O repositories
	echo "Adding repositories required for cri-o..."
	add-apt-repository -y ppa:projectatomic/ppa
	add-apt-repository -y ppa:alexlarsson/flatpak
	apt-get update

	# Install CRI-O dependencies
	echo "Installing dependencies for CRI-O..."
	apt-get install --no-install-recommends -y \
		btrfs-tools \
		gcc \
		git \
		libapparmor-dev \
		libassuan-dev \
		libc6-dev \
		libdevmapper-dev \
		libglib2.0-dev \
		libgpg-error-dev \
		libgpgme11-dev \
		libostree-dev \
		libseccomp-dev \
		libselinux1-dev \
		make \
		pkg-config \
		skopeo-containers

	# Install md2man
	go get github.com/cpuguy83/go-md2man

	# Fix for templates dependency
	(
	go get -u github.com/docker/docker/daemon/logger/templates
	cd "${GOPATH}/src/github.com/docker/docker"
	mkdir -p utils
	cp -r daemon/logger/templates utils/
	)

	buildRunc;

	# Clone the CRI-O source
	echo "Cloning the CRI-O source..."
	mkdir -p "${GOPATH}/src/github.com/kubernetes-incubator"
	(
	cd "${GOPATH}/src/github.com/kubernetes-incubator"
	git clone "https://github.com/kubernetes-incubator/cri-o.git"
	cd cri-o
	git reset --hard v1.0.0
	make BUILDTAGS="seccomp apparmor"
	make install
	make install.config
	make install.systemd
	)

	echo "Successfully built and installed CRI-O..."

	# Cleanup the temporary directory
	rm -vrf "$tmpd"

	# Cleanup the Go install
	rm -vrf "$GO_SRC" "$GOPATH"

	setupCRIO;
}

# Setup CRI-O
setupCRIO() {
	# Configure CRI-O
	echo "Configuring CRI-O..."

	# Configure crio systemd service file
	systemd_CRI_O_SERVICE_FILE="/usr/local/lib/systemd/system/crio.service"
	sed -i 's#ExecStart=/usr/local/bin/crio#ExecStart=/usr/local/bin/crio -log-level debug#' "$systemd_CRI_O_SERVICE_FILE"

	# Configure /etc/crio/crio.conf
	CRI_O_CONFIG="/etc/crio/crio.conf"
	sed -i 's#storage_driver = ""#storage_driver = "devicemapper"#' "$CRI_O_CONFIG"
	sed -i 's#storage_option = \[#storage_option = \["dm.directlvm_device=/dev/sdc", "dm.thinp_percent=95", "dm.thinp_metapercent=1", "dm.thinp_autoextend_threshold=80", "dm.thinp_autoextend_percent=20", "dm.directlvm_device_force=true"#' "$CRI_O_CONFIG"
	sed -i 's#runtime = "/usr/bin/runc"#runtime = "/usr/local/sbin/runc"#' "$CRI_O_CONFIG"
	sed -i 's#runtime_untrusted_workload = ""#runtime_untrusted_workload = "/usr/bin/cc-runtime"#' "$CRI_O_CONFIG"
	sed -i 's#default_workload_trust = "trusted"#default_workload_trust = "untrusted"#' "$CRI_O_CONFIG"

	# Load systemd changes
	echo "Loading changes to systemd service files..."
	systemctl daemon-reload
}

function ensureCRIO() {
	# Enable and start cri-o service
	# Make sure this is done after networking plugins are installed
	echo "Enabling and starting cri-o service..."
	systemctl enable crio crio-shutdown
	systemctl start crio
}

ensureDocker
installClearContainersRuntime
buildCRIO
configNetworkPolicy
setAgentPool
ensureCRIO
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
