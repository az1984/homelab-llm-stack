#!/usr/bin/env bash
set -euo pipefail

source cluster_config.sh

Log() { echo "[orchestrator] $*"; }

# Parse --nodes filter if provided
ACTIVE_NODES=()
parse_node_filter() {
  local filter="$1"
  IFS=',' read -ra ACTIVE_NODES <<< "$filter"
  Log "Node filter: ${ACTIVE_NODES[*]}"
}

is_node_active() {
  local node=$1
  # If no filter set, all nodes active
  [[ ${#ACTIVE_NODES[@]} -eq 0 ]] && return 0
  # Check if node in filter
  for n in "${ACTIVE_NODES[@]}"; do
    [[ "$n" == "$node" ]] && return 0
  done
  return 1
}

get_node_info() {
  local node_num=$1
  local field=$2
  local info="${NODES[$node_num]}"
  case $field in
    lan_ip) echo "$info" | cut -d: -f1 ;;
    name) echo "$info" | cut -d: -f2 ;;
    fabric_ip) echo "$info" | cut -d: -f3 ;;
  esac
}

ensure_container() {
  local node_num=$1
  
  # Skip if not in active nodes
  is_node_active $node_num || { Log "Skipping node $node_num (filtered)"; return 0; }
  
  local node_name=$(get_node_info $node_num name)
  local node_ip=$(get_node_info $node_num lan_ip)
  local fabric_ip=$(get_node_info $node_num fabric_ip)

  Log "Ensuring container on node ${node_num} (${node_name} @ ${node_ip})"

  # Remove old container if exists
  ssh admin@${node_ip} "sudo docker rm -f vllm-node-${node_num} 2>/dev/null || true"

  # Pull image
  ssh admin@${node_ip} "sudo docker pull ${VLLM_IMAGE}"

  # Copy the manager script to the node
  scp vllm_cluster_mgr.sh admin@${node_ip}:/tmp/vllm_cluster_mgr.sh

  # Start container
  ssh admin@${node_ip} "sudo docker run -d \
    --name vllm-node-${node_num} \
    --gpus all \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    --network host \
    --shm-size=10g \
    -e THIS_NODE=${node_num} \
    -e RAY_NODE_IP=${fabric_ip} \
    -e NCCL_SOCKET_IFNAME=enp1s0f0np0 \
    -e NCCL_IB_DISABLE=0 \
    -e NCCL_IB_HCA=rocep1s0f0 \
    -e NCCL_DEBUG=INFO \
    -v /opt/ai-models:/opt/ai-models:ro \
    -v /opt/ai-tools/logs:/opt/ai-tools/logs \
    -v /opt/ai-tools/run:/opt/ai-tools/run \
    -v /tmp/vllm_cluster_mgr.sh:/opt/vllm_cluster.sh:ro \
    --entrypoint /bin/bash \
    ${VLLM_IMAGE} \
    -c 'sleep infinity'"

  Log "  Container started"
}

cmd_start_cluster() {
  local num_nodes=${1:-2}
  
  Log "=== Starting ${num_nodes}-node cluster ==="
  
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    Log "Active nodes: ${ACTIVE_NODES[*]}"
  else
    Log "All nodes 1-${num_nodes} will be used"
  fi

  for i in $(seq 1 ${num_nodes}); do
    ensure_container ${i}
  done

  Log "Containers ready. Use load-model to start cluster with model-specific Ray settings."
}

