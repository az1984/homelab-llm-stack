#!/usr/bin/env bash
# remote_build.sh
# Orchestrates a vLLM Docker build on a remote GB10 node from your Mac
# Copies files, starts build in tmux, deploys watchdog
#
# Usage:
#   ./remote_build.sh <dockerfile> <image_tag> [--node=<ssh_target>] [--docker-opt=<option>...]
#
# Examples:
#   ./remote_build.sh Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2
#   ./remote_build.sh Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2 --docker-opt=no-cache
#   ./remote_build.sh Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2 --node=agentdev@192.168.2.44 --docker-opt=no-cache --docker-opt=pull

set -euo pipefail

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
DOCKERFILE=""
IMAGE_TAG=""
BUILD_NODE="agentdev@192.168.2.45"
DOCKER_OPT_ARGS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --node=*)
            BUILD_NODE="${1#--node=}"
            shift
            ;;
        --docker-opt=*)
            DOCKER_OPT_ARGS+=("$1")
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            if [[ -z "${DOCKERFILE}" ]]; then
                DOCKERFILE="$1"
            elif [[ -z "${IMAGE_TAG}" ]]; then
                IMAGE_TAG="$1"
            else
                echo "Unexpected argument: $1"
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "${DOCKERFILE}" || -z "${IMAGE_TAG}" ]]; then
    echo "Usage: $0 <dockerfile> <image_tag> [--node=<ssh_target>] [--docker-opt=<option>...]"
    echo ""
    echo "Arguments:"
    echo "  dockerfile               Path to the Dockerfile (local, will be copied to node)"
    echo "  image_tag                Full image tag including registry"
    echo "  --node=<ssh_target>      SSH target (default: agentdev@192.168.2.45 / phosphorus)"
    echo "  --docker-opt=<option>    Extra docker build flags, passed to local_build.sh (repeatable)"
    echo ""
    echo "Examples:"
    echo "  $0 Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2"
    echo "  $0 Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2 --docker-opt=no-cache"
    exit 1
fi

BUILD_DIR="/home/agentdev/vllm-build"

if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "ERROR: ${DOCKERFILE} not found locally"
    exit 1
fi

