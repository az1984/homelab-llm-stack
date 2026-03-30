#!/usr/bin/env bash
# local_build.sh
# Generic vLLM Docker image builder for GB10
# RUN THIS DIRECTLY ON THE BUILD NODE (e.g. phosphorus), NOT from your Mac
#
# Usage:
#   ./local_build.sh <dockerfile> <image_tag> [--docker-opt=<option>...]
#
# Examples:
#   ./local_build.sh Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2
#   ./local_build.sh Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2 --docker-opt=no-cache
#   ./local_build.sh Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2 --docker-opt=no-cache --docker-opt=pull

set -euo pipefail

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
DOCKERFILE=""
IMAGE_TAG=""
DOCKER_OPTS=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker-opt=*)
            DOCKER_OPTS+=("--${1#--docker-opt=}")
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
    echo "Usage: $0 <dockerfile> <image_tag> [--docker-opt=<option>...]"
    echo ""
    echo "Arguments:"
    echo "  dockerfile             Path to the Dockerfile to build"
    echo "  image_tag              Full image tag including registry"
    echo "  --docker-opt=<option>  Extra docker build flags (repeatable)"
    echo ""
    echo "Examples:"
    echo "  $0 Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2"
    echo "  $0 Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2 --docker-opt=no-cache"
    echo "  $0 Dockerfile_vllm-v0_18.1-gb10 192.168.2.42:5000/vllm-gb10:0.18.0_b2 --docker-opt=no-cache --docker-opt=pull"
    exit 1
fi

# =============================================================================
# ARCHITECTURE SAFETY CHECK
# =============================================================================
ARCH=$(uname -m)
if [[ "$ARCH" != "aarch64" ]]; then
    echo "=========================================="
    echo "ERROR: Wrong Architecture!"
    echo "=========================================="
    echo ""
    echo "Current architecture: $ARCH"
    echo "Required architecture: aarch64 (ARM)"
    echo ""
    echo "This build MUST run on a GB10 cluster node, NOT on your Mac."
    echo ""
    exit 1
fi

echo "=========================================="
echo "vLLM Docker Image Build for GB10"
echo "=========================================="
echo "Architecture check passed: $ARCH (ARM)"
echo ""
echo "Configuration:"
echo "  Dockerfile:   ${DOCKERFILE}"
echo "  Image Tag:    ${IMAGE_TAG}"
if [[ ${#DOCKER_OPTS[@]} -gt 0 ]]; then
    echo "  Docker Opts:  ${DOCKER_OPTS[*]}"
else
    echo "  Docker Opts:  (default, using layer cache)"
fi
echo "  Build Dir:    $(pwd)"
echo ""

# List supplementary files in the build context
echo "Build context files:"
ls -lh *.patched 2>/dev/null || echo "  (no patch files found)"
echo ""

# =============================================================================
# FILE CHECK
# =============================================================================
if [[ ! -f "${DOCKERFILE}" ]]; then
    echo "ERROR: ${DOCKERFILE} not found in current directory"
    exit 1
fi

# =============================================================================
# DISK SPACE CHECK
# =============================================================================
AVAILABLE_GB=$(df -BG /var/lib/docker | tail -1 | awk '{print $4}' | sed 's/G//')
if [[ $AVAILABLE_GB -lt 30 ]]; then
    echo "WARNING: Low disk space!"
    echo "Available: ${AVAILABLE_GB}GB (recommended: 30GB+)"
    echo "Free up space with: docker system prune -a"
    echo ""
    read -p "Continue anyway? (y/N) " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]] || exit 1
fi

# =============================================================================
# DOCKER CHECK
# =============================================================================
if ! docker info >/dev/null 2>&1; then
    echo "ERROR: Docker is not running or not accessible"
    echo "Fix: sudo systemctl start docker"
    exit 1
fi

# =============================================================================
# CONFIRMATION
# =============================================================================
echo "This will build ${IMAGE_TAG} from ${DOCKERFILE}"
echo "Build time may be 2-3 hours for full CUDA kernel compilation."
echo ""
echo "Press Enter to start (or Ctrl+C to cancel)"
read -r

# =============================================================================
# BUILD
# =============================================================================
BUILD_START=$(date +%s)

echo ""
echo "=========================================="
echo "Starting Build at $(date)"
echo "=========================================="
echo ""

docker build \
    ${DOCKER_OPTS[@]+"${DOCKER_OPTS[@]}"} \
    -t "${IMAGE_TAG}" \
    -f "${DOCKERFILE}" \
    . 2>&1 | tee build.log

BUILD_EXIT_CODE=${PIPESTATUS[0]}
BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))
BUILD_MIN=$((BUILD_TIME / 60))
BUILD_SEC=$((BUILD_TIME % 60))

echo ""
echo "Finished at: $(date)"
echo "Build time: ${BUILD_MIN}m ${BUILD_SEC}s"
echo ""

if [[ $BUILD_EXIT_CODE -eq 0 ]]; then
    echo "=========================================="
    echo "BUILD SUCCESSFUL"
    echo "=========================================="
    echo ""
    echo "Image: ${IMAGE_TAG}"
    echo "Time:  ${BUILD_MIN}m ${BUILD_SEC}s"
    echo ""
    echo "Next steps:"
    echo "  1. Test:  docker run --rm --gpus all --entrypoint python3 ${IMAGE_TAG} -c 'import vllm; print(vllm.__version__)'"
    echo "  2. Push:  docker push ${IMAGE_TAG}"
    echo ""
else
    echo "=========================================="
    echo "BUILD FAILED"
    echo "=========================================="
    echo ""
    echo "Failed after ${BUILD_MIN}m ${BUILD_SEC}s"
    echo "Check: tail -100 build.log"
    exit 1
fi
