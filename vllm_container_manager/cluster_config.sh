#!/usr/bin/env bash
# cluster_config.sh

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
)

declare -gA MODELS=(
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
    KV_CACHE_DTYPE=auto
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
    ENFORCE_EAGER=0
  "
  
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
  
  [qwen3.5-122b]="
    DOCKER_IMAGE=vllm-official
    MODEL_DIR=/opt/ai-models/hf/cyankiwi/Qwen3.5-122B-A10B-AWQ-4bit
    SERVED_MODEL_NAME=chat-heavy,chat-heavy-qwen,qwen35-122b-a10b
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

  [qwen3.5-9b]="
    DOCKER_IMAGE=vllm-official
    MODEL_DIR=/opt/ai-models/hf/cyankiwi/Qwen3.5-9B-AWQ-4bit
    SERVED_MODEL_NAME=chat-peeks,chat-peeks-qwen,qwen35-9b
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
