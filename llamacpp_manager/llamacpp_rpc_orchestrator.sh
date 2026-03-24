#!/usr/bin/env bash
# llama.cpp RPC Cluster Orchestrator
#
# Manages distributed inference across 4x DGX Spark GB10 nodes
# Master: magnesium (192.168.2.42) - hosts model, does tokenization
# Workers: aluminium, silicon, phosphorus - run RPC servers
#
# Modes:
#   --mode cluster (default): Run from cluster node (master=node1, workers=nodes2-4)
#   --mode remote:            Run from remote machine (all 4 nodes as workers)
#
# Usage:
#   # From your Mac (remote mode - all 4 nodes as workers):
#   ./llamacpp_rpc_orchestrator.sh --mode remote start-workers
#   ./llamacpp_rpc_orchestrator.sh --mode remote start-master <profile> [cli|server]
#
#   # From cluster node (cluster mode - node1=master, nodes2-4=workers):
#   ./llamacpp_rpc_orchestrator.sh start-workers
#   ./llamacpp_rpc_orchestrator.sh start-master <profile> [cli|server]
#
#   # Common commands:
#   ./llamacpp_rpc_orchestrator.sh stop
#   ./llamacpp_rpc_orchestrator.sh status

set -euo pipefail

# ============================================================================
# Parse Mode Flag
# ============================================================================

MODE="cluster"  # Default: cluster mode (master=node1, workers=nodes2-4)

# Parse --mode before anything else
TEMP_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)
      MODE="$2"
      if [[ "$MODE" != "cluster" && "$MODE" != "remote" ]]; then
        echo "ERROR: --mode must be 'cluster' or 'remote'" >&2
        exit 1
      fi
      shift 2
      ;;
    *)
      TEMP_ARGS+=("$1")
      shift
      ;;
  esac
done
set -- "${TEMP_ARGS[@]}"  # Restore positional parameters

# ============================================================================
# Load Cluster Configuration
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/cluster_config.sh"

if [[ ! -f "${CONFIG_FILE}" ]]; then
  echo "ERROR: cluster_config.sh not found at ${CONFIG_FILE}" >&2
  echo "Please ensure cluster_config.sh is in the same directory as this script." >&2
  exit 1
fi

source "${CONFIG_FILE}"

# ============================================================================
# llama.cpp RPC Specific Configuration
# ============================================================================

# Binary paths
LLAMA_RPC_SERVER="${LLAMA_CPP_RPC_BIN}/rpc-server"
LLAMA_CLI="${LLAMA_CPP_RPC_BIN}/llama-cli"
LLAMA_SERVER="${LLAMA_CPP_RPC_BIN}/llama-server"

# BuildLlamaCppArgs - Merge MODEL_OPTS + LLAMA_RUNTIME into command-line args
#
# Arguments:
#   $1 - model_profile (string)
# Outputs: Command-line arguments string
# Returns: 0 on success
# Globals: Reads MODEL_OPTS, LLAMA_RUNTIME
BuildLlamaCppArgs() {
  local profile="$1"
  local args=""
  
  # Load semantic options
  if [[ -n "${MODEL_OPTS[$profile]:-}" ]]; then
    eval "${MODEL_OPTS[$profile]}"
    
    # Map semantic → llama.cpp flags
    [[ -n "${CONTEXT_SIZE:-}" ]] && args+=" --ctx-size ${CONTEXT_SIZE}"
    [[ -n "${MAX_CONCURRENCY:-}" ]] && args+=" --parallel ${MAX_CONCURRENCY}"
    [[ -n "${ENABLE_PREFIX_CACHE:-}" ]] && [[ "${ENABLE_PREFIX_CACHE}" == "1" ]] && args+=" --cache-prompt"
  fi
  
  # Load runtime-specific options
  if [[ -n "${LLAMA_RUNTIME[$profile]:-}" ]]; then
    eval "${LLAMA_RUNTIME[$profile]}"
    
    [[ -n "${N_GPU_LAYERS:-}" ]] && args+=" --n-gpu-layers ${N_GPU_LAYERS}"
    [[ -n "${THREADS:-}" ]] && args+=" --threads ${THREADS}"
    [[ -n "${BATCH_SIZE:-}" ]] && args+=" --batch-size ${BATCH_SIZE}"
    [[ -n "${UBATCH_SIZE:-}" ]] && args+=" --ubatch-size ${UBATCH_SIZE}"
    [[ -n "${FLASH_ATTN:-}" ]] && [[ "${FLASH_ATTN}" == "1" ]] && args+=" --flash-attn"
    [[ -n "${CONT_BATCHING:-}" ]] && [[ "${CONT_BATCHING}" == "1" ]] && args+=" --cont-batching"
  fi
  
  echo "$args"
}