cmd_load_model() {
  local profile=$1
  
  # Determine head node (first active node)
  local head_node=1
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    head_node="${ACTIVE_NODES[0]}"
    Log "Using node $head_node as Ray head (first active node)"
  fi
  
  local node_ip=$(get_node_info $head_node lan_ip)
  local head_fabric_ip=$(get_node_info $head_node fabric_ip)
  
  Log "Loading model profile: ${profile}"
  
  # Parse model config
  local model_config="${MODELS[$profile]}"
  [[ -n "${model_config}" ]] || { Log "ERROR: Unknown profile '${profile}'"; exit 1; }
  
  # Extract settings
  local ray_store_gb=$(echo "$model_config" | grep RAY_OBJECT_STORE_GB | cut -d'=' -f2 | xargs)
  local tp_size=$(echo "$model_config" | grep TENSOR_PARALLEL_SIZE | cut -d'=' -f2 | xargs)
  
  # Validate we have enough active nodes
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    if [[ ${#ACTIVE_NODES[@]} -lt $tp_size ]]; then
      Log "ERROR: Model requires ${tp_size} nodes, but only ${#ACTIVE_NODES[@]} active: ${ACTIVE_NODES[*]}"
      exit 1
    fi
  fi
  
  # Determine which nodes to use
  local nodes_to_use=()
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    nodes_to_use=("${ACTIVE_NODES[@]:0:$tp_size}")
  else
    for i in $(seq 1 ${tp_size}); do
      nodes_to_use+=($i)
    done
  fi
  
  Log "Starting Ray cluster (${tp_size} nodes, ${ray_store_gb}GB object store per node)"
  Log "Using nodes: ${nodes_to_use[*]}"
  
  export RAY_OBJECT_STORE_GB="${ray_store_gb}"
  
  # Start Ray on selected nodes
  for node_num in "${nodes_to_use[@]}"; do
    local node_name=$(get_node_info $node_num name)
    local node_ip_i=$(get_node_info $node_num lan_ip)
    local fabric_ip=$(get_node_info $node_num fabric_ip)
    
    Log "Starting Ray on node ${node_num} (${node_name})"
    ssh admin@${node_ip_i} "sudo docker exec \
      -e THIS_NODE=${node_num} \
      -e RAY_NODE_IP=${fabric_ip} \
      -e RAY_HEAD_IP=${head_fabric_ip} \
      -e RAY_OBJECT_STORE_GB=${ray_store_gb} \
      vllm-node-${node_num} /opt/vllm_cluster.sh start-ray"
  done
  
  Log "Waiting for Ray to stabilize (5s)"
  sleep 5
  
  # Build env args for vLLM
  local env_args="-e RAY_HEAD_IP=${head_fabric_ip}"
  while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    [[ -n "$key" && -n "$value" ]] && env_args="${env_args} -e ${key}=${value}"
  done <<< "${model_config}"
  
  Log "Loading model on head node ${head_node}..."
  ssh admin@${node_ip} "sudo docker exec ${env_args} vllm-node-${head_node} /opt/vllm_cluster.sh load-model"
}

cmd_stop_model() {
  local head_node=1
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    head_node="${ACTIVE_NODES[0]}"
  fi
  
  local node_ip=$(get_node_info $head_node lan_ip)
  Log "Stopping model on head node ${head_node}"
  ssh admin@${node_ip} "sudo docker exec vllm-node-${head_node} /opt/vllm_cluster.sh stop-model"
}

cmd_status() {
  local head_node=1
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    head_node="${ACTIVE_NODES[0]}"
  fi
  
  local node_ip=$(get_node_info $head_node lan_ip)
  Log "Status from head node ${head_node}:"
  ssh admin@${node_ip} "sudo docker exec vllm-node-${head_node} /opt/vllm_cluster.sh status" || true
}

cmd_stop_cluster() {
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    Log "Stopping nodes: ${ACTIVE_NODES[*]}"
    for node in "${ACTIVE_NODES[@]}"; do
      local ip=$(get_node_info $node lan_ip)
      ssh admin@${ip} "sudo docker rm -f vllm-node-${node} 2>/dev/null || true" &
    done
  else
    Log "Stopping all nodes"
    for i in 1 2 3 4; do
      local ip=$(get_node_info $i lan_ip)
      ssh admin@${ip} "sudo docker rm -f vllm-node-${i} 2>/dev/null || true" &
    done
  fi
  wait
}

# Parse arguments
COMMAND=""
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes)
      parse_node_filter "$2"
      shift 2
      ;;
    start-cluster|load-model|stop-model|status|stop-cluster)
      COMMAND="$1"
      shift
      ARGS=("$@")
      break
      ;;
    *)
      echo "Unknown argument: $1"
      exit 1
      ;;
  esac
done

if [[ -z "$COMMAND" ]]; then
  cat <<'USAGE'
Usage: ./vllm_cluster_orchestrator.sh [--nodes N,M,...] <command> [args]

Commands:
  start-cluster N    - Start N-node cluster (default: 2)
  load-model PROFILE - Load model from cluster_config.sh
  stop-model         - Stop vLLM (keep Ray + containers)
  status             - Show cluster status
  stop-cluster       - Stop all containers

Node Filtering:
  --nodes 1,2        - Only use nodes 1 and 2
  --nodes 3,4        - Only use nodes 3 and 4
  --nodes 1,3,4      - Only use nodes 1, 3, and 4

Examples:
  # Two instances of Qwen3-VL-235B on different node pairs
  ./vllm_cluster_orchestrator.sh --nodes 1,2 start-cluster 2
  ./vllm_cluster_orchestrator.sh --nodes 1,2 load-model qwen3-vl-235b
  
  ./vllm_cluster_orchestrator.sh --nodes 3,4 start-cluster 2
  ./vllm_cluster_orchestrator.sh --nodes 3,4 load-model qwen3-vl-235b
  # Now you have two separate Qwen3-VL-235B instances!

  # Full 4-node cluster for DeepSeek-V3
  ./vllm_cluster_orchestrator.sh start-cluster 4
  ./vllm_cluster_orchestrator.sh load-model deepseek-v3

  # Qwen3.5-122B on nodes 3-4 only
  ./vllm_cluster_orchestrator.sh --nodes 3,4 start-cluster 2
  ./vllm_cluster_orchestrator.sh --nodes 3,4 load-model qwen3.5-122b

  # Stop specific subset
  ./vllm_cluster_orchestrator.sh --nodes 1,2 stop-cluster
USAGE
  exit 1
fi

case "$COMMAND" in
  start-cluster) cmd_start_cluster "${ARGS[0]:-2}" ;;
  load-model) cmd_load_model "${ARGS[0]}" ;;
  stop-model) cmd_stop_model ;;
  status) cmd_status ;;
  stop-cluster) cmd_stop_cluster ;;
esac
