#!/usr/bin/env bash
# vllm_cluster_orchestrator.sh
#
# Outer shell: fans out SSH commands to cluster nodes to manage vLLM containers.
# Reads profile definitions from cluster_config.sh.
# Reads aliases + sequences from cluster_favorites.sh.
# Reads API keys from cluster.env (local only — never deployed to nodes).
#
# Usage:
#   ./vllm_cluster_orchestrator.sh [--nodes N,M,...] <command> [args]
#   ./vllm_cluster_orchestrator.sh fav <alias-or-sequence>
#   ./vllm_cluster_orchestrator.sh fav list
#
# Commands:
#   start-cluster [PROFILE]    Start containers; infer node count from profile TP
#   start-cluster N [PROFILE]  Start N containers (explicit node count)
#   load-model PROFILE         Start Ray + load model into running containers
#   unload-model               Unload model (keep Ray + containers running)
#   stop-cluster [PROFILE]     Stop containers: all on selected nodes (no PROFILE)
#                              or only containers for PROFILE (surgical)
#   status                     Show container status + Ray info across nodes
#   details                    Probe API endpoints, show served model names
#   fav list                   List all registered aliases and sequences
#   fav <name>                 Expand alias or run a multi-step sequence

set -euo pipefail

# ==============================================================================
# Source config, favorites, and environment
# ==============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "${SCRIPT_DIR}/cluster_config.sh"
source "${SCRIPT_DIR}/cluster_favorites.sh"