# ============================================================================
# Utility Functions
# ============================================================================

# Log - Write timestamped log message
#
# Arguments: All message components ($@)
# Outputs: Timestamped message to stdout
# Returns: 0 (always succeeds)
# Globals: None
Log() {
  echo "[$(date +'%FT%T')] $*"
}

# Die - Write error and exit
#
# Arguments: All error message components ($@)
# Outputs: Error to stderr
# Returns: Exits with code 1
# Globals: None
Die() {
  echo "[$(date +'%FT%T')] ERROR: $*" >&2
  exit 1
}

# SSHExec - Execute command on remote node
#
# Arguments:
#   $1 - node_ip (string)
#   $@ - command to execute
# Outputs: Command output to stdout
# Returns: Command exit code
# Globals: Reads SSH_USER, SSH_OPTS
SSHExec() {
  local node_ip="$1"
  shift
  ssh ${SSH_OPTS} "${SSH_USER}@${node_ip}" "$@"
}

# CheckLlamaBinaries - Verify llama.cpp binaries exist on cluster nodes
#
# Arguments: None
# Outputs: Warning if run from non-cluster machine
# Returns: 0 (checks happen on remote nodes during execution)
# Globals: Reads MASTER_NODE, WORKER_NODES
CheckLlamaBinaries() {
  local hostname=""
  hostname=$(hostname)
  
  # Check if we're on a cluster node
  local on_cluster=false
  for node in "$MASTER_NODE" "${WORKER_NODES[@]}"; do
    if [[ "$hostname" == "$node" ]]; then
      on_cluster=true
      break
    fi
  done
  
  if [[ "$on_cluster" == "false" ]]; then
    Log "⚠ Running from non-cluster machine ($hostname)"
    Log "  Binary checks will occur on remote nodes via SSH"
  else
    # We're on a cluster node, verify local binaries
    if [[ ! -x "$LLAMA_RPC_SERVER" ]]; then
      Die "llama-rpc-server not found at $LLAMA_RPC_SERVER on $hostname"
    fi
    
    if [[ ! -x "$LLAMA_CLI" ]] && [[ ! -x "$LLAMA_SERVER" ]]; then
      Die "llama-cli and llama-server not found on $hostname"
    fi
    
    Log "✓ llama.cpp binaries verified on $hostname"
  fi
}

# StartWorkerNode - Start RPC server on a worker node
#
# Arguments:
#   $1 - node_name (string)
#   $2 - node_ip (string)
# Outputs: Status messages via Log
# Returns: 0 on success, non-zero on failure
# Globals: Reads RPC_PORT, WORKER_MEMORY, LOG_DIR
StartWorkerNode() {
  local node_name="$1"
  local node_ip="$2"
  local log_file=""
  
  log_file="${LLAMA_RPC_LOG_DIR}/${node_name}_rpc_server.log"
  
  Log "Starting RPC server on ${node_name} (${node_ip})..."
  
  # Check if already running
  if SSHExec "$node_ip" "pgrep -f llama-rpc-server" >/dev/null 2>&1; then
    Log "  RPC server already running on ${node_name}"
    return 0
  fi
  
  # Start RPC server via SSH
  # Use nohup to persist after SSH disconnect
  SSHExec "$node_ip" "
    sudo mkdir -p ${LLAMA_RPC_LOG_DIR}
    sudo chown ${SSH_USER}:${SSH_USER} ${LLAMA_RPC_LOG_DIR}
    nohup ${LLAMA_RPC_SERVER} \
      -H 0.0.0.0 \
      -p ${LLAMA_RPC_PORT} \
      -m ${WORKER_MEMORY_MB} \
      --cache \
      > ${log_file} 2>&1 &
    echo \$! > ${LLAMA_RPC_LOG_DIR}/${node_name}_rpc_server.pid
  "
  
  # Wait for server to start
  sleep 2
  
  # Verify it's running
  if SSHExec "$node_ip" "pgrep -f llama-rpc-server" >/dev/null 2>&1; then
    Log "  ✓ RPC server started on ${node_name}"
  else
    Log "  ✗ RPC server failed to start on ${node_name}"
    Log "    Check log: ssh ${SSH_USER}@${node_ip} tail -50 ${log_file}"
    return 1
  fi
}

