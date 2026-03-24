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

# Binary paths (on remote nodes)
LLAMA_RPC_SERVER="${LLAMA_CPP_RPC_BIN}/rpc-server"
LLAMA_CLI="${LLAMA_CPP_RPC_BIN}/llama-cli"
LLAMA_SERVER="${LLAMA_CPP_RPC_BIN}/llama-server"

# BuildLlamaCppArgs - Merge MODEL_OPTS + LLAMA_RUNTIME into command-line args
# RUNS: Locally (just builds a string)
BuildLlamaCppArgs() {
  local profile="$1"
  local args=""
  
  # Load semantic options
  if [[ -n "${MODEL_OPTS[$profile]:-}" ]]; then
    eval "${MODEL_OPTS[$profile]}"
    
    # Map semantic → llama.cpp flags
    [[ -n "${CONTEXT_SIZE:-}" ]] && args+=" --ctx-size ${CONTEXT_SIZE}"
    [[ -n "${MAX_CONCURRENCY:-}" ]] && args+=" --parallel ${MAX_CONCURRENCY}"
    # Note: Prefix caching is automatic in llama.cpp - no flag needed
  fi
  
  # Load runtime-specific options
  if [[ -n "${LLAMA_RUNTIME[$profile]:-}" ]]; then
    eval "${LLAMA_RUNTIME[$profile]}"
    
    [[ -n "${N_GPU_LAYERS:-}" ]] && args+=" --n-gpu-layers ${N_GPU_LAYERS}"
    [[ -n "${THREADS:-}" ]] && args+=" --threads ${THREADS}"
    [[ -n "${BATCH_SIZE:-}" ]] && args+=" --batch-size ${BATCH_SIZE}"
    [[ -n "${UBATCH_SIZE:-}" ]] && args+=" --ubatch-size ${UBATCH_SIZE}"
    [[ -n "${FLASH_ATTN:-}" ]] && [[ "${FLASH_ATTN}" == "1" ]] && args+=" --flash-attn on"
    # Note: --cont-batching is server-only, not used for llama-cli
  fi
  
  echo "$args"
}

# ============================================================================
# Utility Functions
# ============================================================================

# Log - Write timestamped log message
# RUNS: Locally
Log() {
  echo "[$(date +'%FT%T')] $*"
}

# Die - Write error and exit
# RUNS: Locally
Die() {
  echo "[$(date +'%FT%T')] ERROR: $*" >&2
  exit 1
}

# SSHExec - Execute command on remote node
# RUNS: Locally (but executes on remote)
SSHExec() {
  local node_ip="$1"
  shift
  ssh ${SSH_OPTS} "${SSH_USER}@${node_ip}" "$@"
}

# CheckLlamaBinaries - Verify llama.cpp binaries exist
# RUNS: Locally (checks local binaries if on cluster node, otherwise just warns)
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
      Die "rpc-server not found at $LLAMA_RPC_SERVER on $hostname"
    fi
    
    if [[ ! -x "$LLAMA_CLI" ]] && [[ ! -x "$LLAMA_SERVER" ]]; then
      Die "llama-cli and llama-server not found on $hostname"
    fi
    
    Log "✓ llama.cpp binaries verified on $hostname"
  fi
}

# StartWorkerNode - Start RPC server on a worker node
# RUNS: Locally (but starts process on remote via SSH)
StartWorkerNode() {
  local node_name="$1"
  local node_ip="$2"  # Management IP for SSH
  local rdma_ip=""
  local log_file="${LLAMA_RPC_LOG_DIR}/${node_name}_rpc_server.log"
  
  # Map node name to RDMA IP
  case "$node_name" in
    magnesium) rdma_ip="10.10.10.1" ;;
    aluminium) rdma_ip="10.10.10.2" ;;
    silicon)   rdma_ip="10.10.10.3" ;;
    phosphorus) rdma_ip="10.10.10.4" ;;
    *) Die "Unknown node name: $node_name" ;;
  esac
  
  Log "Starting RPC server on ${node_name} (${node_ip}, RDMA: ${rdma_ip})..."
  
  # Check if already running (REMOTE CHECK)
  if SSHExec "$node_ip" "pgrep -f rpc-server" >/dev/null 2>&1; then
    Log "  RPC server already running on ${node_name}"
    return 0
  fi
  
  # Start RPC server via SSH - bind to 100G RDMA IP only
  SSHExec "$node_ip" "
    sudo mkdir -p ${LLAMA_RPC_LOG_DIR}
    sudo chown ${SSH_USER}:${SSH_USER} ${LLAMA_RPC_LOG_DIR}
    nohup ${LLAMA_RPC_SERVER} \
      -H ${rdma_ip} \
      -p ${LLAMA_RPC_PORT} \
      -t 64 \
      --cache \
      > ${log_file} 2>&1 &
    echo \$! > ${LLAMA_RPC_LOG_DIR}/${node_name}_rpc_server.pid
  "
  
  # Wait for server to start
  sleep 2
  
  # Verify it's running (REMOTE CHECK)
  if SSHExec "$node_ip" "pgrep -f rpc-server" >/dev/null 2>&1; then
    Log "  ✓ RPC server started on ${node_name} (listening on ${rdma_ip}:${LLAMA_RPC_PORT})"
  else
    Log "  ✗ RPC server failed to start on ${node_name}"
    Log "    Check log: ssh ${SSH_USER}@${node_ip} tail -50 ${log_file}"
    return 1
  fi
}

