# Project 5 — Serverless AI Inference (Cold-Start Optimization)

Knative-based scale-to-zero serving for a vLLM model endpoint on a single
GPU, with real instrumentation of cold-start latency and real optimization
attempts against it — not a tutorial walkthrough, a measured investigation.

**Core question:** running GPU inference capacity 24/7 for spiky traffic
wastes money. Scale-to-zero fixes that, but cold starts for a multi-GB
model are a real, specific, named cost. How big is that cost, where does
it actually come from, and what can be done about it?

**Result:** baseline cold start ~172s avg (single T4, `facebook/opt-2.7b`)
vs. ~0.7s warm (~240x). Two targeted optimizations — grounded in the
model server's own log output, not guesswork — brought cold start down
to a stabilized ~135s avg (~21% reduction). Full breakdown and honest
account of what's still unsolved: `docs/project-5-final-summary.md`.

---

## Architecture

```
curl (client)
  │
  ▼
Docker bridge network (host ↔ minikube container)
  │
  ▼
minikube container = Kubernetes node
  │
  ▼
kourier Service (Kubernetes Service, type NodePort)
  │
  ▼
Kourier gateway pod (Envoy) — reads the Host header to pick a Revision
  │
  ▼
Knative Route → Activator
  │
  ├─ pod already warm → forwarded via queue-proxy sidecar (milliseconds)
  │
  └─ zero pods running → Activator buffers the request, autoscaler
     starts a pod (image already local → straight to model load →
     compile → CUDA graph capture → ready), then forwards the buffered
     request
```

The Activator is the piece that makes scale-to-zero safe for synchronous
HTTP: it sits *in* the request path (unlike KEDA/HPA, which only watch
metrics from the side), so it has something to buffer against when there
are zero pods and therefore no metric source yet to trigger scale-up from.

---

## Repo structure

```
docs/                     narrative: log.md (running build log),
                           project-5-final-summary.md (results),
                           architecture/ (diagrams)
knative/
  service/                Knative Service (ksvc) manifests
  serving-install/        notes on the Knative Serving install itself
model-server/             Dockerfile for the weights-baked-in vLLM image
scripts/                  repeatable commands (install, benchmark, etc.)
eks/                      eks.yaml, for when minikube isn't enough
benchmarks/results/       raw timestamped benchmark output
```

---

## Prerequisites

- An EC2 GPU instance — used a **g4dn.2xlarge** (8 vCPU / 32 GB RAM / 1x T4).
  A g4dn.xlarge (4 vCPU) is *not* enough — Knative alone needs 6 CPU minimum,
  and CPU starvation will contaminate cold-start measurements once vLLM is
  also running.
- AMI: **AWS Deep Learning OSS Nvidia Driver AMI (Amazon Linux 2023)** —
  ships NVIDIA driver, CUDA, Docker, and the NVIDIA Container Toolkit
  preinstalled. Does **not** ship conda (it's a plain venv at
  `/opt/pytorch`) or kubectl/minikube — those get installed below.

---

## Setup, in order

### 1. Bootstrap the environment
```
./bootstrap-env.sh
```
Installs kubectl, minikube, and conda; wires the NVIDIA Container Toolkit
into Docker. Log out/in (or `newgrp docker`) afterward if you were just
added to the docker group.

### 2. Start minikube with GPU passthrough, sized explicitly
```
minikube start --driver=docker --container-runtime=docker --gpus=all --cpus=7 --memory=14000
```
Don't skip the explicit `--cpus`/`--memory` — minikube's default sizing
does not mean "use the whole host," and will silently undersize the
cluster relative to real instance capacity.

Verify the GPU actually made it through to Kubernetes (not just the host):
```
kubectl get nodes -o=custom-columns=NAME:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu
docker exec minikube nvidia-smi
```

### 3. Install Knative Serving + Kourier
```
./scripts/install-knative.sh
```
Kourier chosen over Istio deliberately — no sidecar injection into
workload pods, one less thing to debug when measuring cold-start latency.

### 4. Prove the mechanism with a trivial non-GPU service first
```
kubectl apply -f knative/service/helloworld-minikube.yaml
```
Confirms scale-to-zero, the Activator, and the whole networking path
work, with zero GPU-layer risk clouding the result. Baseline cold start
here: ~1.08s (almost entirely pod scheduling, since there's no model to
load) — proves the mechanism, not yet the real problem.

### 5. Deploy the real model
```
kubectl apply -f knative/service/vllm-opt-2-7b.yaml
```
`facebook/opt-2.7b`, chosen specifically: large enough for a genuinely
measurable cold start (~5.4GB weights), ungated (no HF token needed),
comfortably fits a 15GB T4 with headroom for KV cache.

Note the resource overrides in the manifest — Knative's defaults
(750Mi ephemeral-storage limit, 200Mi memory limit) will evict/OOM a
model workload if left alone.

### 6. Benchmark
```
./scripts/benchmark-vllm-coldstart.sh
```
Waits for confirmed scale-to-zero, times a cold request (`time_starttransfer`
is the number that matters — first-byte time, where Activator buffering +
pod boot cost shows up), then averages several warm requests. Results
saved to `benchmarks/results/`.

### 7. (Optional) Build and deploy the optimized image
```
eval $(minikube docker-env)
docker build -t dev.local/vllm-opt-2-7b-baked:latest model-server/
kubectl apply -f knative/service/vllm-opt-2-7b.yaml   # already points at the baked image
```
The `dev.local/` prefix matters — Knative resolves image tags to digests
against a registry *before* the kubelet's `imagePullPolicy` is even
consulted; `dev.local` is in Knative's built-in skip-list
(`registries-skipping-tag-resolving`), so a locally-built image with no
registry doesn't get mistaken for a Docker Hub lookup.

---

## Key findings

See `docs/project-5-final-summary.md` for full numbers. Short version:

- The **biggest** cold-start cost (~60s of ~172s) is CUDA-graph capture +
  KV-cache profiling — GPU-runtime-bound, not fixable by image caching.
  vLLM does this capture *twice* by default (a throwaway profiling pass,
  then the real one); `VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0` skips
  the first pass.
- The **second biggest** cost (~34s) was the Hugging Face weight download
  — genuinely fixable by baking weights into the image at build time.
- Combined, these two changes took cold start from ~172s avg to a
  stabilized ~135s avg (~21% reduction) — a result predicted in advance
  from the model server's own log timings, then confirmed by measurement.
- What's left unsolved is structural: the CUDA-graph phase trades off
  against `enforce_eager=True` (faster startup, slower steady-state
  inference) rather than having a clean "just cache it" fix.

---

## Known gotchas hit along the way

- Knative's request-start timeout defaults (`revision-response-start-timeout-seconds`,
  `revision-timeout-seconds` = 300s each, capped by `max-revision-timeout-seconds`
  = 600s) are tuned for web apps, not model loading — set `timeoutSeconds`
  explicitly on the ksvc.
- `READY 2/2` on a pod means 2 *containers* in 1 pod (app + queue-proxy
  sidecar), not 2 replicas — replica count lives on the Deployment Knative
  creates under the hood, not on the pod itself.
- minikube's docker driver means the "node" is itself a Docker container —
  `minikube ip` is that container's address, not the host's; NodePort
  services are reachable there directly, no `minikube tunnel` needed if
  you're curling from the same host.