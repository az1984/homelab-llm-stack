#!/usr/bin/env bash
# vllm_cluster_mgr.sh
#
# Universal vLLM cluster manager for N-node Ray clusters.
# Designed to run inside Docker containers or bare metal.
#
# Commands:
#   start-ray    - Start Ray (head or worker based on THIS_NODE)
#   load-model   - Load model on head node (requires Ray already running)
#   stop-model   - Stop model (keep Ray running)
#   stop-ray     - Stop Ray cluster
#   stop-all     - Stop model and Ray
#   status       - Show cluster status
#
# Usage:
#   Node 1 (head):  THIS_NODE=1 RAY_HEAD_IP=10.10.10.1 RAY_NODE_IP=10.10.10.1 ./vllm_cluster_mgr.sh start-ray
#   Node 2 (worker): THIS_NODE=2 RAY_HEAD_IP=10.10.10.1 RAY_NODE_IP=10.10.10.2 ./vllm_cluster_mgr.sh start-ray
#   Node 1 (load):  MODEL_DIR=... TENSOR_PARALLEL_SIZE=2 ./vllm_cluster_mgr.sh load-model

set -euo pipefail

# ==============================================================================
# Binary Paths
# ==============================================================================
VLLM_PYTHON_BIN="${VLLM_PYTHON_BIN:-python3}"  # In Docker: system python3 with vLLM
RAY_BIN="${RAY_BIN:-ray}"                       # In Docker: system ray
CUDA_BIN_DIR="${CUDA_BIN_DIR:-/usr/local/cuda/bin}"
CUDA_LIB_DIR="${CUDA_LIB_DIR:-/usr/local/cuda/lib64}"
PTXAS_BIN="${PTXAS_BIN:-${CUDA_BIN_DIR}/ptxas}"
RAY_TEMP_DIR="${RAY_TEMP_DIR:-/tmp/ray}"

# ==============================================================================
# Cluster Configuration
# ==============================================================================
THIS_NODE="${THIS_NODE:-1}"
RAY_HEAD_IP="${RAY_HEAD_IP:-}"
RAY_NODE_IP="${RAY_NODE_IP:-}"
RAY_PORT="${RAY_PORT:-6379}"            # Ray GCS port (head node)
RAY_DASHBOARD_PORT="${RAY_DASHBOARD_PORT:-8265}"  # Ray dashboard port (head node)

# Ray worker/internal port ranges — keep well away from VLLM_PORT and VLLM_MASTER_PORT.
# Ray will pick ports in [RAY_MIN_WORKER_PORT, RAY_MAX_WORKER_PORT] for worker processes.
# Defaults: 20000-29000 (avoids clash with vLLM's 29500 range).
RAY_MIN_WORKER_PORT="${RAY_MIN_WORKER_PORT:-20000}"
RAY_MAX_WORKER_PORT="${RAY_MAX_WORKER_PORT:-29000}"

# Ray node manager / object manager ports (one per node, must be unique across nodes)
RAY_NODE_MANAGER_PORT="${RAY_NODE_MANAGER_PORT:-}"   # Empty = Ray auto-assigns
RAY_OBJECT_MANAGER_PORT="${RAY_OBJECT_MANAGER_PORT:-}"  # Empty = Ray auto-assigns

# ==============================================================================
# State and Logging
# ==============================================================================
STATE_DIR="${STATE_DIR:-/opt/ai-tools/run/vllm-cluster}"
LOG_DIR="${LOG_DIR:-/opt/ai-tools/logs/vllm-cluster}"
RAY_PIDFILE="${RAY_PIDFILE:-${STATE_DIR}/ray_node${THIS_NODE}.pid}"
VLLM_PIDFILE="${VLLM_PIDFILE:-${STATE_DIR}/vllm_api.pid}"
RUN_USER="${RUN_USER:-}"  # Empty = run as current user

