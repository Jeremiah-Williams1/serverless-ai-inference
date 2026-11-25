#!/usr/bin/env bash
# Stage 0 gates, repeatable. Prereq: stage0-bootstrap.sh ran (k3s up, node Ready).
# Expects under oci-extension/manifests/stage0/:
#   imgvol-test.yaml  ksvc-imgvol.yaml  gpu-smoke-test.yaml
set -euo pipefail

cd "$(dirname "$0")/.."          # oci-extension/
M=manifests/stage0
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

echo "== Gate 1 (0a): runtime mounts an image as a volume =="
kubectl delete pod imgvol-test --ignore-not-found
kubectl apply -f "$M/imgvol-test.yaml"
kubectl wait --for=condition=Ready pod/imgvol-test --timeout=120s
kubectl exec imgvol-test -- ls /mnt/art
if kubectl exec imgvol-test -- touch /mnt/art/x 2>/dev/null; then
  echo "FAIL: volume is writable"; exit 1
else
  echo "PASS: volume is read-only"
fi

echo
echo "== Gate 3 (0c): GPU through k3s containerd =="
sudo grep nvidia /var/lib/rancher/k3s/agent/etc/containerd/config.toml \
  || { echo "FAIL: k3s did not detect the NVIDIA runtime (try: sudo systemctl restart k3s)"; exit 1; }

if ! kubectl get runtimeclass nvidia >/dev/null 2>&1; then
  cat <<'EOF' | kubectl apply -f -
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia
EOF
fi

kubectl apply -f https://raw.githubusercontent.com/NVIDIA/k8s-device-plugin/v0.17.0/deployments/static/nvidia-device-plugin.yml
DS="$(kubectl -n kube-system get ds -o name | grep -i nvidia-device-plugin | head -n1)"
echo "device plugin: ${DS}"
kubectl -n kube-system patch "${DS}" --type merge \
  -p '{"spec":{"template":{"spec":{"runtimeClassName":"nvidia"}}}}'
kubectl -n kube-system rollout status "${DS}" --timeout=180s
sleep 5
kubectl describe node | grep -A6 "^Capacity"

kubectl delete pod gpu-smoke-test --ignore-not-found
kubectl apply -f "$M/gpu-smoke-test.yaml"
kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/gpu-smoke-test --timeout=240s
kubectl logs gpu-smoke-test

echo
echo "== Gate 2 (0b): Knative accepts image volumes only after the flag =="
V=v1.23.0
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-${V}/serving-crds.yaml"
kubectl apply -f "https://github.com/knative/serving/releases/download/knative-${V}/serving-core.yaml"
kubectl wait --for=condition=Available deployment --all -n knative-serving --timeout=300s

echo "-- flag default (expect rejection) --"
kubectl apply --dry-run=server -f "$M/ksvc-imgvol.yaml" || echo "(rejected, as expected)"

kubectl patch cm config-features -n knative-serving --type merge \
  -p '{"data":{"kubernetes.podspec-volumes-image":"enabled"}}'
sleep 15
echo "-- flag enabled (expect success) --"
kubectl apply --dry-run=server -f "$M/ksvc-imgvol.yaml"

echo
echo "All Stage 0 gates done. Paste the output into log.md."