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
  local image_name=${2:-$DEFAULT_VLLM_IMAGE}
  local head_fabric_ip=${3:-}
  local profile=${4:-unknown}
  
  # Skip if not in active nodes
  is_node_active $node_num || { Log "Skipping node $node_num (filtered)"; return 0; }
  
  # Resolve image name to full path
  local image_path="${CUSTOM_IMAGES[$image_name]:-$image_name}"
  
  local node_name=$(get_node_info $node_num name)
  local node_ip=$(get_node_info $node_num lan_ip)
  local fabric_ip=$(get_node_info $node_num fabric_ip)

  # Extract served model name and build profile env args for baking into container
  local served_name="unknown"
  local profile_env_args=""
  if [[ "$profile" != "unknown" ]]; then
    local model_config="${MODELS[$profile]:-}"
    if [[ -n "${model_config}" ]]; then
      served_name=$(echo "$model_config" | grep "SERVED_MODEL_NAME=" | cut -d'=' -f2 | xargs)
      # Bake all profile env vars into the container
      while IFS='=' read -r key value; do
        key=$(echo "$key" | xargs)
        value=$(echo "$value" | xargs)
        [[ -n "$key" && -n "$value" ]] && profile_env_args="${profile_env_args} -e ${key}=${value}"
      done <<< "${model_config}"
    fi
  fi

  Log "Ensuring container on node ${node_num} (${node_name} @ ${node_ip})"
  Log "  Using image: ${image_name} → ${image_path}"
  Log "  Profile: ${profile} (${served_name})"
  [[ -n "$head_fabric_ip" ]] && Log "  Ray head: ${head_fabric_ip}"

  # Remove old container if exists
  ssh admin@${node_ip} "sudo docker rm -f vllm-node-${node_num} 2>/dev/null || true"

  # Pull image
  ssh admin@${node_ip} "sudo docker pull ${image_path}"

  # Copy the manager script to the node
  scp vllm_cluster_mgr.sh admin@${node_ip}:/tmp/vllm_cluster_mgr.sh

  # Build container command with optional RAY_HEAD_IP
  local env_ray_head=""
  [[ -n "$head_fabric_ip" ]] && env_ray_head="-e RAY_HEAD_IP=${head_fabric_ip}"

  # Determine entrypoint: NGC images need their setup script, others use /bin/bash
  local entrypoint="${IMAGE_ENTRYPOINTS[$image_name]:-}"
  local entrypoint_args
  if [[ -n "$entrypoint" ]]; then
    entrypoint_args="--entrypoint ${entrypoint}"
    local run_cmd="bash -c 'sleep infinity'"
  else
    entrypoint_args="--entrypoint /bin/bash"
    local run_cmd="-c 'sleep infinity'"
  fi

  Log "  Entrypoint: ${entrypoint:-/bin/bash (default)}"

  # Start container
  ssh admin@${node_ip} "sudo docker run -d \
    --name vllm-node-${node_num} \
    --label vllm.profile=${profile} \
    --label vllm.served_name=${served_name} \
    --gpus all \
    --device /dev/infiniband \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    --network host \
    --shm-size=10g \
    -e THIS_NODE=${node_num} \
    -e RAY_NODE_IP=${fabric_ip} \
    ${env_ray_head} \
    -e RAY_memory_usage_threshold=0.98 \
    -e NCCL_SOCKET_IFNAME=enp1s0f0np0 \
    -e NCCL_IB_DISABLE=0 \
    -e NCCL_IB_HCA=rocep1s0f0 \
    -e NCCL_DEBUG=INFO \
    ${profile_env_args} \
    -v /opt/ai-models:/opt/ai-models:ro \
    -v /opt/ai-tools/logs:/opt/ai-tools/logs \
    -v /opt/ai-tools/run:/opt/ai-tools/run \
    -v /opt/ai-tools/cache/triton:/root/.triton/cache \
    -v /tmp/vllm_cluster_mgr.sh:/opt/vllm_cluster.sh:ro \
    ${entrypoint_args} \
    ${image_path} \
    ${run_cmd}"

  Log "  Container started"
}