# StartAllWorkers - Start RPC servers on worker nodes
#
# Arguments: None
# Outputs: Progress via Log
# Returns: 0 (always succeeds, individual failures logged)
# Globals: Reads MODE, MASTER_NODE, MASTER_IP, WORKER_NODES, WORKER_IPS
StartAllWorkers() {
  local i=0
  local nodes_to_start=()
  local ips_to_start=()
  
  if [[ "$MODE" == "remote" ]]; then
    # Remote mode: Start RPC servers on ALL 4 nodes
    Log "Starting RPC servers on all 4 nodes (remote mode)..."
    nodes_to_start=("$MASTER_NODE" "${WORKER_NODES[@]}")
    ips_to_start=("$MASTER_IP" "${WORKER_IPS[@]}")
  else
    # Cluster mode: Start RPC servers on nodes 2-4 only (node 1 is master)
    Log "Starting RPC servers on worker nodes (cluster mode)..."
    nodes_to_start=("${WORKER_NODES[@]}")
    ips_to_start=("${WORKER_IPS[@]}")
  fi
  
  for i in "${!nodes_to_start[@]}"; do
    StartWorkerNode "${nodes_to_start[$i]}" "${ips_to_start[$i]}" || true
  done
  
  Log "Worker startup complete"
}

# BuildRPCEndpoints - Build --rpc argument for llama-cli
#
# Arguments: None
# Outputs: Comma-separated RPC endpoints to stdout
# Returns: 0 (always succeeds)
# Globals: Reads MODE, MASTER_IP, WORKER_IPS, LLAMA_RPC_PORT
BuildRPCEndpoints() {
  local endpoints=()
  local ip=""
  
  if [[ "$MODE" == "remote" ]]; then
    # Remote mode: All 4 nodes are RPC workers
    endpoints+=("${MASTER_IP}:${LLAMA_RPC_PORT}")
    for ip in "${WORKER_IPS[@]}"; do
      endpoints+=("${ip}:${LLAMA_RPC_PORT}")
    done
  else
    # Cluster mode: Only nodes 2-4 are RPC workers
    for ip in "${WORKER_IPS[@]}"; do
      endpoints+=("${ip}:${LLAMA_RPC_PORT}")
    done
  fi
  
  # Join with commas
  local IFS=','
  echo "${endpoints[*]}"
}

# StartMaster - Start master node inference (interactive or server mode)
#
# Arguments:
#   $1 - model_profile (string)
#   $2 - mode (optional: "cli" or "server", default: cli)
# Outputs: Delegates to llama-cli or llama-server
# Returns: Exit code from llama binary
# Globals: Reads LLAMA_MODELS, MODEL_OPTS, LLAMA_RUNTIME
StartMaster() {
  local profile="$1"
  local mode="${2:-cli}"
  local model_path=""
  local llama_args=""
  local rpc_endpoints=""
  local hostname=""
  
  hostname=$(hostname)
  
  # Verify we're on master node
  if [[ "$hostname" != "$MASTER_NODE" ]]; then
    Die "Master must run on ${MASTER_NODE}, currently on ${hostname}"
  fi
  
  # Verify model profile exists
  if [[ -z "${LLAMA_MODELS[$profile]:-}" ]]; then
    Die "Unknown model profile: $profile. Available: ${!LLAMA_MODELS[*]}"
  fi
  
  model_path="${LLAMA_MODELS[$profile]}"
  llama_args=$(BuildLlamaCppArgs "$profile")
  
  # Verify model file exists
  if [[ ! -f "$model_path" ]]; then
    Die "Model file not found: $model_path"
  fi
  
  # Build RPC endpoints
  rpc_endpoints=$(BuildRPCEndpoints)
  
  Log "Starting master on ${MASTER_NODE}"
  Log "  Model: ${model_path}"
  Log "  Profile: ${profile}"
  Log "  RPC workers: ${rpc_endpoints}"
  Log "  Mode: ${mode}"
  
  case "$mode" in
    cli)
      # Interactive CLI mode
      Log "Starting llama-cli in interactive mode..."
      Log "Type your prompt and press Enter. Ctrl+C to exit."
      
      # shellcheck disable=SC2086
      exec "$LLAMA_CLI" \
        --model "$model_path" \
        --rpc "$rpc_endpoints" \
        $llama_args \
        --interactive
      ;;
      
    server)
      # OpenAI-compatible API server mode
      local port="${LLAMA_SERVER_PORT:-8080}"
      
      Log "Starting llama-server on port ${port}..."
      Log "OpenAI-compatible API at: http://${MASTER_IP}:${port}/v1"
      
      # shellcheck disable=SC2086
      exec "$LLAMA_SERVER" \
        --model "$model_path" \
        --rpc "$rpc_endpoints" \
        $llama_args \
        --host 0.0.0.0 \
        --port "$port"
      ;;
      
    *)
      Die "Invalid mode: $mode (must be 'cli' or 'server')"
      ;;
  esac
}

