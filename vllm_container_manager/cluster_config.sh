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
#   - GPU_MEMORY_UTILIZATION=0.80 recommended (unified memory + Ray OOM at 0.95)
#   - RAY_memory_usage_threshold=0.98 set in orchestrator for all profiles
#
# MODEL_DIR path convention:
#   Local SSD:  /opt/ai-models/hf/<vendor>/<model>
#   NFS (NAS):  /mnt/network/data/models/huggingface/hf/<vendor>/<model>
#   NEVER use:  /mnt/network/ai-models/...  (that's the SMB admin mount, not runtime)

declare -A NODES=(
  [1]="192.168.2.42:magnesium:10.10.10.1"
  [2]="192.168.2.43:aluminium:10.10.10.2"
  [3]="192.168.2.44:silicon:10.10.10.3"
  [4]="192.168.2.45:phosphorus:10.10.10.4"
)

# Custom Docker images - map name to full image path
# Add new images here, then reference them in model profiles via DOCKER_IMAGE=name
declare -A CUSTOM_IMAGES=(
  [vllm-official]="vllm/vllm-openai:v0.17.1"
  [vllm-gb10-community]="scitrera/dgx-spark-vllm:0.14.0rc2-t5"
  [vllm-gb10-old]="hellohal2064/vllm-dgx-spark-gb10:latest"
  [vllm-nvidia-official]="nvcr.io/nvidia/vllm:25.09-py3"
  [vllm-gb10-0.18.0]="192.168.2.42:5000/vllm-gb10:0.18.0"
  [vllm-gb10-0.18.0_b2]="192.168.2.42:5000/vllm-gb10:0.18.0_b2"
  [vllm-community-eugr]="192.168.2.42:5000/vllm-community-eugr:latest"
  [vllm-qwen35-v2]="192.168.2.42:5000/vllm-qwen35-v2:latest"
  [vllm-sm121]="192.168.2.42:5000/vllm-sm121:latest"
  [vllm-sm121-397b]="192.168.2.42:5000/vllm-sm121-397b:latest"
  [vllm-node]="192.168.2.42:5000/vllm-node:latest"
  [vllm-cluster-universal]="192.168.2.42:5000/vllm-cluster-universal:2026-05-29_b03"
  [vllm-eugr-0.22.0]="192.168.2.42:5000/vllm-eugr-0.22.0:2026-06-04_b01"
  [vllm-jasl-ds4]="192.168.2.42:5000/vllm-jasl-ds4:2026-06-05_b01"
  [vllm-pasta]="192.168.2.42:5000/vllm-pasta:2026-06-12_b03"
)

# Images that require a specific entrypoint (NGC-based images need their setup script)
# Default (if not listed): /bin/bash
declare -A IMAGE_ENTRYPOINTS=(
  [vllm-community-eugr]="/opt/nvidia/nvidia_entrypoint.sh"
  [vllm-nvidia-official]="/opt/nvidia/nvidia_entrypoint.sh"
  [vllm-qwen35-v2]="/opt/nvidia/nvidia_entrypoint.sh"
  [vllm-sm121]="/opt/nvidia/nvidia_entrypoint.sh"
  [vllm-sm121-397b]="/opt/nvidia/nvidia_entrypoint.sh"
  [vllm-eugr-0.22.0]="/opt/nvidia/nvidia_entrypoint.sh"
  [vllm-cluster-universal]="/opt/entrypoint.sh"
)

