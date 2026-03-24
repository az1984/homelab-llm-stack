#!/usr/bin/env bash
# cluster_config.sh
# Shared configuration for DGX Spark cluster inference tools (vLLM, llama.cpp RPC)

# ============================================================================
# Cluster Topology
# ============================================================================

declare -gA NODES=(
  [1]="192.168.2.42:magnesium:10.10.10.1"
  [2]="192.168.2.43:aluminium:10.10.10.2"
  [3]="192.168.2.44:silicon:10.10.10.3"
  [4]="192.168.2.45:phosphorus:10.10.10.4"
)

# Node roles (for non-vLLM tools like llama.cpp RPC)
MASTER_NODE="magnesium"
MASTER_IP="192.168.2.42"
WORKER_NODES=("aluminium" "silicon" "phosphorus")
WORKER_IPS=("192.168.2.43" "192.168.2.44" "192.168.2.45")

# ============================================================================
# Shared Paths
# ============================================================================

MODEL_BASE="/opt/ai-models"
AI_TOOLS_BASE="/opt/ai-tools"

# Model formats
GGUF_BASE="${MODEL_BASE}/gguf"
HF_BASE="${MODEL_BASE}/hf"
SAFETENSORS_BASE="${MODEL_BASE}/safetensors"

# Tool installations
LLAMA_CPP_RPC_BIN="${AI_TOOLS_BASE}/llama.cpp-rpc/bin"
VLLM_BASE="${AI_TOOLS_BASE}/vllm"

# Logs
LOG_BASE="${AI_TOOLS_BASE}/logs"

# ============================================================================
# SSH Configuration
# ============================================================================

SSH_USER="admin"
SSH_KEY=""
SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=5"

# ============================================================================
# vLLM Configuration
# ============================================================================

LOG_DIR="${LOG_BASE}/vllm-cluster"

# Custom Docker images - map name to full image path
# Add new images here, then reference them in model profiles via DOCKER_IMAGE=name
declare -gA CUSTOM_IMAGES=(
  [vllm-official]="vllm/vllm-openai:v0.17.1"
  [vllm-gb10-community]="scitrera/dgx-spark-vllm:0.14.0rc2-t5"
  [vllm-gb10-old]="hellohal2064/vllm-dgx-spark-gb10:latest"
  [vllm-nvidia-official]="nvcr.io/nvidia/vllm:25.09-py3"
)
  [vllm-official]="vllm/vllm-openai:v0.17.1"
  [vllm-gb10-community]="scitrera/dgx-spark-vllm:0.14.0rc2-t5"
  [vllm-gb10-old]="hellohal2064/vllm-dgx-spark-gb10:latest"
  [vllm-nvidia-official]="nvcr.io/nvidia/vllm:25.09-py3"
)

declare -gA MODELS=(
  [qwen3-vl-235b]="
    DOCKER_IMAGE=vllm-official
    MODEL_DIR=/opt/ai-models/hf/qwen3/Qwen3-VL-235B-A22B-Thinking-AWQ
    SERVED_MODEL_NAME=chat-heavy
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
    DOCKER_IMAGE=vllm-gb10-community
    MODEL_DIR=/opt/ai-models/hf/cognitivecomputations/DeepSeek-V3-AWQ
    SERVED_MODEL_NAME=chat-heavy
    TENSOR_PARALLEL_SIZE=4
    QUANTIZATION=awq
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
    DOCKER_IMAGE=vllm-gb10-community
    MODEL_DIR=/opt/ai-models/hf/QuantTrio/DeepSeek-V3.2-AWQ
    SERVED_MODEL_NAME=chat-heavy
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
  
  [deepseek-v3-future]="
    DOCKER_IMAGE=vllm-gb10-community
    MODEL_DIR=/opt/ai-models/hf/QuantTrio/DeepSeek-V3.2-AWQ
    SERVED_MODEL_NAME=chat-heavy
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

  [deepseek-r1]="
    DOCKER_IMAGE=vllm-gb10-community
    MODEL_DIR=/opt/ai-models/hf/DeepSeek-R1-AWQ
    SERVED_MODEL_NAME=chat-heavy
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
    DOCKER_IMAGE=vllm-gb10-community
    MODEL_DIR=/opt/ai-models/hf/Qwen3.5-122B-AWQ
    SERVED_MODEL_NAME=chat-heavy
    TENSOR_PARALLEL_SIZE=2
    QUANTIZATION=awq
    MAX_MODEL_LEN=131072
    MAX_NUM_SEQS=2
    GPU_MEMORY_UTILIZATION=0.90
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    TRUST_REMOTE_CODE=1
    ENABLE_AUTO_TOOL_CHOICE=1
    TOOL_CALL_PARSER=hermes
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=4
  "
)

# Default image if model profile doesn't specify DOCKER_IMAGE
DEFAULT_VLLM_IMAGE="vllm-official"

# ============================================================================
# llama.cpp RPC Configuration
# ============================================================================

LLAMA_RPC_LOG_DIR="${LOG_BASE}/llama-rpc"
LLAMA_RPC_PORT="50052"

# Per-node memory allocation (leave ~8GB for system)
NODE_TOTAL_MEMORY_GB=128
WORKER_MEMORY_GB=120
WORKER_MEMORY_MB=$((WORKER_MEMORY_GB * 1024))

# llama.cpp RPC model profiles
# Models are split into multiple files - llama.cpp auto-loads all parts from first file
declare -gA LLAMA_MODELS=(
  [deepseek-v3-q4]="${GGUF_BASE}/DeepSeek-V3-Q4_K_M/DeepSeek-V3-Q4_K_M-00001-of-00009.gguf"
  [deepseek-v3-q5]="${GGUF_BASE}/DeepSeek-V3-Q5_K_M/DeepSeek-V3-Q5_K_M-00001-of-00010.gguf"
)

SSH_USER="admin"
SSH_KEY=""
LOG_DIR="/opt/ai-tools/logs/vllm-cluster"
