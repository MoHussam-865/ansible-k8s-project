#!/bin/bash

set -e

K8S_VERSION="v1.31"
CALICO_VERSION="v3.25.0"

# m = master, anything else = worker
if [[ "$1" == "m" ]]; then
    MASTER=true
else
    MASTER=false
fi


echo "=== Kubernetes setup started ==="


# -------------------------------
# Check root privileges
# -------------------------------

if [[ $EUID -eq 0 ]]; then
    echo "Do not run this script as root. Use a sudo user."
    exit 1
fi


# -------------------------------
# Disable swap
# -------------------------------

echo "Checking swap..."

if swapon --show | grep -q .; then
    echo "Disabling swap..."
    sudo swapoff -a
    sudo sed -i '/swap/s/^/#/' /etc/fstab
else
    echo "Swap already disabled"
fi


# -------------------------------
# Kernel modules
# -------------------------------

echo "Configuring kernel modules..."

cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF


sudo modprobe overlay
sudo modprobe br_netfilter


# -------------------------------
# Sysctl configuration
# -------------------------------

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
EOF


sudo sysctl --system


# -------------------------------
# Install containerd
# -------------------------------

if ! command -v containerd &>/dev/null; then

    echo "Installing containerd..."

    sudo apt update

    sudo apt install -y containerd apt-transport-https ca-certificates curl gpg conntrack


else

    echo "containerd already installed"

fi



# Configure containerd

if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null
then

    echo "Configuring containerd..."

    sudo mkdir -p /etc/containerd

    containerd config default | sudo tee /etc/containerd/config.toml

    sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

    sudo systemctl restart containerd

fi


sudo systemctl enable containerd



# -------------------------------
# Kubernetes repository
# -------------------------------

if [ ! -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg ]; then

    echo "Adding Kubernetes repository..."

    sudo mkdir -p -m 755 /etc/apt/keyrings


    curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg


    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S_VERSION/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list

fi



# -------------------------------
# Install Kubernetes packages
# -------------------------------

if ! command -v kubeadm &>/dev/null; then

    echo "Installing Kubernetes..."

    sudo apt update

    sudo apt install -y kubelet kubeadm kubectl

    sudo apt-mark hold kubelet kubeadm kubectl

else

    echo "Kubernetes already installed"

fi



# -------------------------------
# Worker node stop here
# -------------------------------

if [[ "$MASTER" != true ]]; then

    echo "Worker node prepared."

    exit 0

fi



# -------------------------------
# Initialize master
# -------------------------------

if [ -f /etc/kubernetes/admin.conf ]; then

    echo "Cluster already initialized."

else

    echo "Initializing Kubernetes cluster..."

    sudo kubeadm init

fi



# -------------------------------
# Configure kubectl
# -------------------------------

mkdir -p $HOME/.kube


if [ ! -f $HOME/.kube/config ]; then

    sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config

    sudo chown $(id -u):$(id -g) $HOME/.kube/config

fi



# -------------------------------
# Install network plugin
# -------------------------------

if ! kubectl get pods -n kube-system | grep -q calico; then

    echo "Installing Calico..."

    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml

else

    echo "Calico already installed"

fi



# -------------------------------
# Generate worker join command
# -------------------------------

echo ""
echo "Worker join command:"
echo ""

kubeadm token create --print-join-command


echo ""
echo "=== Kubernetes setup completed ==="