# ==============================================================================
# Model and Runtime Configuration
# ==============================================================================
MODEL_DIR="${MODEL_DIR:-/opt/ai-models/hf/CHANGE_ME}"
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-model}"
VLLM_HOST="${VLLM_HOST:-0.0.0.0}"
# NOTE: We use VLLM_API_PORT (not VLLM_PORT) to avoid collision with vLLM's
# internal env var. VLLM_PORT is reserved by vLLM for ZMQ IPC between the
# APIServer and EngineCore processes. Setting it externally causes a port
# conflict — both the HTTP server and the ZMQ socket try to bind the same port.
VLLM_API_PORT="${VLLM_API_PORT:-${VLLM_PORT:-8000}}"  # fallback to VLLM_PORT for backwards compat
QUANTIZATION="${QUANTIZATION:-}"
DTYPE="${DTYPE:-float16}"
AUTO_AWQ_MARLIN="${AUTO_AWQ_MARLIN:-1}"
MAX_MODEL_LEN="${MAX_MODEL_LEN:-32768}"
GPU_MEMORY_UTILIZATION="${GPU_MEMORY_UTILIZATION:-0.92}"
TENSOR_PARALLEL_SIZE="${TENSOR_PARALLEL_SIZE:-2}"
PIPELINE_PARALLEL_SIZE="${PIPELINE_PARALLEL_SIZE:-1}"
MAX_NUM_SEQS="${MAX_NUM_SEQS:-}"
MAX_NUM_BATCHED_TOKENS="${MAX_NUM_BATCHED_TOKENS:-}"
ENFORCE_EAGER="${ENFORCE_EAGER:-1}"
TRUST_REMOTE_CODE="${TRUST_REMOTE_CODE:-1}"

# ==============================================================================
# Tool Calling
# ==============================================================================
ENABLE_AUTO_TOOL_CHOICE="${ENABLE_AUTO_TOOL_CHOICE:-0}"
TOOL_CALL_PARSER="${TOOL_CALL_PARSER:-}"
REASONING_PARSER="${REASONING_PARSER:-}"

# ==============================================================================
# Performance Optimizations
# ==============================================================================
ENABLE_PREFIX_CACHING="${ENABLE_PREFIX_CACHING:-1}"
ENABLE_CHUNKED_PREFILL="${ENABLE_CHUNKED_PREFILL:-1}"
KV_CACHE_DTYPE="${KV_CACHE_DTYPE:-auto}"

# ==============================================================================
# Network Configuration (InfiniBand/RoCE)
# ==============================================================================
NCCL_SOCKET_IFNAME="${NCCL_SOCKET_IFNAME:-enp1s0f0np0}"
NCCL_IB_HCA="${NCCL_IB_HCA:-rocep1s0f0}"
NCCL_DEBUG="${NCCL_DEBUG:-WARN}"
GLOO_SOCKET_IFNAME="${GLOO_SOCKET_IFNAME:-enp1s0f0np0}"
UCX_NET_DEVICES="${UCX_NET_DEVICES:-enp1s0f0np0}"

# ==============================================================================
# Ray Resource Configuration
# ==============================================================================
RAY_OBJECT_STORE_BYTES="${RAY_OBJECT_STORE_BYTES:-}"

if [[ -z "${RAY_OBJECT_STORE_BYTES}" ]]; then
  # Use RAY_OBJECT_STORE_GB if provided, otherwise default to 2GB
  RAY_OBJECT_STORE_BYTES=$(( ${RAY_OBJECT_STORE_GB:-2} * 1024 * 1024 * 1024 ))
fi

# ==============================================================================
# Miscellaneous
# ==============================================================================
VLLM_EXTRA_ARGS="${VLLM_EXTRA_ARGS:-}"
TOKENIZER_MODE="${TOKENIZER_MODE:-}"
BLOCK_SIZE="${BLOCK_SIZE:-}"
HF_HUB_OFFLINE="${HF_HUB_OFFLINE:-0}"

