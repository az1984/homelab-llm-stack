#!/usr/bin/env bash
set -euo pipefail

source cluster_config.sh

Log() { echo "[orchestrator] $*"; }

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
  local node_name=$(get_node_info $node_num name)
  local node_ip=$(get_node_info $node_num lan_ip)
  local fabric_ip=$(get_node_info $node_num fabric_ip)

  Log "Ensuring container on node ${node_num} (${node_name} @ ${node_ip})"

  # Remove old container if exists
  ssh admin@${node_ip} "sudo docker rm -f vllm-node-${node_num} 2>/dev/null || true"

  # Pull image
  ssh admin@${node_ip} "sudo docker pull ${VLLM_IMAGE}"

  # First copy the script to the node
  scp vllm_cluster_mgr.sh admin@${node_ip}:/tmp/vllm_cluster_mgr.sh

  # Start container with bash entrypoint
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

start_ray() {
  local node_num=$1
  local node_name=$(get_node_info $node_num name)
  local node_ip=$(get_node_info $node_num lan_ip)
  local fabric_ip=$(get_node_info $node_num fabric_ip)
  local head_fabric_ip=$(get_node_info 1 fabric_ip)

  Log "Starting Ray on node ${node_num} (${node_name})"
  ssh admin@${node_ip} "sudo docker exec \
    -e THIS_NODE=${node_num} \
    -e RAY_NODE_IP=${fabric_ip} \
    -e RAY_HEAD_IP=${head_fabric_ip} \
    vllm-node-${node_num} /opt/vllm_cluster.sh start-ray"
}

cmd_start_cluster() {
  local num_nodes=${1:-2}
  
  Log "=== Starting ${num_nodes}-node cluster ==="

  for i in $(seq 1 ${num_nodes}); do
    ensure_container ${i}
  done

  # Note: Ray will start with default settings. 
  # RAY_OBJECT_STORE_GB will be set when loading a model.
  Log "Containers ready. Use load-model to start cluster with model-specific Ray settings."
}

cmd_load_model() {
  local profile=$1
  local node_ip=$(get_node_info 1 lan_ip)
  local head_fabric_ip=$(get_node_info 1 fabric_ip)
  
  Log "Loading model profile: ${profile}"
  
  # Parse model config
  local model_config="${MODELS[$profile]}"
  [[ -n "${model_config}" ]] || { Log "ERROR: Unknown profile '${profile}'"; exit 1; }
  
  # Extract RAY_OBJECT_STORE_GB and tensor_parallel_size
  local ray_store_gb=$(echo "$model_config" | grep RAY_OBJECT_STORE_GB | cut -d'=' -f2 | xargs)
  local tp_size=$(echo "$model_config" | grep TENSOR_PARALLEL_SIZE | cut -d'=' -f2 | xargs)
  
  # Start Ray cluster with model-specific settings
  Log "Starting Ray cluster (${tp_size} nodes, ${ray_store_gb}GB object store per node)"
  export RAY_OBJECT_STORE_GB="${ray_store_gb}"
  
  for i in $(seq 1 ${tp_size}); do
    local node_name=$(get_node_info $i name)
    local node_ip_i=$(get_node_info $i lan_ip)
    local fabric_ip=$(get_node_info $i fabric_ip)
    
    Log "Starting Ray on node ${i} (${node_name})"
    ssh admin@${node_ip_i} "sudo docker exec \
      -e THIS_NODE=${i} \
      -e RAY_NODE_IP=${fabric_ip} \
      -e RAY_HEAD_IP=${head_fabric_ip} \
      -e RAY_OBJECT_STORE_GB=${ray_store_gb} \
      vllm-node-${i} /opt/vllm_cluster.sh start-ray"
  done
  
  Log "Waiting for Ray to stabilize (5s)"
  sleep 5
  
  # Export all model vars for docker exec
  local env_args="-e RAY_HEAD_IP=${head_fabric_ip}"
  while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    [[ -n "$key" && -n "$value" ]] && env_args="${env_args} -e ${key}=${value}"
  done <<< "${model_config}"
  
  Log "Loading model..."
  ssh admin@${node_ip} "sudo docker exec ${env_args} vllm-node-1 /opt/vllm_cluster.sh load-model"
}

cmd_stop_model() {
  local node_ip=$(get_node_info 1 lan_ip)
  Log "Stopping model on all nodes"
  ssh admin@${node_ip} "sudo docker exec vllm-node-1 /opt/vllm_cluster.sh stop-model"
}

cmd_status() {
  local node_ip=$(get_node_info 1 lan_ip)
  ssh admin@${node_ip} "sudo docker exec vllm-node-1 /opt/vllm_cluster.sh status" || true
}

cmd_stop_cluster() {
  Log "Stopping all containers"
  for i in 1 2 3 4; do
    local ip=$(get_node_info $i lan_ip)
    ssh admin@${ip} "sudo docker rm -f vllm-node-${i} 2>/dev/null || true" &
  done
  wait
}

case "${1:-}" in
  start-cluster) cmd_start_cluster ${2:-2} ;;
  load-model) cmd_load_model ${2} ;;
  stop-model) cmd_stop_model ;;
  status) cmd_status ;;
  stop-cluster) cmd_stop_cluster ;;
  *) echo "Usage: $0 {start-cluster N|load-model PROFILE|stop-model|status|stop-cluster}"; exit 1 ;;
esac
