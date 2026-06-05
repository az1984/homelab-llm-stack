#!/usr/bin/env bash
# port_monitor_deploy.sh
#
# Run from helium (controller). Deploys port_monitor.sh into running vLLM
# containers on the specified nodes, starts monitoring in background, then
# prints "Ready to launch orchestrator" and streams logs from all nodes.
#
# Usage:
#   ./port_monitor_deploy.sh --nodes 3,4 --ports 8010,8011,29500
#   ./port_monitor_deploy.sh --nodes 3,4 --ports 8010,8011,29500 --interval 0.5
#   ./port_monitor_deploy.sh --nodes 3,4                          # watch all ports
#
# After this prints "Ready to launch orchestrator", run your orchestrator
# load-model command in another terminal. This script will keep streaming
# logs until duration expires or you Ctrl-C.
#
# Assumes:
#   - Containers named vllm-node-N (e.g. vllm-node-3, vllm-node-4)
#   - SSH admin@<node>.elements.song works from helium
#   - Docker is accessible via sudo on each node

set -uo pipefail

# ==============================================================================
# Defaults
# ==============================================================================
NODES=""
WATCH_PORTS=""
INTERVAL="${INTERVAL:-0.5}"
DURATION="${DURATION:-120}"
SSH_USER="${SSH_USER:-admin}"
DOMAIN="${DOMAIN:-elements.song}"
CONTAINER_PREFIX="${CONTAINER_PREFIX:-vllm-node-}"
REMOTE_SCRIPT="/tmp/port_monitor.sh"
REMOTE_LOG="/tmp/port_monitor.log"

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --nodes|-n)      NODES="$2";       shift 2 ;;
    --ports|-p)      WATCH_PORTS="$2"; shift 2 ;;
    --interval|-i)   INTERVAL="$2";    shift 2 ;;
    --duration|-d)   DURATION="$2";    shift 2 ;;
    --ssh-user|-u)   SSH_USER="$2";    shift 2 ;;
    --domain)        DOMAIN="$2";      shift 2 ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "${NODES}" ]]; then
  echo "Error: --nodes is required (e.g. --nodes 3,4)" >&2
  exit 1
fi

# ==============================================================================
# Node name helpers
# ==============================================================================
node_hostname() {
  local n="$1"
  case "$n" in
    1) echo "magnesium" ;;
    2) echo "aluminium" ;;
    3) echo "silicon"   ;;
    4) echo "phosphorus" ;;
    *) echo "$n" ;;  # pass-through if already a hostname
  esac
}

node_host() {
  local n="$1"
  echo "$(node_hostname "$n").${DOMAIN}"
}

node_container() {
  local n="$1"
  echo "${CONTAINER_PREFIX}${n}"
}

# ==============================================================================
# The monitor script — embedded as heredoc, deployed to each container
# ==============================================================================
MONITOR_SCRIPT=$(cat << 'MONITOR'
#!/usr/bin/env bash
INTERVAL="${INTERVAL:-0.5}"
DURATION="${DURATION:-120}"
LOGFILE="${LOGFILE:-/tmp/port_monitor.log}"
WATCH_PORTS="${WATCH_PORTS:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval|-i)  INTERVAL="$2";   shift 2 ;;
    --duration|-d)  DURATION="$2";   shift 2 ;;
    --ports|-p)     WATCH_PORTS="$2"; shift 2 ;;
    --logfile|-l)   LOGFILE="$2";    shift 2 ;;
    *) shift ;;
  esac
done

get_listening_ports() {
  {
    [[ -f /proc/net/tcp  ]] && awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp
    [[ -f /proc/net/tcp6 ]] && awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp6
  } | cut -d: -f2 | while read -r hex; do
    printf "%d\n" "0x${hex}" 2>/dev/null
  done | sort -un
}

filter_ports() {
  local ports="$1"
  if [[ -z "${WATCH_PORTS}" ]]; then echo "${ports}"; return; fi
  local pattern
  pattern=$(echo "${WATCH_PORTS}" | tr ',' '|')
  echo "${ports}" | grep -E "^(${pattern})$" || true
}

ts() { date '+%H:%M:%S.%3N'; }

log() {
  local msg="[$(ts)] $*"
  echo "${msg}"
  echo "${msg}" >> "${LOGFILE}"
}

truncate -s 0 "${LOGFILE}" 2>/dev/null || true
log "=== port_monitor started === interval=${INTERVAL}s duration=${DURATION}s watch=${WATCH_PORTS:-ALL}"

PREV_PORTS=""
START=$(date +%s)
ITERATIONS=0