echo "=== Remote vLLM Build ==="
echo "Dockerfile:   ${DOCKERFILE}"
echo "Image tag:    ${IMAGE_TAG}"
echo "Build node:   ${BUILD_NODE}"
echo "Build dir:    ${BUILD_DIR}"
if [[ ${#DOCKER_OPT_ARGS[@]} -gt 0 ]]; then
    echo "Docker opts:  ${DOCKER_OPT_ARGS[*]}"
else
    echo "Docker opts:  (default, using layer cache)"
fi
echo ""

# =============================================================================
# COPY FILES TO BUILD NODE
# =============================================================================
echo "=== Step 1: Preparing build directory on $(echo ${BUILD_NODE} | cut -d@ -f2) ==="
ssh ${BUILD_NODE} "mkdir -p ${BUILD_DIR}"

echo "=== Step 2: Copying Dockerfile ==="
scp "${DOCKERFILE}" ${BUILD_NODE}:${BUILD_DIR}/Dockerfile

echo "=== Step 3: Copying supplementary files ==="
for f in *.patched; do
    if [[ -f "$f" ]]; then
        echo "  Copying $f"
        scp "$f" ${BUILD_NODE}:${BUILD_DIR}/
    fi
done

echo "=== Step 4: Copying build script ==="
scp local_build.sh ${BUILD_NODE}:${BUILD_DIR}/local_build.sh
ssh ${BUILD_NODE} "chmod +x ${BUILD_DIR}/local_build.sh"

# =============================================================================
# START BUILD IN TMUX
# =============================================================================
# Build the docker-opt args string for passthrough
DOCKER_OPT_STR=""
for opt in "${DOCKER_OPT_ARGS[@]+"${DOCKER_OPT_ARGS[@]}"}"; do
    DOCKER_OPT_STR="${DOCKER_OPT_STR} ${opt}"
done

echo ""
echo "=== Step 5: Starting Docker build in tmux ==="
ssh ${BUILD_NODE} << BUILDCMD
cd ${BUILD_DIR}
tmux kill-session -t vllm_build 2>/dev/null || true
tmux new-session -d -s vllm_build "./local_build.sh Dockerfile ${IMAGE_TAG}${DOCKER_OPT_STR} 2>&1 | tee build.log"
echo "Build started in tmux session 'vllm_build'"
BUILDCMD

# =============================================================================
# DEPLOY WATCHDOG
# =============================================================================
echo ""
echo "=== Step 6: Deploying watchdog ==="
cat > /tmp/vllm_build_watchdog.sh << 'WATCHDOG_EOF'
#!/usr/bin/env bash
set -euo pipefail

BUILD_LOG="/home/agentdev/vllm-build/build.log"
STATUS_FILE="/tmp/build_status.txt"
CHECK_INTERVAL=1200
MAX_STALL_TIME=7200

last_size=0
stall_count=0

echo "=== Build Watchdog Started at $(date) ===" | tee -a "${STATUS_FILE}"

while true; do
  if [[ ! -f "${BUILD_LOG}" ]]; then
    echo "[$(date)] Waiting for build log to appear..." | tee -a "${STATUS_FILE}"
    sleep "${CHECK_INTERVAL}"
    continue
  fi

  current_size=$(stat -c%s "${BUILD_LOG}" 2>/dev/null || echo 0)

  if [[ "${current_size}" -eq "${last_size}" ]]; then
    ((stall_count++))
    stall_duration=$((stall_count * CHECK_INTERVAL))

    if [[ "${stall_duration}" -gt "${MAX_STALL_TIME}" ]]; then
      echo "[$(date)] BUILD STALLED - No log growth for ${stall_duration}s" | tee -a "${STATUS_FILE}"
      tail -100 "${BUILD_LOG}" > /tmp/build_failure.log
      break
    fi
  else
    stall_count=0
  fi

  if grep -q "BUILD SUCCESSFUL\|Successfully tagged\|writing image" "${BUILD_LOG}" 2>/dev/null; then
    echo "[$(date)] BUILD SUCCESS" | tee -a "${STATUS_FILE}"
    break
  fi

  echo "[$(date)] Build running... (${current_size} bytes)" | tee -a "${STATUS_FILE}"
  last_size="${current_size}"
  sleep "${CHECK_INTERVAL}"
done

echo "[$(date)] Watchdog completed" | tee -a "${STATUS_FILE}"
WATCHDOG_EOF

scp /tmp/vllm_build_watchdog.sh ${BUILD_NODE}:/tmp/
ssh ${BUILD_NODE} << 'WATCHDOG_START'
chmod +x /tmp/vllm_build_watchdog.sh
tmux kill-session -t build_watchdog 2>/dev/null || true
tmux new-session -d -s build_watchdog '/tmp/vllm_build_watchdog.sh'
echo "Watchdog running in tmux session 'build_watchdog'"
WATCHDOG_START

# =============================================================================
# INSTRUCTIONS
# =============================================================================
NODE_IP=$(echo ${BUILD_NODE} | cut -d@ -f2)
echo ""
echo "=== Build Running ==="
echo ""
echo "Monitor from your Mac:"
echo "  while true; do clear; ssh ${BUILD_NODE} 'tail -20 /tmp/build_status.txt'; sleep 60; done"
echo ""
echo "View build log:"
echo "  ssh ${BUILD_NODE} 'tail -f ${BUILD_DIR}/build.log'"
echo ""
echo "Attach to build session:"
echo "  ssh ${BUILD_NODE} -t 'tmux attach -t vllm_build'"
echo ""
echo "Expected build time: 2-3 hours"
echo ""
