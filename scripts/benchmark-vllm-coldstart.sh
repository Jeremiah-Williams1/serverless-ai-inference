#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="vllm-opt-2-7b"
NAMESPACE="default"
HOST_HEADER="${SERVICE_NAME}.${NAMESPACE}.example.com"
WARM_REQUESTS=3
MAX_WAIT_FOR_ZERO=600     # give up waiting for scale-to-zero after this many seconds
MAX_TIME_PER_REQUEST=600  # curl --max-time; matches the ksvc's timeoutSeconds

PROMPT="The data center was silent at 3am, every GPU idle, until the first request of the day arrived and"

MINIKUBE_IP=$(minikube ip)
NODEPORT=$(kubectl get svc kourier -n kourier-system -o jsonpath='{.spec.ports[?(@.port==80)].nodePort}')
URL="http://${MINIKUBE_IP}:${NODEPORT}/v1/completions"

RESULTS_DIR="benchmarks/results"
mkdir -p "$RESULTS_DIR"
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
RESULTS_FILE="${RESULTS_DIR}/${TIMESTAMP}-vllm-coldstart.txt"

pod_count() {
  kubectl get pods -l serving.knative.dev/service="$SERVICE_NAME" -n "$NAMESPACE" --no-headers 2>/dev/null | wc -l
}

wait_for_zero() {
  local current
  current=$(pod_count)
  if [ "$current" -eq 0 ]; then
    echo "Already at 0 pods — good to go."
    return
  fi
  echo "Currently ${current} pod(s) running. Waiting for scale-to-zero (stop sending other traffic now)..."
  local waited=0
  while [ "$(pod_count)" -gt 0 ]; do
    if [ "$waited" -ge "$MAX_WAIT_FOR_ZERO" ]; then
      echo "Gave up after ${MAX_WAIT_FOR_ZERO}s — still running. Exiting without measuring."
      exit 1
    fi
    sleep 10
    waited=$((waited + 10))
    echo "  still running... (${waited}s idle so far)"
  done
  echo "Confirmed 0 pods after ~${waited}s idle."
}

send_timed_request() {
  local tmpfile
  tmpfile=$(mktemp)
  curl -s -o /dev/null --max-time "$MAX_TIME_PER_REQUEST" \
    -H "Host: ${HOST_HEADER}" -H "Content-Type: application/json" \
    -w "%{time_connect} %{time_starttransfer} %{time_total} %{http_code}\n" \
    "$URL" \
    -d "{\"model\": \"facebook/opt-2.7b\", \"prompt\": \"${PROMPT}\", \"max_tokens\": 30, \"temperature\": 0.8}" \
    > "$tmpfile" &
  local curl_pid=$!

  echo "  (request sent — a cold start can take 1-3+ min; do NOT interrupt, polling every 10s)" >&2
  local waited=0
  while kill -0 "$curl_pid" 2>/dev/null; do
    sleep 10
    waited=$((waited + 10))
    local pod_status
    pod_status=$(kubectl get pods -l serving.knative.dev/service="$SERVICE_NAME" -n "$NAMESPACE" \
      --no-headers 2>/dev/null | awk '{print $2}' | head -1)
    echo "    ...still waiting (${waited}s) — pod READY column: ${pod_status:-no pod yet}" >&2
  done
  wait "$curl_pid"
  cat "$tmpfile"
  rm -f "$tmpfile"
}

{
  echo "=== vLLM cold-start benchmark — ${TIMESTAMP} ==="
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
  COLD_STARTTRANSFER="$start"
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

  echo "-- Summary --"
  echo "  Cold time_starttransfer: ${COLD_STARTTRANSFER}s"
  echo "  Warm avg time_starttransfer (n=${WARM_REQUESTS}): ${warm_avg}s"
  speedup=$(awk -v c="$COLD_STARTTRANSFER" -v w="$warm_avg" 'BEGIN{if(w>0) printf "%.1f", c/w; else print "n/a"}')
  echo "  Cold is ~${speedup}x slower than warm"

} | tee "$RESULTS_FILE"

echo ""
echo "Full output saved to: ${RESULTS_FILE}"