while true; do
  ELAPSED=$(( $(date +%s) - START ))
  [[ "${ELAPSED}" -ge "${DURATION}" ]] && { log "=== port_monitor finished (${DURATION}s elapsed) ==="; break; }

  RAW_PORTS=$(get_listening_ports)
  PORTS=$(filter_ports "${RAW_PORTS}")

  if [[ "${PORTS}" != "${PREV_PORTS}" ]]; then
    if [[ -z "${PREV_PORTS}" && "${ITERATIONS}" -eq 0 ]]; then
      log "INITIAL: [${PORTS//$'\n'/, }]"
    else
      ADDED=$(comm  -13 <(echo "${PREV_PORTS}") <(echo "${PORTS}") | tr '\n' ' ' | sed 's/ $//')
      REMOVED=$(comm -23 <(echo "${PREV_PORTS}") <(echo "${PORTS}") | tr '\n' ' ' | sed 's/ $//')
      msg=""
      [[ -n "${ADDED}"   ]] && msg+=" +ADDED:[${ADDED}]"
      [[ -n "${REMOVED}" ]] && msg+=" -REMOVED:[${REMOVED}]"
      log "CHANGE:${msg} | now:[${PORTS//$'\n'/, }]"
    fi
    PREV_PORTS="${PORTS}"
  fi

  ITERATIONS=$(( ITERATIONS + 1 ))
  sleep "${INTERVAL}"
done
MONITOR
)

# ==============================================================================
# Deploy and start monitors on each node
# ==============================================================================
IFS=',' read -ra NODE_LIST <<< "${NODES}"

echo ""
echo "=== port_monitor_deploy ==="
echo "Nodes:    ${NODES}"
echo "Ports:    ${WATCH_PORTS:-ALL}"
echo "Interval: ${INTERVAL}s  Duration: ${DURATION}s"
echo ""

for n in "${NODE_LIST[@]}"; do
  HOST=$(node_host "$n")
  CONTAINER=$(node_container "$n")
  PORT_ARGS=""
  [[ -n "${WATCH_PORTS}" ]] && PORT_ARGS="--ports ${WATCH_PORTS}"

  echo ">>> Waiting for container ${CONTAINER} on ${HOST}..."

  # Wait up to 180s for container to exist and be running
  WAIT_START=$(date +%s)
  while true; do
    STATUS=$(ssh "${SSH_USER}@${HOST}" \
      "sudo docker inspect --format='{{.State.Status}}' ${CONTAINER} 2>/dev/null" 2>/dev/null || true)
    if [[ "${STATUS}" == "running" ]]; then
      echo "    Container ${CONTAINER} is running."
      break
    fi
    WAIT_ELAPSED=$(( $(date +%s) - WAIT_START ))
    if [[ "${WAIT_ELAPSED}" -ge 180 ]]; then
      echo "ERROR: Container ${CONTAINER} on ${HOST} not running after 3 minutes (status=${STATUS:-not found})" >&2
      echo "       Start the cluster first: ./vllm_cluster_orchestrator.sh --nodes ${NODES} start-cluster <profile>" >&2
      exit 1
    fi
    printf "    Waiting for container... (%ds elapsed)\r" "${WAIT_ELAPSED}"
    sleep 2
  done

  echo ">>> Deploying monitor to ${HOST} container ${CONTAINER}..."

  # Write monitor script into container via SSH → docker exec
  ssh "${SSH_USER}@${HOST}" \
    "sudo docker exec -i ${CONTAINER} bash -c 'cat > ${REMOTE_SCRIPT} && chmod +x ${REMOTE_SCRIPT}'" \
    <<< "${MONITOR_SCRIPT}"

  # Start monitor in background inside container
  ssh "${SSH_USER}@${HOST}" \
    "sudo docker exec -d ${CONTAINER} bash ${REMOTE_SCRIPT} \
      --interval ${INTERVAL} \
      --duration ${DURATION} \
      ${PORT_ARGS}" 

  echo "    Monitor running in ${CONTAINER} on ${HOST}"
done

echo ""
echo "============================================================"
echo "  Monitors active on nodes: ${NODES}"
echo "  Watching ports: ${WATCH_PORTS:-ALL}"
echo ""
echo "  ✓ Ready to launch orchestrator"
echo "============================================================"
echo ""
echo "Streaming logs (Ctrl-C to stop watching, monitors keep running):"
echo ""

# ==============================================================================
# Stream logs from all nodes, prefixed with node label
# ==============================================================================
cleanup() {
  echo ""
  echo "=== Stopped watching logs. Monitors may still be running in containers. ==="
  echo "To check: ssh admin@<node> 'sudo docker exec <container> tail /tmp/port_monitor.log'"
  kill 0 2>/dev/null
}
trap cleanup INT TERM

for n in "${NODE_LIST[@]}"; do
  HOST=$(node_host "$n")
  CONTAINER=$(node_container "$n")
  LABEL="[node${n}]"

  # Stream log from container, prefix each line with node label
  ssh "${SSH_USER}@${HOST}" \
    "sudo docker exec ${CONTAINER} tail -f ${REMOTE_LOG}" \
    | sed "s/^/${LABEL} /" &
done

wait
