# Project 5 — Final Results Summary

## The core finding

Cold start for a single T4 serving `facebook/opt-2.7b` via vLLM on Knative
started at **~172s average** (baseline, 3 runs: 169.7s / 181.7s / 164.4s)
against a warm-request baseline of **~0.7s** — roughly 240x.

Two optimizations, both grounded in vLLM's own log output rather than
guesswork, brought that down to a **stabilized ~135s average**
(4 runs post-bake: 157.3 / 143.6 / 135.9 / 134.2 — first run elevated from
page-cache warmup, then stable) — a **~37s, ~21% reduction**.

## What actually cost the time (from vLLM's own phase timings)

| Phase | Cost | Addressed? |
|---|---|---|
| Process/CLI startup | ~22s | not attempted |
| Weight download (HF Hub) | ~34s | **fixed** — baked into custom image |
| Weight load to GPU + setup | ~11s | not attempted |
| torch.compile | ~12.5s | partially — profiling-pass env var |
| KV-cache profiling + CUDA graph capture (2 passes) | **~60s** | **not fixable via caching** — GPU-runtime-bound |
| Pod scheduling + readiness-probe lag | ~25s (est.) | not attempted |

## The two optimizations, in order

1. **`VLLM_MEMORY_PROFILER_ESTIMATE_CUDAGRAPHS=0`** — disables a redundant
   first CUDA-graph capture pass that vLLM runs purely to estimate memory
   usage before doing the real capture. Found directly in vLLM's own log
   output (`gpu_worker.py:655`), not external research. Alone, showed no
   clear signal against baseline noise — but compounded with optimization 2.

2. **Baked model weights into a custom image** (`model-server/Dockerfile`,
   `FROM vllm/vllm-openai:latest` + `snapshot_download` at build time).
   Eliminates the ~34s Hugging Face download from every cold start,
   turning it into a one-time build-time cost instead.

## The real gotcha hit along the way (worth including in the post)

Knative performs its own **tag-to-digest resolution** against a registry
before the kubelet's `imagePullPolicy` is even consulted — a locally-built
image with no registry prefix defaults to assuming Docker Hub, which
fails with a 401 for an image that was never pushed anywhere. Fix:
Knative ships a built-in skip-list (`registries-skipping-tag-resolving`,
default `kind.local,ko.local,dev.local`) — prefixing the local image tag
with `dev.local/` was enough. Two separate gates (Knative's digest
resolution, then the kubelet's actual pull), not one.

## What's left unsolved, honestly

The ~60s CUDA-graph-capture + KV-cache-profiling phase is now the single
largest remaining cost — and it's tied to live GPU memory state at
runtime, which doesn't have an obvious "bake it into the image" fix.
`enforce_eager=True` would skip it entirely, at the cost of slower
steady-state per-token inference — a real tradeoff (startup latency vs.
throughput), not a free win, and a reasonable place to end the writeup:
solved the addressable part, named the part that's structurally hard.