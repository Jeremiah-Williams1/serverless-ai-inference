#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="${1:?usage: $0 <service> <label>}"
LABEL="${2:?usage: $0 <service> <label>}"
MODEL_NAME="${MODEL_NAME:-facebook/opt-2.7b}"
NAMESPACE="default"
HOST_HEADER="${SERVICE_NAME}.${NAMESPACE}.example.com"
WARM_REQUESTS=3
MAX_WAIT_FOR_ZERO=900
MAX_TIME_PER_REQUEST=600
SEL="serving.knative.dev/service=${SERVICE_NAME}"

PROMPT="The data center was silent at 3am, every GPU idle, until the first request of the day arrived and"

NODEPORT=$(kubectl get svc kourier -n kourier-system -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
URL="http://localhost:${NODEPORT}/v1/completions"

RESULTS_DIR="oci-extension/benchmarks/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
RESULTS_FILE="${RESULTS_DIR}/${TIMESTAMP}-${LABEL}-coldstart.txt"

pod_count() {
  kubectl get pods -l "$SEL" -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l
}

wait_for_zero() {
  if [ "$(pod_count)" -eq 0 ]; then
    echo "Already at 0 pods."
    return
  fi
  echo "Waiting for scale-to-zero (send no other traffic)..."
  local waited=0
  while [ "$(pod_count)" -gt 0 ]; do
    if [ "$waited" -ge "$MAX_WAIT_FOR_ZERO" ]; then
      echo "Gave up after ${MAX_WAIT_FOR_ZERO}s. Exiting without measuring."
      exit 1
    fi
    sleep 10
    waited=$((waited + 10))
    echo "  ${waited}s: $(kubectl get pods -l "$SEL" -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{printf "%s[%s] ", $1, $3}')"
  done
  echo "Confirmed 0 pods after ~${waited}s."
}

send_timed_request() {
  local tmpfile
  tmpfile=$(mktemp)
  curl -s -o /dev/null --max-time "$MAX_TIME_PER_REQUEST" \
    -H "Host: ${HOST_HEADER}" -H "Content-Type: application/json" \
    -w "%{time_connect} %{time_starttransfer} %{time_total} %{http_code}\n" \
    "$URL" \
    -d "{\"model\": \"${MODEL_NAME}\", \"prompt\": \"${PROMPT}\", \"max_tokens\": 30, \"temperature\": 0.8}" \
    > "$tmpfile" &
  local curl_pid=$!
  echo "  (request sent; a cold start can take minutes, do NOT interrupt)" >&2
  local waited=0
  while kill -0 "$curl_pid" 2>/dev/null; do
    sleep 10
    waited=$((waited + 10))
    local pod_status
    pod_status=$(kubectl get pods -l "$SEL" -n "$NAMESPACE" --no-headers 2>/dev/null | awk '{print $2}' | head -1)
    echo "    ...${waited}s, pod READY: ${pod_status:-no pod yet}" >&2
  done
  wait "$curl_pid"
  cat "$tmpfile"
  rm -f "$tmpfile"
}

{
  echo "=== ${LABEL} cold-start benchmark: ${TIMESTAMP} ==="
  echo "Service: ${SERVICE_NAME}"
  echo ""
  echo "-- Waiting for scale-to-zero --"
  wait_for_zero
  echo ""

  echo "-- Sending COLD request --"
  read -r conn start total code < <(send_timed_request)
  echo "  time_connect:       ${conn}s"
  echo "  time_starttransfer: ${start}s   <-- the cold-start number"
  echo "  time_total:         ${total}s"
  echo "  http_status:        ${code}"
  COLD="$start"
  echo ""

  echo "-- Sending ${WARM_REQUESTS} WARM requests --"
  warm_total=0
  for i in $(seq 1 "$WARM_REQUESTS"); do
    read -r conn start total code < <(send_timed_request)
    echo "  [${i}] time_starttransfer: ${start}s   time_total: ${total}s   http_status: ${code}"
    warm_total=$(awk -v a="$warm_total" -v b="$start" 'BEGIN{print a+b}')
  done
  warm_avg=$(awk -v t="$warm_total" -v n="$WARM_REQUESTS" 'BEGIN{printf "%.4f", t/n}')
  echo ""

  echo "-- Evidence from the pod (still alive right now) --"
  kubectl logs -l "$SEL" -n "$NAMESPACE" -c user-container --tail=-1 \
    > "${RESULTS_DIR}/${TIMESTAMP}-${LABEL}-vllm.log" 2>&1 || true
  kubectl describe pod -l "$SEL" -n "$NAMESPACE" \
    > "${RESULTS_DIR}/${TIMESTAMP}-${LABEL}-pod.txt" 2>&1 || true
  POD=$(kubectl get pods -l "$SEL" -n "$NAMESPACE" -o name | head -n1)
  echo "HF cache size inside the pod:"
  kubectl exec "$POD" -n "$NAMESPACE" -c user-container -- sh -c \
    'du -sh /root/.cache/huggingface 2>/dev/null; ls -lh /root/.cache/huggingface/hub/models--*/snapshots/*/ 2>/dev/null' || true
  echo ""

  echo "-- Summary --"
  echo "  Cold time_starttransfer: ${COLD}s"
  echo "  Warm avg (n=${WARM_REQUESTS}): ${warm_avg}s"
} | tee "$RESULTS_FILE"

echo ""
echo "Saved: ${RESULTS_FILE} (+ -vllm.log and -pod.txt next to it)"