cmd_start_cluster() {
  local num_nodes=${1:-2}
  local profile=${2:-}
  
  Log "=== Starting ${num_nodes}-node cluster ==="
  
  # Determine head node (first active node or node 1)
  local head_node=1
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    head_node="${ACTIVE_NODES[0]}"
    Log "Active nodes: ${ACTIVE_NODES[*]}"
    Log "Head node: ${head_node}"
  else
    Log "All nodes 1-${num_nodes} will be used"
    Log "Head node: 1"
  fi
  
  local head_fabric_ip=$(get_node_info $head_node fabric_ip)
  
  # Determine which image to use
  local image_name=$DEFAULT_VLLM_IMAGE
  if [[ -n "$profile" ]]; then
    local model_config="${MODELS[$profile]:-}"
    if [[ -n "${model_config}" ]]; then
      local docker_image=$(echo "$model_config" | grep "DOCKER_IMAGE=" | cut -d'=' -f2 | xargs)
      [[ -n "$docker_image" ]] && image_name="$docker_image"
      Log "Using image from profile '${profile}': ${image_name}"
    fi
  fi

  # Use active nodes if filtered, otherwise sequential
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    for node_num in "${ACTIVE_NODES[@]}"; do
      ensure_container ${node_num} "${image_name}" "${head_fabric_ip}" "${profile}"
    done
  else
    for i in $(seq 1 ${num_nodes}); do
      ensure_container ${i} "${image_name}" "${head_fabric_ip}" "${profile}"
    done
  fi

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
  local model_config="${MODELS[$profile]:-}"
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
  
  # Start Ray on selected nodes (in parallel)
  for node_num in "${nodes_to_use[@]}"; do
    local node_name=$(get_node_info $node_num name)
    local node_ip_i=$(get_node_info $node_num lan_ip)
    local fabric_ip=$(get_node_info $node_num fabric_ip)
    
    Log "Starting Ray on node ${node_num} (${node_name})"
    (
      ssh admin@${node_ip_i} "sudo docker exec \
        -e THIS_NODE=${node_num} \
        -e RAY_NODE_IP=${fabric_ip} \
        -e RAY_HEAD_IP=${head_fabric_ip} \
        -e RAY_OBJECT_STORE_GB=${ray_store_gb} \
        vllm-node-${node_num} /opt/vllm_cluster.sh start-ray"
    ) &
  done
  
  # Wait for all Ray processes to finish starting
  wait
  
  Log "Waiting for Ray to stabilize (5s)"
  sleep 5
  
  # Build env args for vLLM (profile vars already baked into container,
  # but pass them again on exec for any that might be overridden)
  local env_args="-e RAY_HEAD_IP=${head_fabric_ip}"
  while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    [[ -n "$key" && -n "$value" ]] && env_args="${env_args} -e ${key}=${value}"
  done <<< "${model_config}"
  
  Log "Loading model on head node ${head_node}..."
  ssh admin@${node_ip} "sudo docker exec ${env_args} vllm-node-${head_node} /opt/vllm_cluster.sh load-model"
  
  # Post-launch verification: poll for signs of life
  local vllm_port=$(echo "$model_config" | grep VLLM_PORT | cut -d'=' -f2 | xargs)
  vllm_port="${vllm_port:-8000}"
  local served_name=$(echo "$model_config" | grep SERVED_MODEL_NAME | cut -d'=' -f2 | xargs)
  
  Log "Waiting for vLLM to initialize..."
  local max_wait=300  # 5 minutes max
  local elapsed=0
  local stage="starting"
  
  while [[ $elapsed -lt $max_wait ]]; do
    sleep 10
    elapsed=$((elapsed + 10))
    
    # Check if process is still alive
    local proc_check
    proc_check=$(ssh admin@${node_ip} "sudo docker exec vllm-node-${head_node} cat /opt/ai-tools/run/vllm-cluster/vllm_api.pid 2>/dev/null" || true)
    if [[ -z "$proc_check" ]]; then
      Log "  [${elapsed}s] WARNING: No PID file found — load-model may have failed"
      Log "  Check: ssh admin@${node_ip} 'tail -30 /opt/ai-tools/logs/vllm-cluster/vllm_*_latest.log'"
      return 1
    fi
    
    # Check for fatal errors in log
    local errors
    errors=$(ssh admin@${node_ip} "sudo docker exec vllm-node-${head_node} grep -c 'EngineCore failed\|RuntimeError\|FATAL' /opt/ai-tools/logs/vllm-cluster/vllm_*_latest.log 2>/dev/null" || echo "0")
    if [[ "$errors" -gt 0 ]]; then
      Log "  [${elapsed}s] FAILED: Errors detected in log"
      Log "  Check: ssh admin@${node_ip} 'grep -A5 \"Error\\|RuntimeError\" /opt/ai-tools/logs/vllm-cluster/vllm_*_latest.log | tail -20'"
      return 1
    fi
    
    # Try health endpoint
    local health
    health=$(curl -sf --connect-timeout 2 --max-time 5 "http://${node_ip}:${vllm_port}/health" 2>/dev/null || true)
    if [[ -n "$health" ]]; then
      Log "  [${elapsed}s] READY — vLLM responding on port ${vllm_port}"
      
      # Show model name
      local models
      models=$(curl -sf "http://${node_ip}:${vllm_port}/v1/models" 2>/dev/null | python3 -c "import sys,json; [print(m['id']) for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true)
      if [[ -n "$models" ]]; then
        Log "  Serving: ${models}"
      fi
      return 0
    fi
    
    # Detect stage from log
    local log_tail
    log_tail=$(ssh admin@${node_ip} "sudo docker exec vllm-node-${head_node} tail -3 /opt/ai-tools/logs/vllm-cluster/vllm_*_latest.log 2>/dev/null" || true)
    
    if echo "$log_tail" | grep -q "Loading safetensors"; then
      stage="loading weights"
    elif echo "$log_tail" | grep -q "torch.compile\|compile"; then
      stage="compiling"
    elif echo "$log_tail" | grep -q "CUDA graph\|Graph capturing"; then
      stage="capturing CUDA graphs"
    elif echo "$log_tail" | grep -q "Starting vLLM\|Application startup"; then
      stage="starting API server"
    fi
    
    Log "  [${elapsed}s] ${stage}..."
  done
  
  Log "  [${elapsed}s] TIMEOUT — vLLM did not become ready in ${max_wait}s"
  Log "  Check: ssh admin@${node_ip} 'tail -50 /opt/ai-tools/logs/vllm-cluster/vllm_*_latest.log'"
  return 1
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
  Log "=== Cluster Container Status ==="
  for node_num in 1 2 3 4; do
    is_node_active $node_num || continue
    local node_ip=$(get_node_info $node_num lan_ip)
    local node_name=$(get_node_info $node_num name)
    local status
    status=$(ssh admin@${node_ip} "sudo docker ps --filter name=vllm-node-${node_num} --format '{{.Label \"vllm.profile\"}} ({{.Label \"vllm.served_name\"}}) {{.Image}} {{.Status}}'" 2>/dev/null)
    if [[ -n "$status" ]]; then
      Log "  Node ${node_num} (${node_name}): ${status}"
    else
      Log "  Node ${node_num} (${node_name}): no container"
    fi
  done

  # Also show Ray/vLLM internal status from head node
  local head_node=1
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    head_node="${ACTIVE_NODES[0]}"
  fi
  local head_ip=$(get_node_info $head_node lan_ip)
  Log "=== Ray Status (from node ${head_node}) ==="
  ssh admin@${head_ip} "sudo docker exec vllm-node-${head_node} /opt/vllm_cluster.sh status" 2>/dev/null || Log "  (no running container on head node)"
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

# Known vLLM API ports to probe
VLLM_PROBE_PORTS=(8000 8001 8002)

cmd_details() {
  Log "=== Cluster Details (probing API endpoints) ==="
  for node_num in 1 2 3 4; do
    is_node_active $node_num || continue
    local node_ip=$(get_node_info $node_num lan_ip)
    local node_name=$(get_node_info $node_num name)

    # Check container labels first
    local container_info
    container_info=$(ssh admin@${node_ip} "sudo docker ps --filter name=vllm-node-${node_num} --format '{{.Label \"vllm.profile\"}}'" 2>/dev/null)
    if [[ -z "$container_info" ]]; then
      Log "  Node ${node_num} (${node_name}): no container"
      continue
    fi

    Log "  Node ${node_num} (${node_name}) [profile: ${container_info}]:"

    local found_any=0
    for port in "${VLLM_PROBE_PORTS[@]}"; do
      local response
      response=$(curl -s --connect-timeout 2 --max-time 5 "http://${node_ip}:${port}/v1/models" 2>/dev/null)
      if [[ -n "$response" ]] && echo "$response" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
        local model_ids
        model_ids=$(echo "$response" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('data', []):
    print(m.get('id', '?'))
" 2>/dev/null)
        if [[ -n "$model_ids" ]]; then
          found_any=1
          while IFS= read -r model_id; do
            Log "    :${port} → ${model_id}"
          done <<< "$model_ids"
        fi
      fi
    done

    if [[ $found_any -eq 0 ]]; then
      Log "    (container running, no API responding on ports ${VLLM_PROBE_PORTS[*]})"
    fi
  done
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
    start-cluster|load-model|stop-model|status|details|stop-cluster)
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
  start-cluster N [PROFILE]  - Start N-node cluster (optionally pre-configure for PROFILE)
  load-model PROFILE         - Load model from cluster_config.sh
  stop-model                 - Stop vLLM (keep Ray + containers)
  status                     - Show cluster container status + Ray info
  details                    - Probe API endpoints, show served model names per node/port
  stop-cluster               - Stop all containers

Node Filtering:
  --nodes 1,2        - Only use nodes 1 and 2
  --nodes 3          - Single node deployment

Profiles:
  qwen3.5-122b-v2   - PRODUCTION: Albond hybrid + MTP-2, TP=1, 29-44 tok/s
                       Deploy as independent pair behind HAProxy:
                         --nodes 1 start-cluster 1 qwen3.5-122b-v2
                         --nodes 2 start-cluster 1 qwen3.5-122b-v2
  qwen3.5-122b      - Fallback: eugr image, TP=2, cyankiwi model, 22 tok/s
  qwen3.5-397b      - Heavy mode: TP=4, all nodes, ~37 tok/s (needs vllm-sm121-397b)
  qwen3.5-9b        - Vision: TP=1, port 8002, cohabits with other services

Examples:
  # Production 122B: two independent TP=1 nodes behind HAProxy
  ./vllm_cluster_orchestrator.sh --nodes 1 start-cluster 1 qwen3.5-122b-v2
  ./vllm_cluster_orchestrator.sh --nodes 1 load-model qwen3.5-122b-v2
  ./vllm_cluster_orchestrator.sh --nodes 2 start-cluster 1 qwen3.5-122b-v2
  ./vllm_cluster_orchestrator.sh --nodes 2 load-model qwen3.5-122b-v2

  # 397B heavy mode (all nodes)
  ./vllm_cluster_orchestrator.sh --nodes 1,2,3,4 start-cluster 4 qwen3.5-397b
  ./vllm_cluster_orchestrator.sh --nodes 1,2,3,4 load-model qwen3.5-397b

  # Fallback 122B on TP=2
  ./vllm_cluster_orchestrator.sh --nodes 1,2 start-cluster 2 qwen3.5-122b
  ./vllm_cluster_orchestrator.sh --nodes 1,2 load-model qwen3.5-122b
USAGE
  exit 1
fi

case "$COMMAND" in
  start-cluster) cmd_start_cluster "${ARGS[0]:-2}" "${ARGS[1]:-}" ;;
  load-model) cmd_load_model "${ARGS[0]}" ;;
  stop-model) cmd_stop_model ;;
  status) cmd_status ;;
  details) cmd_details ;;
  stop-cluster) cmd_stop_cluster ;;
esac