# vLLM distributed rendezvous port — used by PyTorch/NCCL for inter-node coordination.
# MUST be different from VLLM_PORT and must not collide with Ray ports.
# eugr uses 29501; we default to 29500 (leaves 29501+ free for multiple concurrent instances).
# If running two TP=2 instances simultaneously, set each to a different VLLM_MASTER_PORT.
VLLM_MASTER_PORT="${VLLM_MASTER_PORT:-29500}"

# Base port for vLLM worker subprocess communication (Ray actor RPC).
# Empty = vLLM auto-assigns. Set explicitly if you need deterministic port assignment.
VLLM_WORKER_PORT_BASE="${VLLM_WORKER_PORT_BASE:-}"
SPECULATIVE_METHOD="${SPECULATIVE_METHOD:-}"
SPECULATIVE_NUM_TOKENS="${SPECULATIVE_NUM_TOKENS:-}"
NUM_SPECULATIVE_TOKENS="${NUM_SPECULATIVE_TOKENS:-}"
CLUSTER_EXECUTOR_BACKEND="${CLUSTER_EXECUTOR_BACKEND:-}"  # Orchestrator/mgr only — never passed to vLLM. Use "ray" or "mp".
LOAD_FORMAT="${LOAD_FORMAT:-}"
COMPILATION_CONFIG="${COMPILATION_CONFIG:-}"
VLLM_LOGFILE="${VLLM_LOGFILE:-${LOG_DIR}/vllm_${SERVED_MODEL_NAME}_node${THIS_NODE}.log}"
RAY_LOGFILE="${RAY_LOGFILE:-${LOG_DIR}/ray_node${THIS_NODE}.log}"

# ==============================================================================
# Helpers
# ==============================================================================
Log() { echo "[vllm-mgr] $*"; }
Die() { echo "[vllm-mgr] ERROR: $*" >&2; exit 1; }

IsHeadNode() {
  [[ "${RAY_NODE_IP}" == "${RAY_HEAD_IP}" ]]
}

EnsureDirs() {
  mkdir -p "${STATE_DIR}" "${LOG_DIR}" 2>/dev/null || true
}

IsPIDRunning() {
  local pid="$1"
  [[ -n "${pid}" ]] && kill -0 "${pid}" >/dev/null 2>&1
}

ReadPIDFile() {
  local pidfile="$1"
  [[ -f "${pidfile}" ]] && cat "${pidfile}" 2>/dev/null || true
}

WritePIDFile() {
  local pidfile="$1"
  local pid="$2"
  printf "%s\n" "${pid}" > "${pidfile}"
}

RemovePIDFile() {
  local pidfile="$1"
  rm -f "${pidfile}"
}

RunCMD() {
  if [[ -n "${RUN_USER}" ]] && [[ "$(id -un)" != "${RUN_USER}" ]]; then
    sudo -u "${RUN_USER}" -H --preserve-env=RAY_ADDRESS,RAY_NODE_IP,VLLM_HOST_IP,NCCL_SOCKET_IFNAME,NCCL_IB_HCA,NCCL_DEBUG,GLOO_SOCKET_IFNAME,UCX_NET_DEVICES,CUDA_HOME,PATH,LD_LIBRARY_PATH,QUANTIZATION,DTYPE,ENABLE_PREFIX_CACHING,ENABLE_CHUNKED_PREFILL,KV_CACHE_DTYPE,AUTO_AWQ_MARLIN,LOAD_FORMAT,COMPILATION_CONFIG,TOKENIZER_MODE,BLOCK_SIZE,HF_HUB_OFFLINE,VLLM_MASTER_PORT,VLLM_WORKER_PORT_BASE,VLLM_API_PORT -- "$@"
  else
    "$@"
  fi
}

# ==============================================================================
# Environment Setup
# ==============================================================================
ExportToolchainEnv() {
  export CUDA_HOME="${CUDA_BIN_DIR%/bin}"
  export PTXAS_BIN
  export TRITON_PTXAS_PATH="${PTXAS_BIN}"
  export PATH="${CUDA_BIN_DIR}:${PATH}"
  export LD_LIBRARY_PATH="${CUDA_LIB_DIR}:${LD_LIBRARY_PATH:-}"
}