declare -A MODELS=(

  # =========================================================================
  # Qwen3 (standard transformer, NOT GDN — no Mamba quirks)
  # =========================================================================

  # Qwen3-VL-235B: Vision+Language, TP=2
  # NOTE: Qwen3 (not 3.5) so no GDN regression on v0.18.0.
  # CUBLAS_STATUS_NOT_INITIALIZED on custom image — use stock only.
  [qwen3-vl-235b]="
    DOCKER_IMAGE=vllm-official
    MODEL_DIR=/opt/ai-models/hf/qwen3/Qwen3-VL-235B-A22B-Thinking-AWQ
    SERVED_MODEL_NAME=qwen3-vl-235b-a22b
    TENSOR_PARALLEL_SIZE=2
    QUANTIZATION=awq_marlin
    MAX_MODEL_LEN=200000
    MAX_NUM_SEQS=2
    GPU_MEMORY_UTILIZATION=0.80
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
  # DeepSeek V4 Flash (CSA+HCA hybrid attention, 284B total / 13B active)
  # =========================================================================
  #
  # Tool calling: deepseek_v4 parser + tokenizer-mode required.
  # KNOWN ISSUES (vLLM 0.22.0):
  #   - #41122/#41240: boolean/typed args returned as quoted strings — breaks
  #     Cline subagent tool calls. Non-streaming + tool_choice=required is the
  #     workaround. Do NOT use for Cline until fixed upstream.
  #   - #40800: streaming + tool_choice=auto leaks DSML fragments intermittently.
  # STATUS: creative writing / Prosesmith primary. Cline: stay on GLM-4.7.
  #
  # KV cache: CSA+HCA extremely compact (~2% of GQA). At fp8 KV, 512k context
  # needs ~2.5GB/node — headroom is not a constraint at TP=2.
  # BLOCK_SIZE=256 required by V4 hybrid KV cache manager.
  # TOKENIZER_MODE=deepseek_v4 required (non-standard tokenizer arch).

  # DeepSeek V4 Flash — native FP4+FP8 mixed checkpoint, TP=2
  # ~158GB weights, ~79GB/node. Quality baseline — test first.
  # Deploy: ./vllm_cluster_orchestrator.sh --nodes 3,4 start-cluster deepseek-v4-flash
  #         ./vllm_cluster_orchestrator.sh --nodes 3,4 load-model deepseek-v4-flash
  [deepseek-v4-flash]="
    DOCKER_IMAGE=vllm-jasl-ds4
    MODEL_DIR=/mnt/network/data/models/huggingface/hf/deepseek-ai/DeepSeek-V4-Flash
    SERVED_MODEL_NAME=deepseek-v4-flash-284b-a13b
    TENSOR_PARALLEL_SIZE=4
    MAX_MODEL_LEN=655360
    MAX_NUM_SEQS=2
    GPU_MEMORY_UTILIZATION=0.50
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    BLOCK_SIZE=256
    TOKENIZER_MODE=deepseek_v4
    HF_HUB_OFFLINE=1
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=deepseek_v4
    REASONING_PARSER=deepseek_v4
    LOAD_FORMAT=instanttensor
    VLLM_API_PORT=8010
    VLLM_MASTER_PORT=29500
    RAY_MIN_WORKER_PORT=20000
    RAY_MAX_WORKER_PORT=29000
    RAY_OBJECT_STORE_GB=1
    ENFORCE_EAGER=0
    DTYPE=bfloat16
    VLLM_EXTRA_ARGS=--disable-custom-all-reduce
    NCCL_NVLS_ENABLE=0
    NCCL_SHM_DISABLE=1
  "

# DeepSeek V4 Flash — native FP4+FP8, TP=2 experiment
  # ~158GB weights, ~79GB/node at TP=2. Tests whether progressive cache flushes
  # give enough headroom to absorb the Marlin prep spike (~20GB transient).
  # If this boots: cables + TP=2 as daily driver. If OOM: stay on TP=4.
  # Deploy: ./vllm_cluster_orchestrator.sh --nodes 1,2 start-cluster deepseek-v4-flash-tp2
  #         ./vllm_cluster_orchestrator.sh --nodes 1,2 load-model deepseek-v4-flash-tp2
  [deepseek-v4-flash-tp2]="
    DOCKER_IMAGE=vllm-jasl-ds4
    MODEL_DIR=/mnt/network/data/models/huggingface/hf/deepseek-ai/DeepSeek-V4-Flash
    SERVED_MODEL_NAME=deepseek-v4-flash-284b-a13b
    TENSOR_PARALLEL_SIZE=2
    MAX_MODEL_LEN=819200
    MAX_NUM_SEQS=3
    GPU_MEMORY_UTILIZATION=0.70
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    BLOCK_SIZE=256
    TOKENIZER_MODE=deepseek_v4
    HF_HUB_OFFLINE=1
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=deepseek_v4
    REASONING_PARSER=deepseek_v4
    LOAD_FORMAT=instanttensor
    VLLM_API_PORT=8011
    VLLM_MASTER_PORT=29501
    RAY_MIN_WORKER_PORT=20000
    RAY_MAX_WORKER_PORT=29000
    RAY_OBJECT_STORE_GB=1
    ENFORCE_EAGER=0
    DTYPE=bfloat16
    VLLM_EXTRA_ARGS=--disable-custom-all-reduce
    NCCL_NVLS_ENABLE=0
    NCCL_SHM_DISABLE=1
  "

  # DeepSeek V4 Flash — local SSD, TP=2, mp executor (no Ray), silicon+phosphorus
  # Weights at /opt/ai-models/hf to eliminate NFS page cache pressure during Marlin prep.
  # DISTRIBUTED_EXECUTOR_BACKEND=mp bypasses Ray OOM monitor (the TP=2 boot killer).
  # Same context as TP=4 baseline to start; tune after boot confirmed.
  # MTP to be added once concurrency is validated.
  # Deploy: ./vllm_cluster_orchestrator.sh --nodes 3,4 start-cluster deepseek-v4-flash-tp2-local
  #         ./vllm_cluster_orchestrator.sh --nodes 3,4 load-model deepseek-v4-flash-tp2-local
  [deepseek-v4-flash-tp2-local]="
    DOCKER_IMAGE=vllm-jasl-ds4
    MODEL_DIR=/opt/ai-models/hf/deepseek-ai/DeepSeek-V4-Flash
    SERVED_MODEL_NAME=deepseek-v4-flash-284b-a13b
    TENSOR_PARALLEL_SIZE=2
    DISTRIBUTED_EXECUTOR_BACKEND=mp
    MAX_MODEL_LEN=655360
    MAX_NUM_SEQS=2
    GPU_MEMORY_UTILIZATION=0.70
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    BLOCK_SIZE=256
    TOKENIZER_MODE=deepseek_v4
    HF_HUB_OFFLINE=1
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=deepseek_v4
    REASONING_PARSER=deepseek_v4
    LOAD_FORMAT=instanttensor
    VLLM_API_PORT=8011
    VLLM_MASTER_PORT=29501
    ENFORCE_EAGER=0
    DTYPE=bfloat16
    VLLM_EXTRA_ARGS=--disable-custom-all-reduce
    NCCL_NVLS_ENABLE=0
    NCCL_SHM_DISABLE=1
  "

  # DeepSeek V4 Flash — native FP4+FP8 mixed checkpoint, TP=2
  # ~158GB weights, ~79GB/node. Quality baseline — test first.
  # Deploy: ./vllm_cluster_orchestrator.sh --nodes 3,4 start-cluster deepseek-v4-flash
  #         ./vllm_cluster_orchestrator.sh --nodes 3,4 load-model deepseek-v4-flash
  [deepseek-v4-flash-dev]="
    DOCKER_IMAGE=vllm-jasl-ds4
    MODEL_DIR=/mnt/network/data/models/huggingface/hf/deepseek-ai/DeepSeek-V4-Flash
    SERVED_MODEL_NAME=deepseek-v4-flash-284b-a13b
    TENSOR_PARALLEL_SIZE=4
    MAX_MODEL_LEN=655360
    MAX_NUM_SEQS=2
    GPU_MEMORY_UTILIZATION=0.50
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    BLOCK_SIZE=256
    TOKENIZER_MODE=deepseek_v4
    HF_HUB_OFFLINE=1
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=deepseek_v4
    REASONING_PARSER=deepseek_v4
    LOAD_FORMAT=instanttensor
    VLLM_API_PORT=8010
    VLLM_MASTER_PORT=29500
    RAY_MIN_WORKER_PORT=20000
    RAY_MAX_WORKER_PORT=29000
    RAY_OBJECT_STORE_GB=1
    ENFORCE_EAGER=0
    DTYPE=bfloat16
    VLLM_EXTRA_ARGS=--disable-custom-all-reduce
    NCCL_SHM_DISABLE=1
    SPECULATIVE_METHOD=mtp
    SPECULATIVE_NUM_TOKENS=1
  "

# DeepSeek V4 Flash — native FP8, TP=2, mp executor, vllm-pasta image
  # Uses eugr PR #219 image (vllm-node-dsv4/vllm-pasta) built from jasl/vllm
  # codex/ds4-sm120-min-enable branch. Native FP8 checkpoint (not Pasta/W4A16).
  # mp backend bypasses Ray OOM monitor. NFS weight path — no Marlin prep spike
  # with safetensors load format. Based on community-verified recipe.
  # Deploy: ./vllm_cluster_orchestrator.sh --nodes 3,4 start-cluster deepseek-v4-flash-w4a16
  #         ./vllm_cluster_orchestrator.sh --nodes 3,4 load-model deepseek-v4-flash-w4a16
  [deepseek-v4-flash-w4a16]="
    DOCKER_IMAGE=vllm-pasta
    MODEL_DIR=/mnt/network/data/models/huggingface/hf/deepseek-ai/DeepSeek-V4-Flash
    SERVED_MODEL_NAME=deepseek-v4-flash-284b-a13b
    TENSOR_PARALLEL_SIZE=2
    MAX_MODEL_LEN=200000
    MAX_NUM_SEQS=2
    MAX_NUM_BATCHED_TOKENS=4192
    GPU_MEMORY_UTILIZATION=0.85
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    BLOCK_SIZE=256
    TOKENIZER_MODE=deepseek_v4
    HF_HUB_OFFLINE=1
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=deepseek_v4
    REASONING_PARSER=deepseek_v4
    LOAD_FORMAT=safetensors
    VLLM_API_PORT=8011
    VLLM_MASTER_PORT=29501
    ENFORCE_EAGER=0
    DTYPE=bfloat16
    TORCH_CUDA_ARCH_LIST=12.1a
    VLLM_ALLOW_LONG_MAX_MODEL_LEN=1
    VLLM_TRITON_MLA_SPARSE=1
    FLASHINFER_DISABLE_VERSION_CHECK=1
    TILELANG_CLEANUP_TEMP_FILES=1
    DG_JIT_USE_NVRTC=0
    DG_JIT_NVCC_COMPILER=/usr/local/cuda/bin/nvcc
    NCCL_IB_DISABLE=0
    NCCL_DEBUG=WARN
    VLLM_EXTRA_ARGS=--disable-custom-all-reduce
    NCCL_NVLS_ENABLE=0
    NCCL_SHM_DISABLE=1
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

  # Qwen3.5-9B bf16: always-on fast-path, single node, cohabits with heavy model
  # Vision-capable (native Qwen3.5 VLM). Serves Hermes chat-quick tier.
  # ~18GB weights bf16 + KV. Deploy on any idle node alongside heavy model.
  # Port 8002 for cohabitation (heavy model on 8000).
  # MTP-1: native MTP head in weights (mtp_num_hidden_layers=1).
  # PREFIX_CACHING=0: DeltaNet hybrid attention crashes with prefix caching.
  # KV_CACHE_DTYPE=auto: fp8 KV may corrupt on hybrid linear+full attention.
  # ATTENTION_BACKEND=FLASHINFER: +16% over default on SM121.
	[qwen3.5-9b-bf16]="
		DOCKER_IMAGE=vllm-qwen35-v2
		MODEL_DIR=/mnt/network/data/models/huggingface/hf/Qwen/Qwen3.5-9B
		SERVED_MODEL_NAME=chat-quick,chat-quick-qwen,qwen35-9b
		TENSOR_PARALLEL_SIZE=1
		MAX_MODEL_LEN=150000
		MAX_NUM_SEQS=6
		MAX_NUM_BATCHED_TOKENS=8192
		GPU_MEMORY_UTILIZATION=0.30
		ENABLE_PREFIX_CACHING=0
		ENABLE_CHUNKED_PREFILL=1
		KV_CACHE_DTYPE=fp8
		TRUST_REMOTE_CODE=1
		ENABLE_AUTO_TOOL_CHOICE=1
		TOOL_CALL_PARSER=qwen3_coder
		REASONING_PARSER=qwen3
		ATTENTION_BACKEND=FLASHINFER
		SPECULATIVE_METHOD=mtp
		SPECULATIVE_NUM_TOKENS=2
		VLLM_PORT=8002
		RAY_OBJECT_STORE_GB=1
		ENFORCE_EAGER=1
	"

  # Qwen3.5-122B v2: PRODUCTION — Albond hybrid INT4+FP8 + MTP-2
  # TP=1 per node, HAProxy load-balances across independent nodes
  # Perf: 29-44 tok/s single-stream (MTP-2, 95-100% acceptance rate)
  # Deploy: ./vllm_cluster_orchestrator.sh --nodes 1 start-cluster 1 qwen3.5-122b-v2
  #         ./vllm_cluster_orchestrator.sh --nodes 2 start-cluster 1 qwen3.5-122b-v2
  [qwen3.5-122b-tp1-cust]="
    DOCKER_IMAGE=vllm-qwen35-v2
    MODEL_DIR=/opt/ai-models/local/qwen35-122b-hybrid-int4fp8
    SERVED_MODEL_NAME=qwen35-122b-a10b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=1
    MAX_MODEL_LEN=240000
    MAX_NUM_SEQS=6
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.80
    ENABLE_PREFIX_CACHING=0
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=qwen3_xml
    REASONING_PARSER=qwen3
    VLLM_PORT=8000
    ENFORCE_EAGER=0
    SPECULATIVE_METHOD=mtp
    SPECULATIVE_NUM_TOKENS=2
  "

  # Qwen3.5-122B: spark-vllm-docker 0.21.1 image test (no Albond patches)
  # Purpose: benchmark baseline — does 0.21.1 + tf5 close the 32→51 tok/s gap
  # without the hybrid INT4+FP8 + INT8 LM head patches?
  # Same model dir, same flags as tp1. Compare bench_sweep output directly.
  # entrypoint: spark-vllm-docker uses /bin/bash (no nvidia_entrypoint.sh)
  [qwen3.5-122b-tp1-univ]="
    DOCKER_IMAGE=vllm-cluster-universal
    MODEL_DIR=/opt/ai-models/local/qwen35-122b-hybrid-int4fp8
    SERVED_MODEL_NAME=qwen35-122b-a10b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=1
    MAX_MODEL_LEN=240000
    MAX_NUM_SEQS=6
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.80
    ENABLE_PREFIX_CACHING=0
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=qwen3_xml
    REASONING_PARSER=qwen3
    VLLM_PORT=8001
	ENFORCE_EAGER=0
    SPECULATIVE_METHOD=mtp
    SPECULATIVE_NUM_TOKENS=2
  "

  # Qwen3.5-122B: TP=2 fallback (eugr image, no MTP, cyankiwi model)
  # Use if hybrid model not yet distributed or for quick testing
  # Perf: 22 tok/s single-stream with IB + fp8 KV
  [qwen3.5-122b]="
    DOCKER_IMAGE=vllm-community-eugr
    MODEL_DIR=/opt/ai-models/hf/cyankiwi/Qwen3.5-122B-A10B-AWQ-4bit
    SERVED_MODEL_NAME=qwen35-122b-a10b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=2
    MAX_MODEL_LEN=250000
    MAX_NUM_SEQS=12
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.80
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    REASONING_PARSER=qwen3
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "

  # Qwen3.5-397B: Heavy mode, TP=4 (all nodes)
  # 64 MoE experts requires TP divisible by 64 — TP=3 fails, TP=4 or TP=2 only
  # ~200GB model, ~50GB/node at TP=4, ~59GB KV headroom/node at 0.80
  # eugr community benchmarks: ~37 tok/s single-stream, ~103 tok/s aggregate (4 users)
  # Requires vllm-sm121-397b (sm121 base + Marlin TP=4 fix + AutoRound ROPE fix)
  # TODO: build vllm-sm121-397b — see CLUSTER_README.md Step 2
  [qwen3.5-397b]="
    DOCKER_IMAGE=vllm-sm121
    MODEL_DIR=/mnt/network/data/models/huggingface/hf/cyankiwi/Qwen3.5-397B-A17B-AWQ-4bit
    SERVED_MODEL_NAME=qwen35-397b-a17b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=4
    MAX_MODEL_LEN=250000
    MAX_NUM_SEQS=2
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.80
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    LOAD_FORMAT=safetensors
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "

  # -------------------------------------------------------------------------
  # PATH A — Qwen3.5-397B Intel int4-AutoRound, TP=2, VISION ON
  #          Tuned for ONE full-context stream (chat-ultra-heavy single seat)
  # -------------------------------------------------------------------------
  # Goal: 1 stream at max context on 2 nodes (magnesium+aluminium), leaving
  # silicon+phosphorus free for Qwen3.5-122B / speech / ComfyUI / SGLang.
  # Beats GLM-4.7 (which eats all 4 nodes) on speed AND adds vision.
  #
  # The !!!! fix: the hand-run vllm-node-tf5 had --language-model-only, which
  # breaks weight-prefix mapping on the early-fusion VLM. This orchestrator
  # never adds that flag, so the full fused model (vision included) loads by
  # default — the fix is free here.
  #
  # IMAGE: vllm-sm121-397b carries the AutoRound ROPE fix (per CUSTOM_IMAGES
  # notes). NOT vllm-qwen35-v2 — that one has hybrid-INT4+FP8 patches, no
  # AutoRound layer (verified via docker history).
  #
  # MEMORY CLIFF: at TP=2, ~100GB weights/node leaves ~10-15GB/node for KV.
  # Single stream (MAX_NUM_SEQS=1) + fp8 KV. EMPIRICAL (2026-05-23): at
  # GPU_MEM_UTIL=0.85, vLLM reported max usable context = 221328 (262144
  # needs 2.06 GiB KV, only 1.79 GiB free). Set to 200000 for safe headroom
  # below that ceiling. To push higher: bump GPU_MEM_UTIL toward 0.88 (Ray
  # OOMs ~0.95 on unified memory — do not exceed). Weights on data/models
  # SSD share (NFS/100G); orchestrator binds it :ro.
  #
  # Deploy: ./vllm_cluster_orchestrator.sh --nodes 2 start-cluster 1 qwen3.5-397b-autoround
  [qwen3.5-397b-autoround]="
    DOCKER_IMAGE=vllm-sm121-397b
    MODEL_DIR=/mnt/network/data/models/huggingface/hf/Intel/Qwen3.5-397B-A17B-int4-AutoRound
    SERVED_MODEL_NAME=chat-ultra-heavy,chat-heavy-qwen,qwen35-397b-a17b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=2
    MAX_MODEL_LEN=200000
    MAX_NUM_SEQS=1
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.85
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=qwen3_coder
    REASONING_PARSER=qwen3
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=1
  "

  # NOTE: PATH B is the existing [qwen3.5-397b] profile above (AWQ, TP=4).
  # It still needs the vllm-sm121-397b image built (Marlin TP=4 + AutoRound
  # ROPE fix) per its TODO, OR a test run on base vllm-sm121. Path A (TP=2,
  # AutoRound) is the lower-effort first attempt; Path B (TP=4, AWQ) is the
  # fallback/scale path if AutoRound proves unworkable.

  # -------------------------------------------------------------------------
  # PATH A-tp4 — Qwen3.5-397B AutoRound, TP=4, CONCURRENCY + COHABITATION
  # -------------------------------------------------------------------------
  # Same model/image/quant as [qwen3.5-397b-autoround], but spread across ALL
  # FOUR nodes. Purpose: real multi-stream concurrency (OpenWebUI + Cline +
  # NovelCrafter at once) AND room on each node for a resting secondary tenant.
  #
  # WHY TP=4 over TP=2: (1) different collective topology — may sidestep the
  # TP=2 post-load KV-init hang (2026-05-23: TP=2 loaded 41/41 then froze at
  # the rank rendezvous, GPUs idle). (2) ~50GB weights/node (vs ~100 at TP=2)
  # → full 262144 context fits easily AND leaves headroom. (3) community
  # working-397B results are mostly TP=4.
  #
  # MEMORY @ GPU_MEM_UTIL=0.80: vLLM claims ~102GB/node, leaves ~26GB/node for
  # a resting tenant. RESTING TENANT MAP (bring up AFTER 397B is serving, so
  # vLLM claims its 0.80 first):
  #     magnesium  → Whisper (STT, ~3GB)
  #     aluminium  → Fish2 (TTS, ~2-4GB)
  #     silicon    → ComfyUI (image gen: SDXL / Flux-fp8 — LIGHT workflows only)
  #     phosphorus → Qwen3.5-9B (Hermes-agent fast path, ~10-18GB w/ its KV)
  # SPIKE ESCAPE VALVE: heavy ComfyUI (video gen, big Flux+LoRA stacks) needs
  # more than 26GB → that's a deliberate hands-on session: tear down 397B,
  # bring up 122B instead (lighter footprint), let freed nodes feed ComfyUI.
  # Not an ambient mode — a conscious tier swap.
  #
  # Deploy: ./vllm_cluster_orchestrator.sh --nodes 1,2,3,4 start-cluster 4 qwen3.5-397b-autoround-tp4
  [qwen3.5-397b-autoround-tp4]="
    DOCKER_IMAGE=vllm-sm121-397b
    MODEL_DIR=/mnt/network/data/models/huggingface/hf/Intel/Qwen3.5-397B-A17B-int4-AutoRound
    SERVED_MODEL_NAME=chat-ultra-heavy,chat-heavy-qwen,qwen35-397b-a17b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=4
    MAX_MODEL_LEN=262144
    MAX_NUM_SEQS=4
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.80
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=qwen3_coder
    REASONING_PARSER=qwen3
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=1
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

  # =========================================================================
  # GLM-4.7 (standard MoE — no GDN/Mamba, no MLA)
  # =========================================================================

  # GLM-4.7-355B: TP=4, compressed-tensors AWQ (same kernel path as 122B)
  # EQBench creative: 66.0 (vs 397B=68.3, 122B=54.3)
  # ~177GB model, ~44GB/node at TP=4, massive KV headroom at 0.80
  # Uses vllm-sm121 image (recent eugr build, already has GLM-4.7 support)
  # If arch error: rebuild with --pre-tf for transformers 5.x
  # Tool calling: --tool-call-parser glm47 --reasoning-parser glm45
  [glm-4.7]="
    DOCKER_IMAGE=vllm-sm121
    MODEL_DIR=/opt/ai-models/hf/cyankiwi/GLM-4.7-AWQ-4bit
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-glm,glm-4.7
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=4
    MAX_MODEL_LEN=200000
    MAX_NUM_SEQS=4
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.80
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=fp8
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=glm47
    REASONING_PARSER=glm45
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "
  # =========================================================================
  # MiniMax (standard MoE — compressed-tensors quant format)
  # =========================================================================

  # MiniMax-M2.7: 229B total / 10B active MoE, TP=4
  # compressed-tensors pack-quantized INT4 (group_size=32) — do NOT set QUANTIZATION flag
  # use_mtp=true, num_mtp_modules=3 — MTP available if image supports it
  # NAS-resident: LOAD_FORMAT=safetensors prevents lazy mmap over SMB
  # COMPILATION_CONFIG: fuse_minimax_qk_norm requires nightly build ~0.19.x+
  #   If launch fails with unknown compilation pass, remove COMPILATION_CONFIG and retry
  [minimax-m2.7]="
    DOCKER_IMAGE=vllm-sm121
    MODEL_DIR=/mnt/network/data/models/huggingface/hf/cyankiwi/MiniMax-M2.7-AWQ-4bit
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-minimax,minimax-m2.7-229b-a10b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=4
    MAX_MODEL_LEN=131072
    MAX_NUM_SEQS=4
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.80
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    LOAD_FORMAT=safetensors
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=minimax_m2
    REASONING_PARSER=minimax_m2
    COMPILATION_CONFIG={"mode":3,"pass_config":{"fuse_minimax_qk_norm":true}}
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "

  # MiniMax-M2.7: TP=2 variant for 2-node deployment
  # ~57GB weights/node at INT4, ~45GB KV headroom at 0.80
  # Phase 1 PASSED: eager mode, 131k, 32-35 tok/s generation (2026-05-24)
  # Phase 2: CUDA graphs enabled, 131k (bump to 200k/seqs=1 after graphs confirmed)
  # MTP disabled in model config.json (use_mtp: false) — re-enable on vLLM v0.21+
  # Deploy: ./vllm_cluster_orchestrator.sh --nodes X,Y start-cluster 2 minimax-m2.7-tp2
  [minimax-m2.7-tp2]="
    DOCKER_IMAGE=vllm-sm121
    MODEL_DIR=/mnt/network/data/models/huggingface/hf/cyankiwi/MiniMax-M2.7-AWQ-4bit
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-minimax,minimax-m2.7-229b-a10b
    AUTO_AWQ_MARLIN=0
    TENSOR_PARALLEL_SIZE=2
    MAX_MODEL_LEN=131072
    MAX_NUM_SEQS=4
    MAX_NUM_BATCHED_TOKENS=8192
    GPU_MEMORY_UTILIZATION=0.80
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    LOAD_FORMAT=safetensors
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=minimax_m2
    REASONING_PARSER=minimax_m2
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "

)

# Default image if model profile doesn't specify DOCKER_IMAGE
DEFAULT_VLLM_IMAGE="vllm-official"

SSH_USER="admin"
SSH_KEY=""
LOG_DIR="/opt/ai-tools/logs/vllm-cluster"