# StopWorkerNode - Stop RPC server on a worker node
#
# Arguments:
#   $1 - node_name (string)
#   $2 - node_ip (string)
# Outputs: Status messages via Log
# Returns: 0 (always succeeds)
# Globals: Reads LOG_DIR
StopWorkerNode() {
  local node_name="$1"
  local node_ip="$2"
  
  Log "Stopping RPC server on ${node_name}..."
  
  SSHExec "$node_ip" "
    if pgrep -f llama-rpc-server >/dev/null 2>&1; then
      pkill -f llama-rpc-server
      sleep 1
      
      # Force kill if still running
      if pgrep -f llama-rpc-server >/dev/null 2>&1; then
        pkill -9 -f llama-rpc-server
      fi
      
      echo '  ✓ Stopped RPC server on ${node_name}'
    else
      echo '  RPC server not running on ${node_name}'
    fi
    
    # Clean up PID file
    rm -f ${LLAMA_RPC_LOG_DIR}/${node_name}_rpc_server.pid
  " || true
}

# StopAllWorkers - Stop RPC servers on all worker nodes
#
# Arguments: None
# Outputs: Progress via Log
# Returns: 0 (always succeeds)
# Globals: Reads WORKER_NODES, WORKER_IPS
StopAllWorkers() {
  local i=0
  
  Log "Stopping RPC servers on all worker nodes..."
  
  for i in "${!WORKER_NODES[@]}"; do
    StopWorkerNode "${WORKER_NODES[$i]}" "${WORKER_IPS[$i]}"
  done
  
  Log "Worker shutdown complete"
}

# StopMaster - Stop master process
#
# Arguments: None
# Outputs: Status via Log
# Returns: 0 (always succeeds)
# Globals: None
StopMaster() {
  local hostname=""
  hostname=$(hostname)
  
  Log "Stopping master processes on ${hostname}..."
  
  if pgrep -f "llama-cli.*--rpc" >/dev/null 2>&1; then
    pkill -f "llama-cli.*--rpc"
    Log "  ✓ Stopped llama-cli"
  fi
  
  if pgrep -f "llama-server.*--rpc" >/dev/null 2>&1; then
    pkill -f "llama-server.*--rpc"
    Log "  ✓ Stopped llama-server"
  fi
}

# ShowStatus - Display cluster status
#
# Arguments: None
# Outputs: Status table to stdout
# Returns: 0 (always succeeds)
# Globals: Reads all cluster configuration
ShowStatus() {
  local i=0
  local node_name=""
  local node_ip=""
  local worker_status=""
  local hostname=""
  
  hostname=$(hostname)
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo "  llama.cpp RPC Cluster Status"
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
  echo "Master Node: ${MASTER_NODE} (${MASTER_IP})"
  
  if [[ "$hostname" == "$MASTER_NODE" ]]; then
    if pgrep -f "llama-cli.*--rpc" >/dev/null 2>&1; then
      echo "  Status: ✓ llama-cli running (interactive)"
    elif pgrep -f "llama-server.*--rpc" >/dev/null 2>&1; then
      echo "  Status: ✓ llama-server running (API mode)"
    else
      echo "  Status: ✗ No master process running"
    fi
  else
    echo "  (Current node: ${hostname})"
  fi
  
  echo ""
  echo "Worker Nodes:"
  
  for i in "${!WORKER_NODES[@]}"; do
    node_name="${WORKER_NODES[$i]}"
    node_ip="${WORKER_IPS[$i]}"
    
    if SSHExec "$node_ip" "pgrep -f llama-rpc-server" >/dev/null 2>&1; then
      worker_status="✓ Running"
    else
      worker_status="✗ Stopped"
    fi
    
    printf "  %-12s (%s) - %s\n" "$node_name" "$node_ip" "$worker_status"
  done
  
  echo ""
  echo "RPC Configuration:"
  echo "  Port: ${LLAMA_RPC_PORT}"
  echo "  Worker memory: ${WORKER_MEMORY_MB}MB (per node)"
  echo "  Total cluster memory: $((WORKER_MEMORY * ${#WORKER_NODES[@]} / 1024))GB"
  echo ""
  echo "Available Models:"
  
  for profile in "${!MODELS[@]}"; do
    echo "  - $profile: ${LLAMA_MODELS[$profile]}"
  done
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
}