# Load API keys from cluster.env if present — sourced locally, injected via -e
ENV_FILE="${SCRIPT_DIR}/cluster.env"
ENV_INJECT_ARGS=""
if [[ -f "${ENV_FILE}" ]]; then
  # Parse non-comment, non-empty lines into -e KEY=VALUE args
  while IFS= read -r line; do
    # Skip blank lines and comments
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    # Basic sanity: must look like KEY=VALUE
    [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
    key="${line%%=*}"
    value="${line#*=}"
    # Skip if value is empty
    [[ -z "$value" ]] && continue
    ENV_INJECT_ARGS="${ENV_INJECT_ARGS} -e ${key}=$(printf '%q' "${value}")"
    export "${key}=${value}"
  done < "${ENV_FILE}"
fi

# ==============================================================================
# Logging
# ==============================================================================
Log() { echo "[orchestrator] $*"; }
Die() { echo "[orchestrator] ERROR: $*" >&2; exit 1; }

# ==============================================================================
# Node filter
# ==============================================================================
ACTIVE_NODES=()

parse_node_filter() {
  local filter="$1"
  IFS=',' read -ra ACTIVE_NODES <<< "$filter"
  Log "Node filter: ${ACTIVE_NODES[*]}"
}

is_node_active() {
  local node=$1
  [[ ${#ACTIVE_NODES[@]} -eq 0 ]] && return 0
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
    lan_ip)    echo "$info" | cut -d: -f1 ;;
    name)      echo "$info" | cut -d: -f2 ;;
    fabric_ip) echo "$info" | cut -d: -f3 ;;
  esac
}

# ==============================================================================
# Container naming
# ==============================================================================
# Canonical name: {prefix}--{profile}--n{node_num}
# prefix defaults to "vllm"; overridable per-profile via CONTAINER_PREFIX field.
#
# All docker commands go through container_name_for() — one place to change
# if the scheme ever evolves.

extract_profile_field() {
  local profile="$1"
  local field="$2"
  local default="${3:-}"
  local model_config="${MODELS[$profile]:-}"
  local val
  val=$(echo "$model_config" | grep "^[[:space:]]*${field}=" | cut -d'=' -f2 | xargs)
  echo "${val:-$default}"
}

container_name_for() {
  local profile="$1"
  local node_num="$2"
  local prefix
  prefix=$(extract_profile_field "$profile" "CONTAINER_PREFIX" "vllm")
  echo "${prefix}--${profile}--n${node_num}"
}

# ==============================================================================
# ENV injection helpers
# ==============================================================================

# Build -e KEY=VALUE args from a model profile config block
profile_env_args() {
  local model_config="$1"
  local args=""
  while IFS='=' read -r key value; do
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    [[ -n "$key" && -n "$value" ]] && args="${args} -e ${key}=$(printf '%q' "${value}")"
  done <<< "${model_config}"
  echo "$args"
}

# ==============================================================================
# ensure_container
# ==============================================================================
# Starts one container on one node for a given profile.
# Container is named via container_name_for() — deterministic, profile-keyed.
# Bakes profile env vars in at docker run AND injects cluster.env keys.
# Labels baked in: cluster.profile, cluster.service, cluster.node

ensure_container() {
  local node_num=$1
  local image_name=${2:-$DEFAULT_VLLM_IMAGE}
  local head_fabric_ip=${3:-}
  local profile=${4:-unknown}

  is_node_active $node_num || { Log "Skipping node $node_num (filtered)"; return 0; }

  local image_path="${CUSTOM_IMAGES[$image_name]:-$image_name}"
  local node_name=$(get_node_info $node_num name)
  local node_ip=$(get_node_info $node_num lan_ip)
  local fabric_ip=$(get_node_info $node_num fabric_ip)
  local container_name
  container_name=$(container_name_for "${profile}" "${node_num}")

  # Extract served model name and build profile env args
  local served_name="unknown"
  local p_env_args=""
  if [[ "$profile" != "unknown" ]]; then
    local model_config="${MODELS[$profile]:-}"
    if [[ -n "${model_config}" ]]; then
      served_name=$(echo "$model_config" | grep "SERVED_MODEL_NAME=" | cut -d'=' -f2 | xargs)
      p_env_args=$(profile_env_args "${model_config}")
    fi
  fi

  local service_type
  service_type=$(extract_profile_field "$profile" "SERVICE_TYPE" "vllm")

  Log "Ensuring container on node ${node_num} (${node_name} @ ${node_ip})"
  Log "  Container: ${container_name}"
  Log "  Image:     ${image_name} → ${image_path}"
  Log "  Profile:   ${profile} (${served_name})"
  [[ -n "$head_fabric_ip" ]] && Log "  Ray head:  ${head_fabric_ip}"

  # Remove old container with this exact name (surgical — does not touch other containers)
  ssh admin@${node_ip} "sudo docker rm -f ${container_name} 2>/dev/null || true"

  # Pull image
  ssh admin@${node_ip} "sudo docker pull ${image_path}"

  # Copy manager script
  scp vllm_cluster_mgr.sh admin@${node_ip}:/tmp/vllm_cluster_mgr.sh

  local env_ray_head=""
  [[ -n "$head_fabric_ip" ]] && env_ray_head="-e RAY_HEAD_IP=${head_fabric_ip}"

  local entrypoint="${IMAGE_ENTRYPOINTS[$image_name]:-}"
  local entrypoint_args run_cmd
  if [[ -n "$entrypoint" ]]; then
    entrypoint_args="--entrypoint ${entrypoint}"
    run_cmd="sleep infinity"
  else
    entrypoint_args="--entrypoint /bin/bash"
    run_cmd="-c 'sleep infinity'"
  fi

  Log "  Entrypoint: ${entrypoint:-/bin/bash (default)}"

  ssh admin@${node_ip} "sudo docker run -d \
    --name ${container_name} \
    --label cluster.profile=${profile} \
    --label cluster.service=${service_type} \
    --label cluster.node=${node_num} \
    --label cluster.served_name=${served_name} \
    --gpus all \
    --device /dev/infiniband \
    --ipc=host \
    --ulimit memlock=-1 \
    --ulimit stack=67108864 \
    --ulimit nofile=1048576:1048576 \
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
    ${p_env_args} \
    ${ENV_INJECT_ARGS} \
    -v /opt/ai-models:/opt/ai-models:ro \
    -v /mnt/network/ai-models:/mnt/network/ai-models:ro \
    -v /mnt/network/data/models:/mnt/network/data/models:ro \
    -v /opt/ai-tools/logs:/opt/ai-tools/logs \
    -v /opt/ai-tools/run:/opt/ai-tools/run \
    -v /opt/ai-tools/cache/triton:/root/.triton/cache \
    -v /opt/ai-tools/cache/tilelang:/root/.tilelang/cache \
    -v /opt/ai-tools/cache/nv-compute:/root/.nv/ComputeCache \
    -v /tmp/vllm_cluster_mgr.sh:/opt/vllm_cluster.sh:ro \
    ${entrypoint_args} \
    ${image_path} \
    ${run_cmd}"

  Log "  Container started: ${container_name}"
}

# ==============================================================================
# Profile helpers
# ==============================================================================
get_profile_tp_size() {
  local profile=$1
  extract_profile_field "$profile" "TENSOR_PARALLEL_SIZE" "2"
}

get_profile_image() {
  local profile=$1
  extract_profile_field "$profile" "DOCKER_IMAGE" "$DEFAULT_VLLM_IMAGE"
}

# ==============================================================================
# cmd_start_cluster
# ==============================================================================
cmd_start_cluster() {
  local arg1=${1:-}
  local arg2=${2:-}
  local num_nodes=""
  local profile=""

  if [[ -n "$arg1" ]]; then
    if [[ "$arg1" =~ ^[0-9]+$ ]]; then
      num_nodes="$arg1"
      profile="${arg2:-}"
    else
      profile="$arg1"
      [[ -n "$arg2" ]] && Log "WARNING: extra argument '$arg2' ignored (node count inferred from profile TP size)"
    fi
  fi

  # Resolve favorite alias
  [[ -n "$profile" ]] && profile=$(resolve_favorite "$profile")

  if [[ -n "$profile" ]]; then
    local model_config="${MODELS[$profile]:-}"
    [[ -z "${model_config}" ]] && Die "Unknown profile '${profile}'"
  fi

  if [[ -z "$num_nodes" ]]; then
    if [[ -n "$profile" ]]; then
      num_nodes=$(get_profile_tp_size "$profile")
      Log "Inferred ${num_nodes}-node cluster from profile '${profile}' (TP=${num_nodes})"
    else
      num_nodes=2
      Log "No profile or node count given, defaulting to ${num_nodes} nodes"
    fi
  fi

  Log "=== Starting ${num_nodes}-node cluster ==="
  Log "Ensuring clean state (stop-cluster before start)..."
  cmd_stop_cluster

  local head_node=1
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    head_node="${ACTIVE_NODES[0]}"
    Log "Active nodes: ${ACTIVE_NODES[*]}"
    Log "Head node: ${head_node}"
  else
    Log "All nodes 1-${num_nodes} will be used"
    Log "Head node: 1"
  fi

  local head_fabric_ip
  head_fabric_ip=$(get_node_info $head_node fabric_ip)

  local image_name=$DEFAULT_VLLM_IMAGE
  [[ -n "$profile" ]] && image_name=$(get_profile_image "$profile")
  Log "Image: ${image_name}"

  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    for node_num in "${ACTIVE_NODES[@]}"; do
      ensure_container ${node_num} "${image_name}" "${head_fabric_ip}" "${profile:-unknown}"
    done
  else
    for i in $(seq 1 ${num_nodes}); do
      ensure_container ${i} "${image_name}" "${head_fabric_ip}" "${profile:-unknown}"
    done
  fi

  Log "Containers ready. Use load-model to start cluster with model-specific Ray settings."
}

# ==============================================================================
# cmd_load_model
# ==============================================================================
cmd_load_model() {
  local profile
  profile=$(resolve_favorite "${1:-}")
  [[ -z "$profile" ]] && Die "load-model requires a profile name"

  local head_node=1
  [[ ${#ACTIVE_NODES[@]} -gt 0 ]] && head_node="${ACTIVE_NODES[0]}"
  Log "Using node $head_node as Ray head (first active node)"

  local node_ip
  node_ip=$(get_node_info $head_node lan_ip)
  local head_fabric_ip
  head_fabric_ip=$(get_node_info $head_node fabric_ip)
  local container_name
  container_name=$(container_name_for "${profile}" "${head_node}")

  Log "Loading model profile: ${profile}"

  local model_config="${MODELS[$profile]:-}"
  [[ -n "${model_config}" ]] || Die "Unknown profile '${profile}'"

  local ray_store_gb
  ray_store_gb=$(echo "$model_config" | grep RAY_OBJECT_STORE_GB | cut -d'=' -f2 | xargs)
  local tp_size
  tp_size=$(echo "$model_config" | grep TENSOR_PARALLEL_SIZE | cut -d'=' -f2 | xargs)
  local executor_backend
  executor_backend=$(echo "$model_config" | grep CLUSTER_EXECUTOR_BACKEND | cut -d'=' -f2 | xargs)

  if [[ ${#ACTIVE_NODES[@]} -gt 0 && ${#ACTIVE_NODES[@]} -lt $tp_size ]]; then
    Die "Model requires ${tp_size} nodes, but only ${#ACTIVE_NODES[@]} active: ${ACTIVE_NODES[*]}"
  fi

  local nodes_to_use=()
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    nodes_to_use=("${ACTIVE_NODES[@]:0:$tp_size}")
  else
    for i in $(seq 1 ${tp_size}); do nodes_to_use+=($i); done
  fi

  Log "Using nodes: ${nodes_to_use[*]}"
  Log "Executor backend: ${executor_backend:-ray (default)}"

  if [[ "${tp_size}" -gt 1 && "${executor_backend}" != "mp" ]]; then
    Log "Starting Ray cluster (${tp_size} nodes, ${ray_store_gb}GB object store per node)"
    export RAY_OBJECT_STORE_GB="${ray_store_gb}"

    Log "Dropping page cache on all nodes before model load..."
    for node_num in "${nodes_to_use[@]}"; do
      local node_ip_i=$(get_node_info $node_num lan_ip)
      local node_name=$(get_node_info $node_num name)
      (ssh admin@${node_ip_i} "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null && echo '[${node_name}] page cache dropped'") &
    done
    wait
    Log "Page cache drop complete"

    for node_num in "${nodes_to_use[@]}"; do
      local node_name=$(get_node_info $node_num name)
      local node_ip_i=$(get_node_info $node_num lan_ip)
      local fabric_ip=$(get_node_info $node_num fabric_ip)
      local cname
      cname=$(container_name_for "${profile}" "${node_num}")
      Log "Starting Ray on node ${node_num} (${node_name}) in ${cname}"
      (
        ssh admin@${node_ip_i} "sudo docker exec \
          -e THIS_NODE=${node_num} \
          -e RAY_NODE_IP=${fabric_ip} \
          -e RAY_HEAD_IP=${head_fabric_ip} \
          -e RAY_OBJECT_STORE_GB=${ray_store_gb} \
          ${cname} /opt/vllm_cluster.sh start-ray"
      ) &
    done
    wait

    Log "Waiting for Ray to stabilize..."
    local ray_wait=0 ray_max=30
    while [[ $ray_wait -lt $ray_max ]]; do
      sleep 2; ray_wait=$((ray_wait + 2))
      local ray_ok
      ray_ok=$(ssh admin@${node_ip} \
        "sudo docker exec ${container_name} ray status 2>/dev/null | grep -c 'Active' || true")
      if [[ "${ray_ok:-0}" -gt 0 ]]; then
        Log "  Ray ready after ${ray_wait}s"; break
      fi
      Log "  Waiting for Ray... (${ray_wait}s)"
    done
    [[ $ray_wait -ge $ray_max ]] && Log "  WARNING: Ray status check timed out — proceeding anyway"

  elif [[ "${executor_backend}" == "mp" && "${tp_size}" -gt 1 ]]; then
    Log "mp executor: skipping Ray — launching vLLM on all nodes directly"
    Log "Dropping page cache on all nodes before model load..."
    for node_num in "${nodes_to_use[@]}"; do
      local node_ip_i=$(get_node_info $node_num lan_ip)
      local node_name=$(get_node_info $node_num name)
      (ssh admin@${node_ip_i} "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null && echo '[${node_name}] page cache dropped'") &
    done
    wait
    Log "Page cache drop complete"
  else
    Log "TP=1: skipping Ray — using multiproc executor"
  fi

  # Build env args (profile vars + cluster.env keys)
  local env_args="${ENV_INJECT_ARGS}"
  [[ "${executor_backend}" != "mp" ]] && env_args="${env_args} -e RAY_HEAD_IP=${head_fabric_ip}"
  env_args="${env_args} $(profile_env_args "${model_config}")"

  local served_name
  served_name=$(echo "$model_config" | grep SERVED_MODEL_NAME | cut -d'=' -f2 | xargs)
  local vllm_port
  vllm_port=$(echo "$model_config" | grep -E "VLLM_API_PORT|VLLM_PORT" | head -1 | cut -d'=' -f2 | xargs)
  vllm_port="${vllm_port:-8000}"
  local log_file="/opt/ai-tools/logs/vllm-cluster/vllm_${served_name}_node${head_node}_latest.log"

  ssh admin@${node_ip} "sudo docker exec ${container_name} truncate -s 0 ${log_file} 2>/dev/null || true"

  if [[ "${executor_backend}" == "mp" && "${tp_size}" -gt 1 ]]; then
    local nnodes="${tp_size}"
    Log "Loading model on all nodes (mp, nnodes=${nnodes})..."
    local _mp_rank=0
    for node_num in "${nodes_to_use[@]}"; do
      local node_name=$(get_node_info $node_num name)
      local node_ip_i=$(get_node_info $node_num lan_ip)
      local headless_flag=0
      [[ $_mp_rank -gt 0 ]] && headless_flag=1
      local this_rank=$_mp_rank
      local cname
      cname=$(container_name_for "${profile}" "${node_num}")
      Log "  Node ${node_num} (${node_name}) rank=${this_rank} headless=${headless_flag} → ${cname}"
      (
        ssh admin@${node_ip_i} "sudo docker exec \
          ${env_args} \
          -e VLLM_NNODES=${nnodes} \
          -e VLLM_NODE_RANK=${this_rank} \
          -e VLLM_MASTER_ADDR=${head_fabric_ip} \
          -e VLLM_HEADLESS=${headless_flag} \
          ${cname} /opt/vllm_cluster.sh load-model"
      ) &
      _mp_rank=$((_mp_rank + 1))
    done
  else
    Log "Loading model on head node ${head_node} (${container_name})..."
    ssh admin@${node_ip} "sudo docker exec ${env_args} ${container_name} /opt/vllm_cluster.sh load-model"
  fi

  _wait_for_vllm "${node_ip}" "${container_name}" "${vllm_port}" "${log_file}" "${nodes_to_use[@]}"
}

# ==============================================================================
# _drop_page_cache_on_nodes (internal helper — top-level so bash allows it)
# ==============================================================================
# Args: reason node1 node2 ...
_drop_page_cache_on_nodes() {
  local reason="$1"; shift
  local nodes_to_drop=("$@")
  Log "  Dropping page cache on all nodes (${reason})..."
  for n in "${nodes_to_drop[@]}"; do
    local nip
    nip=$(get_node_info $n lan_ip)
    (ssh admin@${nip} "sync && echo 3 | sudo tee /proc/sys/vm/drop_caches > /dev/null && echo '[node${n}] cache dropped'" 2>/dev/null || true) &
  done
  wait
}

# ==============================================================================
# _wait_for_vllm (internal)
# ==============================================================================
_wait_for_vllm() {
  local node_ip="$1"
  local container_name="$2"
  local vllm_port="$3"
  local log_file="$4"
  shift 4
  local nodes_to_use=("$@")

  Log "Waiting for vLLM to initialize..."
  local max_wait=900 elapsed=0 stage="starting"
  local cache_drop_15_25_done=false cache_drop_35_45_done=false
  local cache_drop_55_65_done=false cache_drop_75_85_done=false cache_drop_90_done=false

  while [[ $elapsed -lt $max_wait ]]; do
    sleep 10; elapsed=$((elapsed + 10))

    local proc_check
    proc_check=$(ssh admin@${node_ip} "sudo docker exec ${container_name} cat /opt/ai-tools/run/vllm-cluster/vllm_api.pid 2>/dev/null" || true)
    if [[ -z "$proc_check" ]]; then
      Log "  [${elapsed}s] WARNING: No PID file — load-model may have failed"
      Log "  Check: ssh admin@${node_ip} 'tail -30 ${log_file}'"
      return 1
    fi

    local errors
    errors=$(ssh admin@${node_ip} "sudo docker exec ${container_name} grep -c 'EngineCore failed to start' ${log_file} 2>/dev/null" || echo "0")
    errors=$(echo "$errors" | tr -d '\n')
    if [[ "$errors" -gt 0 ]]; then
      Log "  [${elapsed}s] FAILED: Errors detected in log"
      Log "  Check: ssh admin@${node_ip} 'grep -A5 \"EngineCore failed\" ${log_file} | tail -20'"
      return 1
    fi

    local health
    health=$(curl -sf --connect-timeout 2 --max-time 5 "http://${node_ip}:${vllm_port}/health" 2>/dev/null || true)
    if [[ -n "$health" ]]; then
      Log "  [${elapsed}s] READY — vLLM responding on port ${vllm_port}"
      local models
      models=$(curl -sf "http://${node_ip}:${vllm_port}/v1/models" 2>/dev/null \
        | python3 -c "import sys,json; [print(m['id']) for m in json.load(sys.stdin).get('data',[])]" 2>/dev/null || true)
      [[ -n "$models" ]] && Log "  Serving: ${models}"
      return 0
    fi

    local log_tail
    log_tail=$(ssh admin@${node_ip} "sudo docker exec ${container_name} tail -3 ${log_file} 2>/dev/null" || true)

    if echo "$log_tail" | grep -q "Loading safetensors"; then
      stage="loading weights"
      local pct
      pct=$(echo "$log_tail" | grep -o '[0-9]\+%' | tail -1 | tr -d '%\n' || echo "0")
      if [[ -n "$pct" && "$pct" =~ ^[0-9]+$ ]]; then
        if   [[ "$pct" -ge 15 && "$pct" -le 25 ]] && [[ "$cache_drop_15_25_done" == false ]]; then
          cache_drop_15_25_done=true; _drop_page_cache_on_nodes "${pct}% loaded" "${nodes_to_use[@]}"
        elif [[ "$pct" -ge 35 && "$pct" -le 45 ]] && [[ "$cache_drop_35_45_done" == false ]]; then
          cache_drop_35_45_done=true; _drop_page_cache_on_nodes "${pct}% loaded" "${nodes_to_use[@]}"
        elif [[ "$pct" -ge 55 && "$pct" -le 65 ]] && [[ "$cache_drop_55_65_done" == false ]]; then
          cache_drop_55_65_done=true; _drop_page_cache_on_nodes "${pct}% loaded" "${nodes_to_use[@]}"
        elif [[ "$pct" -ge 75 && "$pct" -le 85 ]] && [[ "$cache_drop_75_85_done" == false ]]; then
          cache_drop_75_85_done=true; _drop_page_cache_on_nodes "${pct}% loaded" "${nodes_to_use[@]}"
        elif [[ "$pct" -ge 90 ]] && [[ "$cache_drop_90_done" == false ]]; then
          cache_drop_90_done=true; _drop_page_cache_on_nodes "${pct}% loaded" "${nodes_to_use[@]}"
        fi
      fi
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
  Log "  Check: ssh admin@${node_ip} 'tail -50 ${log_file}'"
  return 1
}

# ==============================================================================
# cmd_stop_cluster
# ==============================================================================
# Two modes:
#   No PROFILE → kill ALL managed containers on selected nodes (nuclear, safe default)
#   PROFILE given → kill only containers matching that profile (surgical)
#
# "Managed container" = any container with label cluster.service set.
# This means legacy containers named vllm-node-N (from before this scheme) are
# NOT touched by surgical stop — they have no labels. Use nuclear stop (no profile)
# to clean those up during migration.

cmd_stop_cluster() {
  local profile="${1:-}"
  [[ -n "$profile" ]] && profile=$(resolve_favorite "$profile")

  local nodes_to_stop=()
  if [[ ${#ACTIVE_NODES[@]} -gt 0 ]]; then
    nodes_to_stop=("${ACTIVE_NODES[@]}")
  else
    nodes_to_stop=(1 2 3 4)
  fi

  if [[ -n "$profile" ]]; then
    # ── Surgical: only containers for this profile ──────────────────────────
    Log "=== Surgical stop: profile '${profile}' on nodes ${nodes_to_stop[*]} ==="

    # Phase 1: gracefully stop Ray/vLLM inside each matching container
    Log "Phase 1: stopping Ray/vLLM inside profile containers..."
    for node in "${nodes_to_stop[@]}"; do
      local ip
      ip=$(get_node_info $node lan_ip)
      local cname
      cname=$(container_name_for "${profile}" "${node}")
      (
        ssh admin@${ip} \
          "sudo docker exec ${cname} /opt/vllm_cluster.sh stop-all 2>/dev/null || true" \
          2>/dev/null || true
      ) &
    done
    wait
    Log "  Ray/vLLM stop complete (or containers already gone)"

    # Phase 2: remove matching containers
    Log "Phase 2: removing containers..."
    for node in "${nodes_to_stop[@]}"; do
      local ip
      ip=$(get_node_info $node lan_ip)
      local cname
      cname=$(container_name_for "${profile}" "${node}")
      ssh admin@${ip} "sudo docker rm -f ${cname} 2>/dev/null || true" &
    done
    wait
    Log "Surgical stop complete: ${profile}"

  else
    # ── Nuclear: all managed containers on selected nodes ───────────────────
    Log "=== Nuclear stop: all managed containers on nodes ${nodes_to_stop[*]} ==="

    # Phase 1: gracefully stop Ray/vLLM inside every managed container
    Log "Phase 1: stopping Ray/vLLM inside all managed containers..."
    for node in "${nodes_to_stop[@]}"; do
      local ip
      ip=$(get_node_info $node lan_ip)
      (
        # Find all containers with cluster.service label on this node
        local cnames
        cnames=$(ssh admin@${ip} \
          "sudo docker ps -a --filter 'label=cluster.service' --format '{{.Names}}'" 2>/dev/null || true)
        if [[ -n "$cnames" ]]; then
          while IFS= read -r cname; do
            [[ -z "$cname" ]] && continue
            ssh admin@${ip} \
              "sudo docker exec ${cname} /opt/vllm_cluster.sh stop-all 2>/dev/null || true" \
              2>/dev/null || true
          done <<< "$cnames"
        fi
        # Also kill any legacy vllm-node-N containers (pre-rename-scheme migration)
        ssh admin@${ip} \
          "sudo docker rm -f vllm-node-${node} 2>/dev/null || true" \
          2>/dev/null || true
      ) &
    done
    wait
    Log "  Ray/vLLM stop complete"

    # Phase 2: remove all managed containers
    Log "Phase 2: removing all managed containers..."
    for node in "${nodes_to_stop[@]}"; do
      local ip
      ip=$(get_node_info $node lan_ip)
      (
        local cnames
        cnames=$(ssh admin@${ip} \
          "sudo docker ps -a --filter 'label=cluster.service' --format '{{.Names}}'" 2>/dev/null || true)
        if [[ -n "$cnames" ]]; then
          while IFS= read -r cname; do
            [[ -z "$cname" ]] && continue
            ssh admin@${ip} "sudo docker rm -f ${cname} 2>/dev/null || true"
          done <<< "$cnames"
        fi
      ) &
    done
    wait
    Log "Nuclear stop complete."
  fi
}

# ==============================================================================
# cmd_stop_model (unload model, keep containers + Ray)
# ==============================================================================
cmd_stop_model() {
  local profile="${1:-}"
  [[ -n "$profile" ]] && profile=$(resolve_favorite "$profile")

  local head_node=1
  [[ ${#ACTIVE_NODES[@]} -gt 0 ]] && head_node="${ACTIVE_NODES[0]}"

  local node_ip
  node_ip=$(get_node_info $head_node lan_ip)

  if [[ -n "$profile" ]]; then
    local cname
    cname=$(container_name_for "${profile}" "${head_node}")
    Log "Stopping model in ${cname} (node ${head_node})"
    ssh admin@${node_ip} "sudo docker exec ${cname} /opt/vllm_cluster.sh stop-model"
  else
    # No profile: stop model in every managed container on head node
    Log "Stopping model in all managed containers on node ${head_node}"
    local cnames
    cnames=$(ssh admin@${node_ip} \
      "sudo docker ps --filter 'label=cluster.service' --format '{{.Names}}'" 2>/dev/null || true)
    if [[ -n "$cnames" ]]; then
      while IFS= read -r cname; do
        [[ -z "$cname" ]] && continue
        Log "  Stopping model in ${cname}"
        ssh admin@${node_ip} "sudo docker exec ${cname} /opt/vllm_cluster.sh stop-model 2>/dev/null || true"
      done <<< "$cnames"
    else
      Log "  No managed containers found on node ${head_node}"
    fi
  fi
}

# ==============================================================================
# cmd_status
# ==============================================================================
cmd_status() {
  Log "=== Cluster Container Status ==="
  for node_num in 1 2 3 4; do
    is_node_active $node_num || continue
    local node_ip
    node_ip=$(get_node_info $node_num lan_ip)
    local node_name
    node_name=$(get_node_info $node_num name)

    # Query by label — works regardless of container name scheme
    local containers
    containers=$(ssh admin@${node_ip} \
      "sudo docker ps --filter 'label=cluster.service' \
       --format 'table {{.Names}}\t{{.Label \"cluster.profile\"}}\t{{.Label \"cluster.served_name\"}}\t{{.Image}}\t{{.Status}}'" \
      2>/dev/null || true)

    if [[ -n "$containers" ]]; then
      Log "  Node ${node_num} (${node_name}):"
      while IFS= read -r line; do
        [[ -z "$line" || "$line" == NAMES* ]] && continue
        Log "    ${line}"
      done <<< "$containers"
    else
      Log "  Node ${node_num} (${node_name}): no managed containers"
    fi
  done

  # Ray status from head node
  local head_node=1
  [[ ${#ACTIVE_NODES[@]} -gt 0 ]] && head_node="${ACTIVE_NODES[0]}"
  local head_ip
  head_ip=$(get_node_info $head_node lan_ip)

  Log "=== Ray Status (from node ${head_node}) ==="
  # Try to find any managed container on head node to exec into
  local head_cname
  head_cname=$(ssh admin@${head_ip} \
    "sudo docker ps --filter 'label=cluster.service' --format '{{.Names}}' | head -1" 2>/dev/null || true)

  if [[ -n "$head_cname" ]]; then
    ssh admin@${head_ip} "sudo docker exec ${head_cname} /opt/vllm_cluster.sh status" 2>/dev/null \
      || Log "  (status call failed inside container)"
  else
    Log "  (no running managed container on head node)"
  fi
}

# ==============================================================================
# cmd_details
# ==============================================================================
VLLM_PROBE_PORTS=(8000 8001 8002 8010 8011)

cmd_details() {
  Log "=== Cluster Details (probing API endpoints) ==="
  for node_num in 1 2 3 4; do
    is_node_active $node_num || continue
    local node_ip
    node_ip=$(get_node_info $node_num lan_ip)
    local node_name
    node_name=$(get_node_info $node_num name)

    local containers
    containers=$(ssh admin@${node_ip} \
      "sudo docker ps --filter 'label=cluster.service' --format '{{.Names}}|{{.Label \"cluster.profile\"}}'" \
      2>/dev/null || true)

    if [[ -z "$containers" ]]; then
      Log "  Node ${node_num} (${node_name}): no managed containers"
      continue
    fi

    Log "  Node ${node_num} (${node_name}):"
    while IFS='|' read -r cname cprofile; do
      [[ -z "$cname" ]] && continue
      Log "    Container: ${cname} (profile: ${cprofile})"
    done <<< "$containers"

    local found_any=0
    for port in "${VLLM_PROBE_PORTS[@]}"; do
      local response
      response=$(curl -s --connect-timeout 2 --max-time 5 \
        "http://${node_ip}:${port}/v1/models" 2>/dev/null)
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
    [[ $found_any -eq 0 ]] && Log "    (containers running, no API on ports ${VLLM_PROBE_PORTS[*]})"
  done
}

# ==============================================================================
# cmd_fav
# ==============================================================================
cmd_fav() {
  local arg="${1:-list}"

  if [[ "$arg" == "list" ]]; then
    echo ""
    echo "=== Favorite Aliases ==="
    if [[ ${#FAVORITES[@]} -eq 0 ]]; then
      echo "  (none defined — edit cluster_favorites.sh)"
    else
      # Sort by key for readability
      for key in $(echo "${!FAVORITES[@]}" | tr ' ' '\n' | sort); do
        printf "  %-20s → %s\n" "$key" "${FAVORITES[$key]}"
      done
    fi

    echo ""
    echo "=== Sequences ==="
    if [[ ${#SEQUENCES[@]} -eq 0 ]]; then
      echo "  (none defined — edit cluster_favorites.sh)"
    else
      for key in $(echo "${!SEQUENCES[@]}" | tr ' ' '\n' | sort); do
        local entry="${SEQUENCES[$key]}"
        local desc
        desc=$(echo "$entry" | cut -d'|' -f2)
        printf "  %-20s %s\n" "$key" "$desc"
      done
    fi
    echo ""
    return 0
  fi

  # Check if it's a sequence first
  if is_sequence "$arg"; then
    run_sequence "$arg"
    return $?
  fi

  # Otherwise treat as profile alias — print the expansion and exit
  # (actual execution is left to the caller to re-invoke with the expanded name,
  #  OR the user can use it inline: ./orchestrator.sh load-model $(./orchestrator.sh fav ds4))
  local expanded
  expanded=$(resolve_favorite "$arg")
  if [[ "$expanded" == "$arg" ]]; then
    Die "Unknown favorite or sequence: '${arg}'. Run 'fav list' to see options."
  fi
  echo "$expanded"
}

# ==============================================================================
# Argument parsing + dispatch
# ==============================================================================
COMMAND=""
ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --help|-h)
      COMMAND="help"; shift ;;
    --nodes)
      parse_node_filter "$2"; shift 2 ;;
    start-cluster|load-model|unload-model|stop-model|stop-cluster|status|details|fav)
      COMMAND="$1"; shift; ARGS=("$@"); break ;;
    *)
      Die "Unknown argument: $1" ;;
  esac
done

if [[ -z "$COMMAND" || "$COMMAND" == "help" ]]; then
  cat <<'USAGE'
Usage: ./vllm_cluster_orchestrator.sh [--nodes N,M,...] <command> [args]

Commands:
  start-cluster [PROFILE]      Start containers; infer node count from profile TP
  start-cluster N [PROFILE]    Start N containers (explicit node count)
  load-model PROFILE           Load model into running containers
  unload-model [PROFILE]       Unload model (keep Ray + containers)
  stop-cluster                 Stop ALL managed containers on selected nodes
  stop-cluster PROFILE         Surgical: stop only containers for this profile
  status                       Show container status + Ray info
  details                      Probe API endpoints, show served model names
  fav list                     List aliases and sequences
  fav <name>                   Run a sequence or print expanded alias

Node Filtering:
  --nodes 1,2        Only use nodes 1 and 2
  --nodes 3          Single node

Profiles (shortcut aliases in cluster_favorites.sh):
  ds4                deepseek-v4-flash          (TP=4, all nodes)
  ds4-tp2            deepseek-v4-flash-tp2      (TP=2, 2 nodes)
  glm                glm-4.7                    (TP=4, all nodes)
  q122               qwen3.5-122b-tp1-cust      (TP=1 per node)
  q397               qwen3.5-397b-autoround     (TP=2, 2 nodes)
  mm                 minimax-m2.7               (TP=4)
  mm-tp2             minimax-m2.7-tp2           (TP=2)
  q9b-bf16           qwen3.5-9b-bf16            (TP=1, cohabits)

Sequences (run with: fav <name>):
  ds4-up             Stop all → start DeepSeek V4 Flash TP=4
  ds4-tp2-up         Stop 3,4 → start DeepSeek V4 Flash TP=2
  glm-up             Stop all → start GLM-4.7 TP=4
  q122-prod          Stop 1,2 → start 122B TP=1 on each
  q397-heavy         Stop 1,2 → start 397B TP=2 on nodes 1+2
  mm-tp2             Stop 3,4 → start MiniMax TP=2

Examples:
  # Full sequence via fav:
  ./vllm_cluster_orchestrator.sh fav ds4-up

  # Manual equivalent:
  ./vllm_cluster_orchestrator.sh --nodes 1,2,3,4 start-cluster deepseek-v4-flash
  ./vllm_cluster_orchestrator.sh --nodes 1,2,3,4 load-model deepseek-v4-flash

  # Co-habitation: 122B on node 1, 9B also on node 1
  ./vllm_cluster_orchestrator.sh --nodes 1 start-cluster qwen3.5-122b-tp1-cust
  ./vllm_cluster_orchestrator.sh --nodes 1 load-model qwen3.5-122b-tp1-cust
  ./vllm_cluster_orchestrator.sh --nodes 1 start-cluster qwen3.5-9b-bf16
  ./vllm_cluster_orchestrator.sh --nodes 1 load-model qwen3.5-9b-bf16

  # Surgical stop — only kills the 9B, leaves 122B running:
  ./vllm_cluster_orchestrator.sh --nodes 1 stop-cluster qwen3.5-9b-bf16

  # Nuclear stop — kills everything on nodes 1 and 2:
  ./vllm_cluster_orchestrator.sh --nodes 1,2 stop-cluster

  # Using an alias:
  ./vllm_cluster_orchestrator.sh --nodes 1 load-model q122
USAGE
  [[ "$COMMAND" == "help" ]] && exit 0 || exit 1
fi

case "$COMMAND" in
  help)          : ;;
  start-cluster) cmd_start_cluster "${ARGS[0]:-}" "${ARGS[1]:-}" ;;
  load-model)    cmd_load_model "${ARGS[0]:-}" ;;
  unload-model|stop-model)
                 cmd_stop_model "${ARGS[0]:-}" ;;
  stop-cluster)  cmd_stop_cluster "${ARGS[0]:-}" ;;
  status)        cmd_status ;;
  details)       cmd_details ;;
  fav)           cmd_fav "${ARGS[0]:-list}" ;;
esac

