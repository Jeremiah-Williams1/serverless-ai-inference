#!/usr/bin/env bash
# Stage 0 bootstrap: host preflight, single-node k3s (bundles containerd),
# then a version-gate report. Run on the g4dn.2xlarge, as ec2-user.
#
# Override the k3s release channel if the gate report says versions are too old:
#   K3S_CHANNEL=latest ./stage0-bootstrap.sh
set -euo pipefail

K3S_CHANNEL="${K3S_CHANNEL:-stable}"
MIN_CONTAINERD="2.1.0"
MIN_K8S="1.35"

ver_ge() { [ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" = "$2" ]; }

echo "== 1. Host preflight =="
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader \
  || { echo "FAIL: nvidia-smi does not work on the host"; exit 1; }
command -v docker >/dev/null && echo "docker: $(docker --version)" \
  || echo "WARN: docker missing (needed later to build images)"
command -v nvidia-ctk >/dev/null && echo "nvidia-ctk: $(nvidia-ctk --version | head -n1)" \
  || echo "WARN: nvidia-ctk missing (needed for Stage 0c)"
echo "free disk on /:"; df -h / | tail -n1
echo "cpus: $(nproc)  mem: $(free -g | awk '/Mem:/{print $2}') GB"

echo
echo "== 2. Install k3s (channel: ${K3S_CHANNEL}) =="
if command -v k3s >/dev/null 2>&1; then
  echo "k3s already installed, skipping install"
else
  curl -sfL https://get.k3s.io | sudo env \
    INSTALL_K3S_CHANNEL="${K3S_CHANNEL}" \
    INSTALL_K3S_EXEC="--write-kubeconfig-mode 644" sh -
fi

mkdir -p "$HOME/.kube"
cp /etc/rancher/k3s/k3s.yaml "$HOME/.kube/config"
export KUBECONFIG="$HOME/.kube/config"

echo
echo "== 3. Wait for the node =="
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl get nodes -o wide

echo
echo "== 4. Version gate report =="
K8S_VER="$(kubectl get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
RUNTIME_LINE="$(sudo k3s crictl version | awk '/RuntimeName|RuntimeVersion/{printf "%s ", $2}')"
CONTAINERD_VER="$(sudo k3s crictl version | awk '/RuntimeVersion/{print $2}' | sed 's/^v//')"
K8S_MM="$(echo "${K8S_VER#v}" | cut -d. -f1,2)"

echo "kubelet:  ${K8S_VER}   (want >= ${MIN_K8S})"
echo "runtime:  ${RUNTIME_LINE}   (want containerd >= ${MIN_CONTAINERD})"

ver_ge "${K8S_MM}" "${MIN_K8S}" && echo "k8s gate:        PASS" || echo "k8s gate:        CHECK (try K3S_CHANNEL=latest)"
ver_ge "${CONTAINERD_VER}" "${MIN_CONTAINERD}" && echo "containerd gate: PASS" || echo "containerd gate: CHECK (try K3S_CHANNEL=latest)"

echo
echo "Paste sections 1 and 4 back into the chat. Next: Stage 0a (busybox image-volume pod)."
