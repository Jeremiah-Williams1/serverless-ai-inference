#!/usr/bin/env bash
set -euo pipefail

HOST_HEADER="helloworld-go.default.example.com"
MINIKUBE_IP=$(minikube ip)
NODEPORT=$(kubectl get svc kourier -n kourier-system -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
URL="http://${MINIKUBE_IP}:${NODEPORT}"

TIME_FORMAT='  time_connect:       %{time_connect}s\n  time_starttransfer: %{time_starttransfer}s (first byte back)\n  time_total:         %{time_total}s\n'

echo "== Current pod state =="
kubectl get pods -l serving.knative.dev/service=helloworld-go

echo ""
echo "If a pod is currently Running, this measurement will be WARM, not cold."
echo "To force a true cold measurement: stop sending requests, wait ~90s for it"
echo "to scale to zero (watch with: kubectl get pods -w), THEN rerun this script."
echo ""
read -p "Press enter to send the request now..." _

echo ""
echo "== Sending request =="
curl -s -o /dev/null -H "Host: ${HOST_HEADER}" -w "$TIME_FORMAT" "$URL"

echo ""
echo "== Pod state immediately after =="
kubectl get pods -l serving.knative.dev/service=helloworld-go

echo ""
echo "== Sending a second request right away (this one should be WARM) =="
curl -s -o /dev/null -H "Host: ${HOST_HEADER}" -w "$TIME_FORMAT" "$URL"