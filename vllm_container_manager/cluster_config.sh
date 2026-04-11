#!/usr/bin/env bash
# cluster_config.sh
#
# Model naming convention (comma-separated, all served simultaneously):
#   role,role-family,detail
#   e.g. chat-heavy,chat-heavy-qwen,qwen35-122b-a10b
#
# Qwen3.5 GDN/Mamba notes:
#   - compressed-tensors quant format: do NOT set QUANTIZATION flag
#   - MAX_NUM_BATCHED_TOKENS>=8192 required (Mamba block_size=4176)
#   - GPU_MEMORY_UTILIZATION=0.85 max (0.90 triggers Ray OOM on unified memory)
#   - KV_CACHE_DTYPE=auto on stock v0.17.1 (fp8 FlashInfer lacks sm_121 kernels)

declare -gA NODES=(
  [1]="192.168.2.42:magnesium:10.10.10.1"
  [2]="192.168.2.43:aluminium:10.10.10.2"
  [3]="192.168.2.44:silicon:10.10.10.3"
  [4]="192.168.2.45:phosphorus:10.10.10.4"
)

# Custom Docker images - map name to full image path
# Add new images here, then reference them in model profiles via DOCKER_IMAGE=name
declare -gA CUSTOM_IMAGES=(
  [vllm-official]="vllm/vllm-openai:v0.17.1"
  [vllm-gb10-community]="scitrera/dgx-spark-vllm:0.14.0rc2-t5"
  [vllm-gb10-old]="hellohal2064/vllm-dgx-spark-gb10:latest"
  [vllm-nvidia-official]="nvcr.io/nvidia/vllm:25.09-py3"
  [vllm-gb10-0.18.0]="192.168.2.42:5000/vllm-gb10:0.18.0"
  [vllm-gb10-0.18.0_b2]="192.168.2.42:5000/vllm-gb10:0.18.0_b2"
  [vllm-community-eugr]="192.168.2.42:5000/vllm-community-eugr:latest"
)

# Images that require a specific entrypoint (NGC-based images need their setup script)
# Default (if not listed): /bin/bash
declare -gA IMAGE_ENTRYPOINTS=(
  [vllm-community-eugr]="/opt/nvidia/nvidia_entrypoint.sh"
  [vllm-nvidia-official]="/opt/nvidia/nvidia_entrypoint.sh"
)

