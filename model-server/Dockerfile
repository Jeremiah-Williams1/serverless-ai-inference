FROM vllm/vllm-openai:latest

# Pre-fetch weights at BUILD time, not pod-start time. Lands in the default
# HF cache path (~/.cache/huggingface/hub), which vLLM's loader checks
# automatically — no --download-dir override needed on the serve side.
RUN python3 -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='facebook/opt-2.7b')"