#!/usr/bin/env bash
set -euo pipefail

KNATIVE_VERSION="knative-v1.23.0"

echo "== Checking current context =="
kubectl config current-context
echo "(Ctrl+C now if this isn't your minikube context)"
sleep 3

echo "== Installing Knative Serving CRDs =="
kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-crds.yaml"

echo "== Installing Knative Serving core =="
kubectl apply -f "https://github.com/knative/serving/releases/download/${KNATIVE_VERSION}/serving-core.yaml"

echo "== Installing Kourier networking layer =="
kubectl apply -f "https://github.com/knative-extensions/net-kourier/releases/download/${KNATIVE_VERSION}/kourier.yaml"

echo "== Setting Kourier as the default ingress class =="
kubectl patch configmap/config-network \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"ingress-class":"kourier.ingress.networking.knative.dev"}}'

echo "== Setting a curl-friendly domain (no real DNS needed for minikube) =="
kubectl patch configmap/config-domain \
  --namespace knative-serving \
  --type merge \
  --patch '{"data":{"example.com":""}}'

echo ""
echo "== Waiting for knative-serving pods to be ready (this can take a minute) =="
kubectl wait --for=condition=Ready pods --all -n knative-serving --timeout=180s || true

echo ""
echo "== knative-serving pods =="
kubectl get pods -n knative-serving
echo ""
echo "SCREENSHOT THIS OUTPUT — first checklist item in docs/log.md"

echo ""
echo "== kourier-system pods (the actual gateway) =="
kubectl get pods -n kourier-system

echo ""
echo "== Kourier service (note the port for curl -H \"Host:\" later) =="
kubectl --namespace kourier-system get service kourier