ExportRuntimeEnv() {
  # Detect node IP if not set
  if [[ -z "${RAY_NODE_IP}" ]]; then
    RAY_NODE_IP="$(ip -br a | awk '{print $3}' | sed 's#/.*##' | grep -E '^10\.10\.10\.' | head -1)"
    [[ -n "${RAY_NODE_IP}" ]] || Die "Could not auto-detect RAY_NODE_IP (set it manually)"
  fi
  
  # Head IP defaults to this node's IP if not set (meaning we ARE the head)
  if [[ -z "${RAY_HEAD_IP}" ]]; then
    RAY_HEAD_IP="${RAY_NODE_IP}"
  fi
  
  [[ -n "${RAY_HEAD_IP}" ]] || Die "RAY_HEAD_IP not set"
  
  export RAY_ADDRESS="${RAY_HEAD_IP}:${RAY_PORT}"
  export RAY_NODE_IP
  export VLLM_HOST_IP="${RAY_NODE_IP}"
  
  # NCCL/network settings
  export NCCL_SOCKET_IFNAME
  export NCCL_IB_HCA
  export NCCL_IB_DISABLE=0
  export NCCL_DEBUG
  export GLOO_SOCKET_IFNAME
  export UCX_NET_DEVICES
}

PrintEnvSummary() {
  Log "=== Configuration ==="
  Log "Cluster: ${TENSOR_PARALLEL_SIZE}-way tensor parallel"
  Log "This node: ${THIS_NODE} (${RAY_NODE_IP})"
  Log "Head node: ${RAY_HEAD_IP}"
  Log "Model: ${MODEL_DIR}"
  Log "Network: ${NCCL_SOCKET_IFNAME} (IB: ${NCCL_IB_HCA})"
}

# ==============================================================================
# Ray Management
# ==============================================================================
StopRayHard() {
  Log "Stopping Ray (hard) on this node"
  timeout 5 ${RAY_BIN} stop >/dev/null 2>&1 || true
  sleep 1
  
  pkill -9 -f "ray::" >/dev/null 2>&1 || true
  pkill -9 -f "raylet" >/dev/null 2>&1 || true
  pkill -9 -f "gcs_server" >/dev/null 2>&1 || true
  pkill -9 -f "dashboard" >/dev/null 2>&1 || true
  
  # Clean up temp dirs (with timeout to avoid hanging)
  timeout 5 rm -rf /tmp/ray 2>/dev/null || true
  
  Log "Ray cleanup complete"
}

StartRayHead() {
  Log "Starting Ray head on ${RAY_NODE_IP}:${RAY_PORT}"
  
  StopRayHard
  
  local ray_args=(
    "${RAY_BIN}" start --head
    --node-ip-address="${RAY_NODE_IP}"
    --port="${RAY_PORT}"
    --dashboard-host=0.0.0.0
    --dashboard-port="${RAY_DASHBOARD_PORT}"
    --min-worker-port="${RAY_MIN_WORKER_PORT}"
    --max-worker-port="${RAY_MAX_WORKER_PORT}"
    --object-store-memory="${RAY_OBJECT_STORE_BYTES}"
    --temp-dir="${RAY_TEMP_DIR}"
    --num-cpus=0
  )
  [[ -n "${RAY_NODE_MANAGER_PORT}" ]] && ray_args+=(--node-manager-port="${RAY_NODE_MANAGER_PORT}")
  [[ -n "${RAY_OBJECT_MANAGER_PORT}" ]] && ray_args+=(--object-manager-port="${RAY_OBJECT_MANAGER_PORT}")

  RunCMD "${ray_args[@]}" >>"${RAY_LOGFILE}" 2>&1
  
  Log "Ray head started (dashboard: http://${RAY_NODE_IP}:${RAY_DASHBOARD_PORT})"
}