# StartAllWorkers - Start RPC servers on worker nodes
# RUNS: Locally (orchestrates remote starts)
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
# RUNS: Locally (just builds a string)
BuildRPCEndpoints() {
  local endpoints=()
  local rdma_ip=""
  
  if [[ "$MODE" == "remote" ]]; then
    # Remote mode: Master uses LOCAL GPU, workers 2-4 as RPC (no master in RPC list)
    endpoints+=("10.10.10.2:${LLAMA_RPC_PORT}")  # aluminium RDMA
    endpoints+=("10.10.10.3:${LLAMA_RPC_PORT}")  # silicon RDMA
    endpoints+=("10.10.10.4:${LLAMA_RPC_PORT}")  # phosphorus RDMA
  else
    # Cluster mode: Master runs locally, workers 2-4 as RPC
    endpoints+=("10.10.10.2:${LLAMA_RPC_PORT}")  # aluminium RDMA
    endpoints+=("10.10.10.3:${LLAMA_RPC_PORT}")  # silicon RDMA
    endpoints+=("10.10.10.4:${LLAMA_RPC_PORT}")  # phosphorus RDMA
  fi
  
  # Join with commas
  local IFS=','
  echo "${endpoints[*]}"
}

# StartMaster - Start master node inference
# RUNS: Depends on mode
#   - cluster mode: Must run on master node (local execution)
#   - remote mode: SSH to master node and exec there
StartMaster() {
  local profile="$1"
  local mode="${2:-cli}"
  local model_path=""
  local llama_args=""
  local rpc_endpoints=""
  local hostname=""
  
  hostname=$(hostname)
  
  # Verify model profile exists
  if [[ -z "${LLAMA_MODELS[$profile]:-}" ]]; then
    Die "Unknown model profile: $profile. Available: ${!LLAMA_MODELS[*]}"
  fi
  
  model_path="${LLAMA_MODELS[$profile]}"
  llama_args=$(BuildLlamaCppArgs "$profile")
  rpc_endpoints=$(BuildRPCEndpoints)
  
  # In remote mode, SSH to master node and exec there
  if [[ "$MODE" == "remote" ]]; then
    if [[ "$hostname" == "$MASTER_NODE" ]]; then
      Die "Already on master node - don't use --mode remote when running from the cluster"
    fi
    
    Log "Connecting to master node (${MASTER_NODE}) and starting inference..."
    Log "Model: ${model_path}"
    Log "Profile: ${profile}"
    Log "RPC workers: ${rpc_endpoints}"
    Log "Mode: ${mode}"
    
    case "$mode" in
      cli)
        # Interactive mode - need terminal passthrough
        # llama-cli supports --interactive flag
        SSHExec "${MASTER_IP}" "
          ${LLAMA_CLI} \
            --model ${model_path} \
            --rpc ${rpc_endpoints} \
            ${llama_args} \
            --interactive
        "
        ;;
      server)
        # Server mode - run in background on remote
        # llama-server does NOT use --interactive flag
        local port="${LLAMA_SERVER_PORT:-8080}"
        Log "Starting llama-server on ${MASTER_NODE}:${port}..."
        Log "OpenAI-compatible API at: http://${MASTER_IP}:${port}/v1"
        
        SSHExec "${MASTER_IP}" "
          sudo mkdir -p ${LLAMA_RPC_LOG_DIR}
          nohup ${LLAMA_SERVER} \
            --model ${model_path} \
            --rpc ${rpc_endpoints} \
            ${llama_args} \
            --host 0.0.0.0 \
            --port ${port} \
            > ${LLAMA_RPC_LOG_DIR}/master_server.log 2>&1 &
          echo \$! > ${LLAMA_RPC_LOG_DIR}/master_server.pid
        "
        Log "Server started on ${MASTER_NODE}"
        ;;
      *)
        Die "Invalid mode: $mode (must be 'cli' or 'server')"
        ;;
    esac
    
  else
    # Cluster mode: verify we're on master node and exec locally
    if [[ "$hostname" != "$MASTER_NODE" ]]; then
      Die "Master must run on ${MASTER_NODE}, currently on ${hostname}"
    fi
    
    # Verify model file exists (LOCAL CHECK)
    if [[ ! -f "$model_path" ]]; then
      Die "Model file not found: $model_path"
    fi
    
    Log "Starting master on ${MASTER_NODE}"
    Log "  Model: ${model_path}"
    Log "  Profile: ${profile}"
    Log "  RPC workers: ${rpc_endpoints}"
    Log "  Mode: ${mode}"
    
    case "$mode" in
      cli)
        # Interactive CLI mode (LOCAL EXEC)
        # llama-cli supports --interactive flag
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
        # OpenAI-compatible API server mode (LOCAL EXEC)
        # llama-server does NOT use --interactive flag
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
  fi
}