declare -gA MODELS=(

  # =========================================================================
  # Qwen3 (standard transformer, NOT GDN — no Mamba quirks)
  # =========================================================================

  # Qwen3-VL-235B: Vision+Language, TP=2
  # NOTE: Qwen3 (not 3.5) so no GDN regression on v0.18.0.
  # CUBLAS_STATUS_NOT_INITIALIZED on custom image — use stock only.
  [qwen3-vl-235b]="
    DOCKER_IMAGE=vllm-official
    MODEL_DIR=/opt/ai-models/hf/qwen3/Qwen3-VL-235B-A22B-Thinking-AWQ
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-qwen,qwen3-vl-235b-a22b
    TENSOR_PARALLEL_SIZE=2
    QUANTIZATION=awq_marlin
    MAX_MODEL_LEN=200000
    MAX_NUM_SEQS=2
    GPU_MEMORY_UTILIZATION=0.90
    ENABLE_PREFIX_CACHING=0
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=bfloat16
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "

  # =========================================================================
  # DeepSeek (MLA architecture — parked due to CUBLAS sm_121 bug)
  # =========================================================================

  # DeepSeek V3 (cognitivecomputations AWQ) — BROKEN: fused shard validation
  [deepseek-v3-dense]="
    DOCKER_IMAGE=vllm-gb10-0.18.0
    MODEL_DIR=/opt/ai-models/hf/cognitivecomputations/DeepSeek-V3-AWQ
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-deepseek,deepseek-v3-671b-a37b
    TENSOR_PARALLEL_SIZE=4
    MAX_MODEL_LEN=143360
    MAX_NUM_SEQS=1
    GPU_MEMORY_UTILIZATION=0.88
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "

  # DeepSeek V3.2 (QuantTrio AWQ) — BROKEN: requires sparse MLA (DSA), no backend for sm_121
  [deepseek-v3]="
    DOCKER_IMAGE=vllm-gb10-0.18.0
    MODEL_DIR=/opt/ai-models/hf/QuantTrio/DeepSeek-V3.2-AWQ
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-deepseek,deepseek-v3.2-671b
    TENSOR_PARALLEL_SIZE=4
    QUANTIZATION=awq
    MAX_MODEL_LEN=143360
    MAX_NUM_SEQS=1
    GPU_MEMORY_UTILIZATION=0.90
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "

  # DeepSeek V3.1 (QuantTrio AWQ) — BROKEN: CUBLAS_STATUS_INVALID_VALUE on MLA dequant
  [deepseek-v3.1]="
    DOCKER_IMAGE=vllm-gb10-0.18.0_b2
    MODEL_DIR=/opt/ai-models/hf/QuantTrio/DeepSeek-V3.1-AWQ
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-deepseek,deepseek-v3.1-685b-a37b
    TENSOR_PARALLEL_SIZE=4
    QUANTIZATION=awq_marlin
    MAX_MODEL_LEN=143360
    MAX_NUM_SEQS=1
    GPU_MEMORY_UTILIZATION=0.88
    DTYPE=bfloat16
    ENFORCE_EAGER=1
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
  "

  # DeepSeek R1 (AWQ) — BROKEN: same CUBLAS issue as V3.1
  [deepseek-r1]="
    DOCKER_IMAGE=vllm-gb10-0.18.0
    MODEL_DIR=/opt/ai-models/hf/DeepSeek-R1-AWQ
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-deepseek,deepseek-r1-671b-a37b
    TENSOR_PARALLEL_SIZE=4
    QUANTIZATION=awq
    MAX_MODEL_LEN=163840
    MAX_NUM_SEQS=2
    GPU_MEMORY_UTILIZATION=0.90
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
  "

  # =========================================================================
  # Qwen3.5 (GDN/Mamba hybrid — compressed-tensors quant format)
  # =========================================================================


  # Qwen3.5-397B: Heavy mode, TP=4 (all nodes)
  # 64 MoE experts requires TP divisible by 64 — TP=3 fails, TP=4 or TP=2 only
  # ~200GB model, ~50GB/node at TP=4, ~59GB KV headroom/node at 0.85
  # eugr community benchmarks: ~37 tok/s single-stream, ~103 tok/s aggregate (4 users)
  [qwen3.5-397b]="
    DOCKER_IMAGE=vllm-community-eugr
    MODEL_DIR=/opt/ai-models/hf/Intel/Qwen3.5-397B-A17B-int4-AutoRound
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-qwen,qwen35-397b-a17b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=4
    MAX_MODEL_LEN=250000
    MAX_NUM_SEQS=2
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.85
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "

  # Qwen3.5-122B: Daily driver, TP=2, aggressive 16-stream config
  # Perf (stock v0.17.1): 1s=19.5t/s, 2s=39.4, 3s=49.2, 4s=59.5, 8s=94.4, 12s=115.2
  # eugr community benchmarks: ~56 tok/s dual Spark — expect significant improvement
  [qwen3.5-122b]="
    DOCKER_IMAGE=vllm-official
    MODEL_DIR=/opt/ai-models/hf/cyankiwi/Qwen3.5-122B-A10B-AWQ-4bit
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-qwen,qwen35-122b-a10b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=2
    MAX_MODEL_LEN=250000
    MAX_NUM_SEQS=16
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.85
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "

  # Qwen3.5-9B: Vision (chat-peeks), single node, cohabits with TTS/STT/ComfyUI
  # ~5GB model at 0.30 util = ~38GB to vLLM, leaves ~90GB for cohabitants
  [qwen3.5-9b]="
    DOCKER_IMAGE=vllm-community-eugr
    MODEL_DIR=/opt/ai-models/hf/cyankiwi/Qwen3.5-9B-AWQ-4bit
    SERVED_MODEL_NAME=chat-peeks,chat-peeks-qwen,qwen35-9b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=1
    MAX_MODEL_LEN=65536
    MAX_NUM_SEQS=12
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.30
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8002
    RAY_OBJECT_STORE_GB=1
    ENFORCE_EAGER=0
  "
)

# Default image if model profile doesn't specify DOCKER_IMAGE
DEFAULT_VLLM_IMAGE="vllm-official"

SSH_USER="admin"
SSH_KEY=""
LOG_DIR="/opt/ai-tools/logs/vllm-cluster"
