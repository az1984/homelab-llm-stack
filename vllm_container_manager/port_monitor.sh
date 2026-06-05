#!/usr/bin/env bash
# port_monitor.sh
#
# Monitors TCP port state inside a running vLLM container.
# Polls /proc/net/tcp (and tcp6) every INTERVAL seconds for up to DURATION seconds.
# Logs a timestamped line ONLY when the set of listening ports changes.
# Designed to be copied into the container and run before vLLM launches.
#
# Usage (from host):
#   docker exec -d vllm-node-3 /tmp/port_monitor.sh
#   docker exec -d vllm-node-3 /tmp/port_monitor.sh --interval 0.5 --duration 180
#   docker exec -d vllm-node-3 /tmp/port_monitor.sh --ports 8000,8001,29500
#
# Output goes to stdout and to /tmp/port_monitor.log inside the container.
# Watch from host: docker exec vllm-node-3 tail -f /tmp/port_monitor.log
#
# To copy to a running container:
#   docker cp port_monitor.sh vllm-node-3:/tmp/port_monitor.sh
#   docker exec vllm-node-3 chmod +x /tmp/port_monitor.sh

set -uo pipefail

# ==============================================================================
# Defaults
# ==============================================================================
INTERVAL="${INTERVAL:-1}"          # Poll interval in seconds (supports decimals via sleep)
DURATION="${DURATION:-120}"        # Total monitoring duration in seconds
LOGFILE="${LOGFILE:-/tmp/port_monitor.log}"
WATCH_PORTS="${WATCH_PORTS:-}"     # Comma-separated list of ports to watch; empty = all listening ports

# ==============================================================================
# Argument parsing
# ==============================================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --interval|-i)  INTERVAL="$2";  shift 2 ;;
    --duration|-d)  DURATION="$2";  shift 2 ;;
    --ports|-p)     WATCH_PORTS="$2"; shift 2 ;;
    --logfile|-l)   LOGFILE="$2";   shift 2 ;;
    --help|-h)
      grep '^#' "$0" | grep -v '^#!/' | sed 's/^# \?//'
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ==============================================================================
# Helpers
# ==============================================================================

# Parse /proc/net/tcp and /proc/net/tcp6, return sorted unique list of
# decimal port numbers that are in LISTEN state (state=0A).
# Format: local_address is "XXXXXXXX:PPPP" (hex ip:hex port), state field is column 4.
get_listening_ports() {
  {
    [[ -f /proc/net/tcp  ]] && awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp
    [[ -f /proc/net/tcp6 ]] && awk 'NR>1 && $4=="0A" {print $2}' /proc/net/tcp6
  } | cut -d: -f2 | while read -r hex; do
    printf "%d\n" "0x${hex}" 2>/dev/null
  done | sort -un
}

# Filter port list to only watched ports, if WATCH_PORTS is set.
filter_ports() {
  local ports="$1"
  if [[ -z "${WATCH_PORTS}" ]]; then
    echo "${ports}"
    return
  fi
  # Build grep pattern from comma-separated list
  local pattern
  pattern=$(echo "${WATCH_PORTS}" | tr ',' '|')
  echo "${ports}" | grep -E "^(${pattern})$" || true
}

ts() {
  date '+%H:%M:%S.%3N'
}

log() {
  local msg="[$(ts)] $*"
  echo "${msg}"
  echo "${msg}" >> "${LOGFILE}"
}

# ==============================================================================
# Main
# ==============================================================================
truncate -s 0 "${LOGFILE}" 2>/dev/null || true

log "=== port_monitor started === interval=${INTERVAL}s duration=${DURATION}s watch=${WATCH_PORTS:-ALL}"
log "Logfile: ${LOGFILE}"

PREV_PORTS=""
START=$(date +%s)
ITERATIONS=0

while true; do
  NOW=$(date +%s)
  ELAPSED=$(( NOW - START ))

  if [[ "${ELAPSED}" -ge "${DURATION}" ]]; then
    log "=== port_monitor finished (${DURATION}s elapsed) ==="
    break
  fi

  RAW_PORTS=$(get_listening_ports)
  PORTS=$(filter_ports "${RAW_PORTS}")

  if [[ "${PORTS}" != "${PREV_PORTS}" ]]; then
    if [[ -z "${PREV_PORTS}" && "${ITERATIONS}" -eq 0 ]]; then
      log "INITIAL: [${PORTS//$'\n'/, }]"
    else
      # Find added and removed ports
      ADDED=$(comm -13 <(echo "${PREV_PORTS}") <(echo "${PORTS}") | tr '\n' ' ' | sed 's/ $//')
      REMOVED=$(comm -23 <(echo "${PREV_PORTS}") <(echo "${PORTS}") | tr '\n' ' ' | sed 's/ $//')
      local_msg=""
      [[ -n "${ADDED}"   ]] && local_msg+=" +ADDED:[${ADDED}]"
      [[ -n "${REMOVED}" ]] && local_msg+=" -REMOVED:[${REMOVED}]"
      log "CHANGE:${local_msg} | now:[${PORTS//$'\n'/, }]"
    fi
    PREV_PORTS="${PORTS}"
  fi

  ITERATIONS=$(( ITERATIONS + 1 ))
  sleep "${INTERVAL}"
done