StartRayWorker() {
  Log "Starting Ray worker (joining ${RAY_ADDRESS})"
  
  StopRayHard
  
  RunCMD "${RAY_BIN}" start \
    --address="${RAY_ADDRESS}" \
    --node-ip-address="${RAY_NODE_IP}" \
    --object-store-memory="${RAY_OBJECT_STORE_BYTES}" \
    --temp-dir="${RAY_TEMP_DIR}" \
    --num-cpus=0 \
    >>"${RAY_LOGFILE}" 2>&1
  
  Log "Ray worker started"
}

# ==============================================================================
# vLLM Model Loading
# ==============================================================================
BuildVLLMArgs() {
  local args=(
    "${VLLM_PYTHON_BIN}" -m vllm.entrypoints.openai.api_server
    --model "${MODEL_DIR}"
    --host "${VLLM_HOST}"
    --port "${VLLM_API_PORT}"
    --dtype "${DTYPE}"
    --max-model-len "${MAX_MODEL_LEN}"
    --gpu-memory-utilization "${GPU_MEMORY_UTILIZATION}"
    --tensor-parallel-size "${TENSOR_PARALLEL_SIZE}"
    --pipeline-parallel-size "${PIPELINE_PARALLEL_SIZE}"
  )
  # CLUSTER_EXECUTOR_BACKEND is an orchestrator/mgr-only variable — never passed to vLLM.
  # vLLM infers the executor from --nnodes (mp) or Ray being present (ray).
  # No --distributed-executor-backend is injected here.

  # Explicit rendezvous port — decouples NCCL/PyTorch distributed init from VLLM_PORT.
  # Without this, vLLM defaults to VLLM_PORT+1 which collides with other services.
  [[ -n "${VLLM_MASTER_PORT}" ]] && args+=(--master-port "${VLLM_MASTER_PORT}")

  # mp multi-node flags — only relevant when CLUSTER_EXECUTOR_BACKEND=mp and nnodes>1.
  # VLLM_NNODES, VLLM_NODE_RANK, VLLM_MASTER_ADDR, and VLLM_HEADLESS are injected
  # per-node by the orchestrator during mp (CLUSTER_EXECUTOR_BACKEND=mp) load-model launches.
  [[ -n "${VLLM_NNODES:-}" ]] && args+=(--nnodes "${VLLM_NNODES}")
  [[ -n "${VLLM_NODE_RANK:-}" ]] && args+=(--node-rank "${VLLM_NODE_RANK}")
  [[ -n "${VLLM_MASTER_ADDR:-}" ]] && args+=(--master-addr "${VLLM_MASTER_ADDR}")
  [[ "${VLLM_HEADLESS:-0}" == "1" ]] && args+=(--headless)

  # Worker port base — set for deterministic Ray actor RPC port assignment.
  [[ -n "${VLLM_WORKER_PORT_BASE}" ]] && args+=(--worker-port-base "${VLLM_WORKER_PORT_BASE}")
  
  # Split comma-separated model names into separate flags
  IFS=',' read -ra model_names <<< "${SERVED_MODEL_NAME}"
  for name in "${model_names[@]}"; do
    args+=(--served-model-name "${name}")
  done
  
  [[ -n "${MAX_NUM_SEQS}" ]] && args+=(--max-num-seqs "${MAX_NUM_SEQS}")
  [[ -n "${MAX_NUM_BATCHED_TOKENS}" ]] && args+=(--max-num-batched-tokens "${MAX_NUM_BATCHED_TOKENS}")
  [[ "${ENFORCE_EAGER}" == "1" ]] && args+=(--enforce-eager)
  [[ "${TRUST_REMOTE_CODE}" == "1" ]] && args+=(--trust-remote-code)
  [[ "${ENABLE_PREFIX_CACHING}" == "1" ]] && args+=(--enable-prefix-caching)
  [[ "${ENABLE_CHUNKED_PREFILL}" == "1" ]] && args+=(--enable-chunked-prefill)
  [[ "${KV_CACHE_DTYPE}" != "auto" ]] && args+=(--kv-cache-dtype "${KV_CACHE_DTYPE}")
  [[ "${ENABLE_AUTO_TOOL_CHOICE}" == "1" ]] && args+=(--enable-auto-tool-choice)
  [[ -n "${TOOL_CALL_PARSER}" ]] && args+=(--tool-call-parser "${TOOL_CALL_PARSER}")
  [[ -n "${REASONING_PARSER}" ]] && args+=(--reasoning-parser "${REASONING_PARSER}")
  [[ -n "${TOKENIZER_MODE}" ]] && args+=(--tokenizer-mode "${TOKENIZER_MODE}")
  [[ -n "${BLOCK_SIZE}" ]] && args+=(--block-size "${BLOCK_SIZE}")
  
  # Auto AWQ detection
  if [[ -z "${QUANTIZATION}" ]] && [[ "${AUTO_AWQ_MARLIN}" == "1" ]]; then
    if [[ "${MODEL_DIR}" == *AWQ* ]]; then
      QUANTIZATION="awq"
    fi
  fi
  [[ -n "${QUANTIZATION}" ]] && args+=(--quantization "${QUANTIZATION}")
  
  # Speculative decoding (MTP)
  if [[ -n "${SPECULATIVE_METHOD}" ]]; then
    local spec_json="{\"method\":\"${SPECULATIVE_METHOD}\",\"num_speculative_tokens\":${SPECULATIVE_NUM_TOKENS:-1}}"
    args+=(--speculative-config "${spec_json}")
  fi

  # Standalone speculative token override (e.g. NUM_SPECULATIVE_TOKENS=0 to disable MTP auto-detection)
  # Uses --speculative-config JSON — --num-speculative-tokens does not exist in 0.19.x
  if [[ -n "${NUM_SPECULATIVE_TOKENS}" ]] && [[ -z "${SPECULATIVE_METHOD}" ]]; then
    args+=(--speculative-config "{\"num_speculative_tokens\":${NUM_SPECULATIVE_TOKENS}}")
  fi

  if [[ -n "${VLLM_EXTRA_ARGS}" ]]; then
    # shellcheck disable=SC2206
    args+=(${VLLM_EXTRA_ARGS})
  fi

  [[ -n "${LOAD_FORMAT}" ]] && args+=(--load-format "${LOAD_FORMAT}")
  [[ -n "${COMPILATION_CONFIG}" ]] && args+=(--compilation-config "${COMPILATION_CONFIG}")
  
  printf "%q " "${args[@]}"
}

