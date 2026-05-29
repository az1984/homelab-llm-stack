#!/usr/bin/env bash
# bench_sweep.sh
#
# Runs bench_essays.sh in sequence for 1..N concurrent streams,
# capturing stdout to a timestamped logfile.
#
# Usage:
#   ./bench_sweep.sh                          # 1-4 streams, defaults
#   ./bench_sweep.sh --streams 6              # 1-6 streams
#   ./bench_sweep.sh --random-offset          # randomize subject start
#   ./bench_sweep.sh --host 192.168.2.44      # different node
#
# All flags except --streams and --random-offset are passed through
# to bench_essays.sh unchanged.

set -euo pipefail

# ─────────────────────────────────────────────────────────────────────────────
# Globals
# ─────────────────────────────────────────────────────────────────────────────
BENCH_SCRIPT="${BENCH_SCRIPT:-./bench_essays.sh}"
SUBJECTS_FILE="${SUBJECTS_FILE:-bench_subjects.txt}"
MAX_STREAMS="${MAX_STREAMS:-4}"
MAX_TOKENS="${MAX_TOKENS:-2048}"
RANDOM_OFFSET=0
LOG_DIR="${LOG_DIR:-bench_logs}"

# Passthrough args for bench_essays.sh
PASSTHROUGH_ARGS=()

# ─────────────────────────────────────────────────────────────────────────────
# CLI Parsing
# ─────────────────────────────────────────────────────────────────────────────
function ParseArgsCLI {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --streams)
        MAX_STREAMS="$2"; shift 2 ;;
      --random-offset)
        RANDOM_OFFSET=1; shift ;;
      --subjects-file|--subjects)
        SUBJECTS_FILE="$2"
        PASSTHROUGH_ARGS+=("--subjects" "$2")
        shift 2 ;;
      --max-tokens)
        MAX_TOKENS="$2"
        PASSTHROUGH_ARGS+=("--max-tokens" "$2")
        shift 2 ;;
      --host|--port|--model)
        PASSTHROUGH_ARGS+=("$1" "$2"); shift 2 ;;
      --help|-h)
        _Usage; exit 0 ;;
      *)
        echo "Unknown arg: $1"; _Usage; exit 1 ;;
    esac
  done
}

function _Usage {
  cat <<'EOF'
Usage: bench_sweep.sh [OPTIONS]

Runs bench_essays.sh for stream counts 1 through --streams N in sequence.
All output is tee'd to a timestamped log file.

Options:
  --streams N           Max concurrent streams to sweep up to (default: 4)
  --random-offset       Randomize subject start offset to avoid cache hits
  --host HOST           Passed through to bench_essays.sh
  --port PORT           Passed through to bench_essays.sh
  --model MODEL         Passed through to bench_essays.sh
  --subjects-file FILE  Subjects file (default: bench_subjects.txt)
  --max-tokens N        Max tokens per response (default: 2048)
  --help                Show this help

Examples:
  ./bench_sweep.sh --streams 4 --random-offset
  ./bench_sweep.sh --streams 6 --host 192.168.2.44 --model chat-heavy
EOF
}

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
function _Log {
  # Writes to stdout (which is tee'd to logfile by CoreExec)
  echo "[sweep] $*"
}

function _SubjectCount {
  # Count non-empty lines in subjects file
  local count
  count=$(grep -c . "${SUBJECTS_FILE}" 2>/dev/null || echo 0)
  echo "${count}"
}

function _RandomOffset {
  # Pick a random offset such that MAX_STREAMS subjects remain available
  local total
  total=$(_SubjectCount)
  local max_offset=$(( total - MAX_STREAMS ))
  if [[ ${max_offset} -le 0 ]]; then
    echo 0
    return
  fi
  echo $(( RANDOM % max_offset ))
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
function CoreExec {
  ParseArgsCLI "$@"

  if [[ ! -f "${BENCH_SCRIPT}" ]]; then
    echo "ERROR: bench_essays.sh not found at: ${BENCH_SCRIPT}"
    echo "       Set BENCH_SCRIPT env var or run from the same directory."
    exit 1
  fi

  if [[ ! -f "${SUBJECTS_FILE}" ]]; then
    echo "ERROR: subjects file not found: ${SUBJECTS_FILE}"
    exit 1
  fi

  local subject_count
  subject_count=$(_SubjectCount)
  if [[ ${subject_count} -lt ${MAX_STREAMS} ]]; then
    echo "ERROR: need at least ${MAX_STREAMS} subjects, but ${SUBJECTS_FILE} has ${subject_count}"
    exit 1
  fi

  # Determine offset
  local base_offset=0
  if [[ ${RANDOM_OFFSET} -eq 1 ]]; then
    base_offset=$(_RandomOffset)
  fi

  # Set up log file
  mkdir -p "${LOG_DIR}"
  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  local log_file="${LOG_DIR}/sweep_${timestamp}_1-${MAX_STREAMS}streams.log"

  # Tee all output to log from this point forward
  exec > >(tee -a "${log_file}") 2>&1

  _Log "============================================"
  _Log "Benchmark sweep: 1 to ${MAX_STREAMS} streams"
  _Log "Subjects file:   ${SUBJECTS_FILE} (${subject_count} subjects)"
  _Log "Base offset:     ${base_offset}$([ ${RANDOM_OFFSET} -eq 1 ] && echo ' (random)' || echo '')"
  _Log "Max tokens:      ${MAX_TOKENS}"
  _Log "Log file:        ${log_file}"
  _Log "Passthrough:     ${PASSTHROUGH_ARGS[*]:-none}"
  _Log "============================================"
  _Log ""

  local sweep_start
  sweep_start=$(date +%s.%N)

  for (( n=1; n<=MAX_STREAMS; n++ )); do
    local offset=$(( base_offset + n - 1 ))

    # Make sure we don't run off the end of the subjects file
    local needed=$(( offset + n ))
    if [[ ${needed} -gt ${subject_count} ]]; then
      _Log "WARNING: not enough subjects for ${n} streams at offset ${offset} — wrapping to 0"
      offset=0
    fi

    _Log "--------------------------------------------"
    _Log "Run ${n}/${MAX_STREAMS}: ${n} concurrent stream(s), offset ${offset}"
    _Log "--------------------------------------------"

    "${BENCH_SCRIPT}" \
      --streams "${n}" \
      --offset  "${offset}" \
      "${PASSTHROUGH_ARGS[@]+"${PASSTHROUGH_ARGS[@]}"}"

    _Log ""
  done

  local sweep_end
  sweep_end=$(date +%s.%N)
  local sweep_wall
  sweep_wall=$(echo "${sweep_end} - ${sweep_start}" | bc)

  _Log "============================================"
  _Log "Sweep complete. Total wall time: ${sweep_wall}s"
  _Log "Full log: ${log_file}"
  _Log "============================================"
}

CoreExec "$@"