# StopWorkerNode - Stop RPC server on a worker node
# RUNS: Locally (but stops process on remote via SSH)
StopWorkerNode() {
  local node_name="$1"
  local node_ip="$2"
  
  Log "Stopping RPC server on ${node_name}..."
  
  # RUNS ON REMOTE
  SSHExec "$node_ip" "
    if pgrep -f rpc-server >/dev/null 2>&1; then
      pkill -f rpc-server
      sleep 1
      
      # Force kill if still running
      if pgrep -f rpc-server >/dev/null 2>&1; then
        pkill -9 -f rpc-server
      fi
      
      echo '  ✓ Stopped RPC server'
    else
      echo '  RPC server not running'
    fi
    
    # Clean up PID file
    rm -f ${LLAMA_RPC_LOG_DIR}/${node_name}_rpc_server.pid
  " || true
}

# StopAllWorkers - Stop RPC servers on all nodes
# RUNS: Locally (orchestrates remote stops)
StopAllWorkers() {
  local i=0
  local nodes_to_stop=()
  local ips_to_stop=()
  
  if [[ "$MODE" == "remote" ]]; then
    # Remote mode: Stop ALL 4 nodes
    Log "Stopping RPC servers on all 4 nodes (remote mode)..."
    nodes_to_stop=("$MASTER_NODE" "${WORKER_NODES[@]}")
    ips_to_stop=("$MASTER_IP" "${WORKER_IPS[@]}")
  else
    # Cluster mode: Stop nodes 2-4 only
    Log "Stopping RPC servers on worker nodes (cluster mode)..."
    nodes_to_stop=("${WORKER_NODES[@]}")
    ips_to_stop=("${WORKER_IPS[@]}")
  fi
  
  for i in "${!nodes_to_stop[@]}"; do
    StopWorkerNode "${nodes_to_stop[$i]}" "${ips_to_stop[$i]}"
  done
  
  Log "Worker shutdown complete"
}

# StopMaster - Stop master process
# RUNS: Depends on mode
#   - cluster mode: Must run on master node (local process kill)
#   - remote mode: SSH to master and kill there
StopMaster() {
  local hostname=""
  hostname=$(hostname)
  
  if [[ "$MODE" == "remote" ]]; then
    # Remote mode: SSH to master and kill
    Log "Stopping master processes on ${MASTER_NODE}..."
    
    SSHExec "${MASTER_IP}" "
      if pgrep -f 'llama-cli.*--rpc' >/dev/null 2>&1; then
        pkill -f 'llama-cli.*--rpc'
        echo '  ✓ Stopped llama-cli'
      fi
      
      if pgrep -f 'llama-server.*--rpc' >/dev/null 2>&1; then
        pkill -f 'llama-server.*--rpc'
        echo '  ✓ Stopped llama-server'
      fi
      
      rm -f ${LLAMA_RPC_LOG_DIR}/master_server.pid
    " || true
    
  else
    # Cluster mode: kill local processes
    Log "Stopping master processes on ${hostname}..."
    
    if pgrep -f "llama-cli.*--rpc" >/dev/null 2>&1; then
      pkill -f "llama-cli.*--rpc"
      Log "  ✓ Stopped llama-cli"
    fi
    
    if pgrep -f "llama-server.*--rpc" >/dev/null 2>&1; then
      pkill -f "llama-server.*--rpc"
      Log "  ✓ Stopped llama-server"
    fi
  fi
}