LoadModel() {
  # mp headless workers (rank > 0) are not head nodes but still run load-model
  [[ "${VLLM_HEADLESS:-0}" != "1" ]] && { IsHeadNode || Die "load-model must run on head node (this=${RAY_NODE_IP}, head=${RAY_HEAD_IP})"; }
  
  local old_pid
  old_pid="$(ReadPIDFile "${VLLM_PIDFILE}" || true)"
  if [[ -n "${old_pid}" ]] && IsPIDRunning "${old_pid}"; then
    Die "vLLM already running (pid=${old_pid}). Stop it first with: stop-model"
  fi
  
  # Ensure target port is free — kill any stale process holding it
  local port_pid
  port_pid="$(ss -tlnp 2>/dev/null | grep ":${VLLM_API_PORT} " | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1 || true)"
  if [[ -n "${port_pid}" ]]; then
    Log "WARNING: Port ${VLLM_API_PORT} held by pid ${port_pid} — killing stale process"
    kill "${port_pid}" 2>/dev/null || true
    sleep 2
    if ss -tlnp 2>/dev/null | grep -q ":${VLLM_API_PORT} "; then
      kill -9 "${port_pid}" 2>/dev/null || true
      sleep 1
    fi
    if ss -tlnp 2>/dev/null | grep -q ":${VLLM_API_PORT} "; then
      Die "Cannot free port ${VLLM_API_PORT} — something is still holding it"
    fi
    Log "  Port ${VLLM_API_PORT} freed"
  fi
  
  # Rotate log: timestamped file + _latest symlink
  local timestamp
  timestamp="$(date +%Y%m%d_%H%M%S)"
  local log_base="${LOG_DIR}/vllm_${SERVED_MODEL_NAME}_node${THIS_NODE}"
  local timestamped_log="${log_base}_${timestamp}.log"
  local latest_link="${log_base}_latest.log"
  VLLM_LOGFILE="${timestamped_log}"
  ln -sfn "${timestamped_log}" "${latest_link}"
  Log "Log file: ${timestamped_log}"
  Log "  Symlink: ${latest_link}"
  
  Log "Loading model: ${MODEL_DIR}"
  Log "  Served as: ${SERVED_MODEL_NAME}"
  Log "  Tensor parallel: ${TENSOR_PARALLEL_SIZE}"

  # TP=1 or mp backend: unset RAY_ADDRESS so vLLM doesn't auto-detect Ray
  # and fall back to the Ray executor instead of multiproc.
  if [[ "${TENSOR_PARALLEL_SIZE}" -le 1 || "${CLUSTER_EXECUTOR_BACKEND}" == "mp" ]]; then
    Log "  Executor: multiproc (Ray disabled)"
    unset RAY_ADDRESS
  fi

  local cmd
  cmd="$(BuildVLLMArgs)"
  
  RunCMD nohup bash -c "${cmd}" >>"${VLLM_LOGFILE}" 2>&1 &
  local pid=$!
  WritePIDFile "${VLLM_PIDFILE}" "${pid}"
  
  Log "vLLM started (pid=${pid})"
  Log "API endpoint: http://${RAY_NODE_IP}:${VLLM_API_PORT}/v1"
}