# ShowUsage - Display help text
#
# Arguments: None
# Outputs: Usage text to stdout
# Returns: Exits with code 0
# Globals: None
ShowUsage() {
  cat <<'USAGE'
Usage: llamacpp_rpc_orchestrator.sh <command> [options]

Commands:
  start-workers              Start RPC servers on all worker nodes
  start-master <profile>     Start master inference (interactive CLI)
  start-server <profile>     Start master as OpenAI API server
  stop                       Stop all RPC servers and master
  stop-workers               Stop only worker RPC servers
  stop-master                Stop only master process
  status                     Show cluster status
  check-binaries             Verify llama.cpp binaries installed

Model Profiles:
  deepseek-v3-q4            DeepSeek-V3 Q4_K_M quantization (~340GB)
  deepseek-v3-q5            DeepSeek-V3 Q5_K_M quantization (~420GB)

Examples:
  # Full cluster startup (run from master node):
  ./llamacpp_rpc_orchestrator.sh start-workers
  ./llamacpp_rpc_orchestrator.sh start-master deepseek-v3-q4

  # API server mode:
  ./llamacpp_rpc_orchestrator.sh start-server deepseek-v3-q4

  # Shutdown:
  ./llamacpp_rpc_orchestrator.sh stop

  # Check status:
  ./llamacpp_rpc_orchestrator.sh status

Environment Variables:
  LLAMA_SERVER_PORT         API server port (default: 8080)

Logs:
  Worker logs: /opt/ai-tools/logs/llama-rpc/<node>_rpc_server.log
  
Network:
  Uses fabric network (10.10.10.x) for RPC communication
  Master: 192.168.2.41 (magnesium)
  Workers: 192.168.2.42-44 (aluminium, silicon, phosphorus)
USAGE
  exit 0
}

# CoreExec - Main execution function
#
# Arguments: All command-line args ($@)
# Outputs: Delegates to subcommands
# Returns: Exit code from subcommand
# Globals: Uses all globals
CoreExec() {
  local command="${1:-}"
  
  # Ensure log directory exists (on local machine only, workers handle their own)
  if [[ "$command" == "start-master" ]]; then
    sudo mkdir -p "${LLAMA_RPC_LOG_DIR}"
    sudo chown "${SSH_USER}:${SSH_USER}" "${LLAMA_RPC_LOG_DIR}"
  fi
  
  case "$command" in
    start-workers)
      CheckLlamaBinaries
      StartAllWorkers
      ;;
      
    start-master)
      local profile="${2:-}"
      [[ -z "$profile" ]] && Die "Usage: $0 start-master <model_profile>"
      CheckLlamaBinaries
      StartMaster "$profile" "cli"
      ;;
      
    start-server)
      local profile="${2:-}"
      [[ -z "$profile" ]] && Die "Usage: $0 start-server <model_profile>"
      CheckLlamaBinaries
      StartMaster "$profile" "server"
      ;;
      
    stop)
      StopMaster
      StopAllWorkers
      ;;
      
    stop-workers)
      StopAllWorkers
      ;;
      
    stop-master)
      StopMaster
      ;;
      
    status)
      ShowStatus
      ;;
      
    check-binaries)
      CheckLlamaBinaries
      ;;
      
    --help|-h|help|"")
      ShowUsage
      ;;
      
    *)
      Die "Unknown command: $command (use --help)"
      ;;
  esac
}

# ============================================================================
# Entry Point
# ============================================================================

CoreExec "$@"