# ShowStatus - Display cluster status
# RUNS: Mixed (local checks + remote SSH checks)
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
  echo "Mode: ${MODE}"
  echo "Master Node: ${MASTER_NODE} (${MASTER_IP})"
  
  # Check master status (REMOTE CHECK in remote mode, LOCAL in cluster mode)
  if [[ "$MODE" == "remote" ]] || [[ "$hostname" == "$MASTER_NODE" ]]; then
    local master_status=""
    
    if [[ "$MODE" == "remote" ]]; then
      master_status=$(SSHExec "${MASTER_IP}" "
        if pgrep -f 'llama-cli.*--rpc' >/dev/null 2>&1; then
          echo 'llama-cli'
        elif pgrep -f 'llama-server.*--rpc' >/dev/null 2>&1; then
          echo 'llama-server'
        else
          echo 'none'
        fi
      ")
    else
      if pgrep -f "llama-cli.*--rpc" >/dev/null 2>&1; then
        master_status="llama-cli"
      elif pgrep -f "llama-server.*--rpc" >/dev/null 2>&1; then
        master_status="llama-server"
      else
        master_status="none"
      fi
    fi
    
    case "$master_status" in
      llama-cli)
        echo "  Status: ✓ llama-cli running (interactive)"
        ;;
      llama-server)
        echo "  Status: ✓ llama-server running (API mode)"
        ;;
      *)
        echo "  Status: ✗ No master process running"
        ;;
    esac
  else
    echo "  (Running from: ${hostname})"
  fi
  
  echo ""
  echo "Worker Nodes:"
  
  # Check workers (always REMOTE via SSH)
  local all_nodes=("$MASTER_NODE" "${WORKER_NODES[@]}")
  local all_ips=("$MASTER_IP" "${WORKER_IPS[@]}")
  
  for i in "${!all_nodes[@]}"; do
    node_name="${all_nodes[$i]}"
    node_ip="${all_ips[$i]}"
    
    # Skip master in cluster mode
    if [[ "$MODE" == "cluster" ]] && [[ "$node_name" == "$MASTER_NODE" ]]; then
      continue
    fi
    
    if SSHExec "$node_ip" "pgrep -f rpc-server" >/dev/null 2>&1; then
      worker_status="✓ Running"
    else
      worker_status="✗ Stopped"
    fi
    
    printf "  %-12s (%s) - %s\n" "$node_name" "$node_ip" "$worker_status"
  done
  
  echo ""
  echo "RPC Configuration:"
  echo "  Port: ${LLAMA_RPC_PORT}"
  echo "  Threads per worker: 64"
  
  if [[ "$MODE" == "remote" ]]; then
    echo "  Active workers: 4 nodes"
  else
    echo "  Active workers: 3 nodes"
  fi
  
  echo ""
  echo "Available Models:"
  
  for profile in "${!LLAMA_MODELS[@]}"; do
    echo "  - $profile"
  done
  
  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo ""
}

# CoreExec - Main execution function
# RUNS: Locally (orchestrates everything)
CoreExec() {
  local command="${1:-}"
  
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
      cat <<'USAGE'
Usage: llamacpp_rpc_orchestrator.sh [--mode cluster|remote] <command> [options]

Modes:
  --mode cluster (default)  Run from cluster node (node1=master, nodes2-4=workers)
  --mode remote             Run from remote machine (all 4 nodes as workers)

Commands:
  start-workers              Start RPC servers on worker nodes
  start-master <profile>     Start master inference (interactive CLI)
  start-server <profile>     Start master as OpenAI API server
  stop                       Stop all RPC servers and master
  stop-workers               Stop only worker RPC servers
  stop-master                Stop only master process
  status                     Show cluster status

Examples:
  # From your Mac (remote mode):
  ./llamacpp_rpc_orchestrator.sh --mode remote start-workers
  ./llamacpp_rpc_orchestrator.sh --mode remote start-server deepseek-v3

  # From cluster (cluster mode):
  ./llamacpp_rpc_orchestrator.sh start-workers
  ./llamacpp_rpc_orchestrator.sh start-master deepseek-v3

  # Stop everything:
  ./llamacpp_rpc_orchestrator.sh --mode remote stop
USAGE
      exit 0
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