StopModel() {
  local vpid
  vpid="$(ReadPIDFile "${VLLM_PIDFILE}" || true)"
  
  if [[ -n "${vpid}" ]] && IsPIDRunning "${vpid}"; then
    Log "Stopping vLLM (pid=${vpid})"
    kill "${vpid}" || true
    sleep 2
    IsPIDRunning "${vpid}" && kill -9 "${vpid}" || true
  else
    Log "No running vLLM process found"
  fi
  
  RemovePIDFile "${VLLM_PIDFILE}"
}

# ==============================================================================
# Commands
# ==============================================================================
CMDStartRay() {
  EnsureDirs
  ExportToolchainEnv
  ExportRuntimeEnv
  PrintEnvSummary
  
  if IsHeadNode; then
    StartRayHead
  else
    StartRayWorker
  fi
}

CMDLoadModel() {
  EnsureDirs
  ExportToolchainEnv
  ExportRuntimeEnv
  LoadModel
}

CMDStopModel() {
  StopModel
}

CMDStopRay() {
  StopRayHard
  RemovePIDFile "${RAY_PIDFILE}"
}

CMDStopAll() {
  StopModel
  StopRayHard
  RemovePIDFile "${RAY_PIDFILE}"
}

CMDStatus() {
  Log "=== Status ==="
  Log "THIS_NODE=${THIS_NODE}"
  Log "Ray head: ${RAY_HEAD_IP}:${RAY_PORT}"
  Log "Ray node: ${RAY_NODE_IP}"
  
  if [[ -f "${RAY_PIDFILE}" ]]; then
    local rpid
    rpid="$(ReadPIDFile "${RAY_PIDFILE}" || true)"
    if [[ -n "${rpid}" ]] && IsPIDRunning "${rpid}"; then
      Log "Ray: RUNNING"
    else
      Log "Ray: pidfile present but not running"
    fi
  else
    Log "Ray: no pidfile"
  fi
  
  if [[ -f "${VLLM_PIDFILE}" ]]; then
    local vpid
    vpid="$(ReadPIDFile "${VLLM_PIDFILE}" || true)"
    if [[ -n "${vpid}" ]] && IsPIDRunning "${vpid}"; then
      Log "vLLM: RUNNING (pid=${vpid})"
    else
      Log "vLLM: pidfile present but not running"
    fi
  else
    Log "vLLM: no pidfile"
  fi
  
  if command -v "${RAY_BIN}" >/dev/null 2>&1; then
    ${RAY_BIN} status 2>&1 || true
  fi
}

Usage() {
  cat <<EOF
Usage:
  ./vllm_cluster_mgr.sh <command>

Commands:
  start-ray     Start Ray cluster (head or worker based on THIS_NODE)
  load-model    Load model on head node (requires Ray running)
  stop-model    Stop model (keep Ray running)
  stop-ray      Stop Ray cluster
  stop-all      Stop model and Ray
  status        Show cluster status

Environment (cluster):
  THIS_NODE=<1|2|3|4>        Node number (1=head, 2-4=workers)
  RAY_HEAD_IP=<ip>           Head node fabric IP (e.g. 10.10.10.1)
  RAY_NODE_IP=<ip>           This node's fabric IP (auto-detected if unset)
  RAY_PORT=<port>            Ray GCS port (default: 6379)
  RAY_DASHBOARD_PORT=<port>  Ray dashboard port (default: 8265)
  RAY_MIN_WORKER_PORT=<port> Ray worker port range lower bound (default: 20000)
  RAY_MAX_WORKER_PORT=<port> Ray worker port range upper bound (default: 29000)
  RAY_NODE_MANAGER_PORT=<p>  Ray node manager port (default: auto)
  RAY_OBJECT_MANAGER_PORT=<p> Ray object manager port (default: auto)

Environment (model):
  MODEL_DIR=<path>           Model directory (default: /opt/ai-models/hf/CHANGE_ME)
  SERVED_MODEL_NAME=<name>   Model name in API
  TENSOR_PARALLEL_SIZE=<n>   Number of GPUs (default: 2)
  QUANTIZATION=<method>      awq, gptq, fp8, etc.
  MAX_MODEL_LEN=<tokens>     Context length
  GPU_MEMORY_UTILIZATION=<f> Fraction (default: 0.92)
  VLLM_API_PORT=<port>        API server port (default: 8000)
                             NOTE: Do NOT use VLLM_PORT — that is reserved by
                             vLLM internally for ZMQ IPC and will cause a port
                             conflict if set externally.
  VLLM_MASTER_PORT=<port>    PyTorch/NCCL distributed rendezvous port (default: 29500)
                             MUST differ from VLLM_PORT and Ray ports.
                             If running two TP>1 instances, give each a unique value.
  VLLM_WORKER_PORT_BASE=<p>  Base port for vLLM Ray actor RPC (default: auto)

Examples:
  # Node 1 (head) - start Ray
  THIS_NODE=1 RAY_NODE_IP=10.10.10.1 ./vllm_cluster_mgr.sh start-ray

  # Node 2 (worker) - start Ray
  THIS_NODE=2 RAY_HEAD_IP=10.10.10.1 RAY_NODE_IP=10.10.10.2 ./vllm_cluster_mgr.sh start-ray

  # Node 1 (head) - load model
  MODEL_DIR=/opt/ai-models/hf/Qwen3-VL-235B-AWQ \\
    SERVED_MODEL_NAME=qwen3-vl-235b \\
    TENSOR_PARALLEL_SIZE=2 \\
    QUANTIZATION=awq \\
    ./vllm_cluster_mgr.sh load-model
EOF
}

# ==============================================================================
# Main
# ==============================================================================
Main() {
  local cmd="${1:-}"
  
  case "${cmd}" in
    start-ray)   CMDStartRay ;;
    load-model)  CMDLoadModel ;;
    stop-model)  CMDStopModel ;;
    stop-ray)    CMDStopRay ;;
    stop-all)    CMDStopAll ;;
    status)      CMDStatus ;;
    ""|help|-h|--help) Usage ;;
    *) Die "Unknown command: ${cmd}" ;;
  esac
}

Main "$@"
