#!/usr/bin/env bash
# bench_essays.sh
#
# Stress test for vLLM: fires concurrent essay-generation requests and
# measures wall time, token counts, and per-stream throughput.
#
# Usage:
#   ./bench_essays.sh                           # defaults: 4 concurrent, first 4 subjects
#   ./bench_essays.sh --streams 8               # 8 concurrent
#   ./bench_essays.sh --streams 2 --offset 10   # subjects 11-12
#   ./bench_essays.sh --host 192.168.2.44       # different node
#   ./bench_essays.sh --model qwen35-122b-a10b  # specific model name

set -euo pipefail

# =============================================================================
# Globals
# =============================================================================
HOST="${HOST:-192.168.2.42}"
PORT="${PORT:-8000}"
MODEL="${MODEL:-chat-heavy,chat-heavy-qwen,qwen35-122b-a10b}"
STREAMS="${STREAMS:-4}"
OFFSET="${OFFSET:-0}"
SUBJECTS_FILE="${SUBJECTS_FILE:-bench_subjects.txt}"
OUTPUT_DIR="${OUTPUT_DIR:-bench_results}"
TEMPERATURE="${TEMPERATURE:-0.7}"
TOP_P="${TOP_P:-0.9}"
MAX_TOKENS="${MAX_TOKENS:-2048}"

# =============================================================================
# CLI Parsing
# =============================================================================
ParseArgs() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host)       HOST="$2"; shift 2 ;;
      --port)       PORT="$2"; shift 2 ;;
      --model)      MODEL="$2"; shift 2 ;;
      --streams)    STREAMS="$2"; shift 2 ;;
      --offset)     OFFSET="$2"; shift 2 ;;
      --subjects)   SUBJECTS_FILE="$2"; shift 2 ;;
      --output)     OUTPUT_DIR="$2"; shift 2 ;;
      --max-tokens) MAX_TOKENS="$2"; shift 2 ;;
      --help|-h)    Usage; exit 0 ;;
      *)            echo "Unknown arg: $1"; Usage; exit 1 ;;
    esac
  done
}

Usage() {
  cat <<'EOF'
Usage: bench_essays.sh [OPTIONS]

Options:
  --host HOST           vLLM API host (default: 192.168.2.42)
  --port PORT           vLLM API port (default: 8000)
  --model MODEL         Model name to request (default: chat-heavy,chat-heavy-qwen,qwen35-122b-a10b)
  --streams N           Number of concurrent requests (default: 4)
  --offset N            Start from subject line N (0-indexed, default: 0)
  --subjects FILE       Subjects file, one per line (default: bench_subjects.txt)
  --output DIR          Output directory for results (default: bench_results)
  --max-tokens N        Max tokens per response (default: 2048)
  --help                Show this help

Examples:
  ./bench_essays.sh --streams 1                    # Single-stream baseline
  ./bench_essays.sh --streams 4                    # 4 concurrent
  ./bench_essays.sh --streams 8 --offset 8         # Next batch of 8
  ./bench_essays.sh --host 192.168.2.44 --streams 2  # Test node 3
EOF
}

# =============================================================================
# Helpers
# =============================================================================
Log() { echo "[bench] $*"; }

CheckEndpoint() {
  local url="http://${HOST}:${PORT}/v1/models"
  if ! curl -sf "${url}" >/dev/null 2>&1; then
    echo "ERROR: vLLM not responding at ${url}"
    exit 1
  fi
}

LoadSubjects() {
  if [[ ! -f "${SUBJECTS_FILE}" ]]; then
    echo "ERROR: subjects file not found: ${SUBJECTS_FILE}"
    exit 1
  fi
  mapfile -t ALL_SUBJECTS < "${SUBJECTS_FILE}"
  local available=$(( ${#ALL_SUBJECTS[@]} - OFFSET ))
  if [[ ${available} -lt ${STREAMS} ]]; then
    echo "ERROR: need ${STREAMS} subjects starting at offset ${OFFSET}, but only ${available} available"
    exit 1
  fi
}

# Fire one request, capture timing and token counts
# Args: stream_id subject output_file
FireRequest() {
  local stream_id="$1"
  local subject="$2"
  local out_file="$3"

  local prompt="Write me a 1000 to 1500 word essay about ${subject}. Format the essay in markdown with a title header (##), section headers (###), and use bold for key terms on first mention. Be thorough and specific, drawing on concrete details and examples. Do not pad with filler — every paragraph should advance the reader's understanding."

  local start_ts
  start_ts=$(date +%s.%N)

  local response
  response=$(curl -sf "http://${HOST}:${PORT}/v1/chat/completions" \
    -H "Content-Type: application/json" \
    -d "$(cat <<ENDJSON
{
  "model": "${MODEL}",
  "messages": [
    {"role": "user", "content": "${prompt}"}
  ],
  "max_tokens": ${MAX_TOKENS},
  "temperature": ${TEMPERATURE},
  "top_p": ${TOP_P},
  "stream": false
}
ENDJSON
)" 2>&1) || {
    local end_ts
    end_ts=$(date +%s.%N)
    echo "${stream_id}|${subject}|ERROR|0|0|0|$(echo "${end_ts} - ${start_ts}" | bc)" >> "${out_file}"
    Log "  Stream ${stream_id}: FAILED (${subject})"
    return 1
  }

  local end_ts
  end_ts=$(date +%s.%N)

  local wall_time
  wall_time=$(echo "${end_ts} - ${start_ts}" | bc)

  local prompt_tokens completion_tokens total_tokens finish_reason
  prompt_tokens=$(echo "${response}" | jq -r '.usage.prompt_tokens // 0')
  completion_tokens=$(echo "${response}" | jq -r '.usage.completion_tokens // 0')
  total_tokens=$(echo "${response}" | jq -r '.usage.total_tokens // 0')
  finish_reason=$(echo "${response}" | jq -r '.choices[0].finish_reason // "unknown"')

  local tok_per_sec
  if (( $(echo "${wall_time} > 0" | bc -l) )); then
    tok_per_sec=$(echo "scale=1; ${completion_tokens} / ${wall_time}" | bc)
  else
    tok_per_sec="0"
  fi

  # Save the essay text
  echo "${response}" | jq -r '.choices[0].message.content // "NO CONTENT"' > "${OUTPUT_DIR}/essay_${stream_id}.md"

  # Save metrics row
  echo "${stream_id}|${subject}|${finish_reason}|${prompt_tokens}|${completion_tokens}|${total_tokens}|${wall_time}|${tok_per_sec}" >> "${out_file}"

  Log "  Stream ${stream_id}: ${completion_tokens} tokens in ${wall_time}s (${tok_per_sec} tok/s) [${finish_reason}]"
}

# =============================================================================
# Main
# =============================================================================
CoreExec() {
  ParseArgs "$@"
  LoadSubjects
  CheckEndpoint

  local timestamp
  timestamp=$(date +%Y%m%d_%H%M%S)
  OUTPUT_DIR="${OUTPUT_DIR}/${timestamp}_${STREAMS}streams"
  mkdir -p "${OUTPUT_DIR}"

  local metrics_file="${OUTPUT_DIR}/metrics.csv"
  echo "stream_id|subject|finish_reason|prompt_tokens|completion_tokens|total_tokens|wall_seconds|tok_per_sec" > "${metrics_file}"

  Log "============================================"
  Log "Benchmark: ${STREAMS} concurrent streams"
  Log "Host: ${HOST}:${PORT}"
  Log "Model: ${MODEL}"
  Log "Max tokens: ${MAX_TOKENS}"
  Log "Output: ${OUTPUT_DIR}"
  Log "============================================"

  local bench_start
  bench_start=$(date +%s.%N)

  # Fire all streams in parallel
  local pids=()
  for (( i=0; i<STREAMS; i++ )); do
    local idx=$(( OFFSET + i ))
    local subject="${ALL_SUBJECTS[$idx]}"
    Log "Starting stream $((i+1))/${STREAMS}: ${subject}"
    FireRequest "$((i+1))" "${subject}" "${metrics_file}" &
    pids+=($!)
  done

  # Wait for all
  local failures=0
  for pid in "${pids[@]}"; do
    wait "${pid}" || (( failures++ ))
  done

  local bench_end
  bench_end=$(date +%s.%N)
  local bench_wall
  bench_wall=$(echo "${bench_end} - ${bench_start}" | bc)

  Log ""
  Log "============================================"
  Log "Results"
  Log "============================================"

  # Summary stats
  local total_completion_tokens=0
  local count=0
  while IFS='|' read -r sid subj fr pt ct tt ws tps; do
    [[ "${sid}" == "stream_id" ]] && continue
    [[ "${fr}" == "ERROR" ]] && continue
    total_completion_tokens=$(( total_completion_tokens + ct ))
    (( count++ ))
  done < "${metrics_file}"

  local aggregate_tps="0"
  if (( $(echo "${bench_wall} > 0" | bc -l) )); then
    aggregate_tps=$(echo "scale=1; ${total_completion_tokens} / ${bench_wall}" | bc)
  fi

  Log "Streams: ${STREAMS} (${count} succeeded, ${failures} failed)"
  Log "Wall time: ${bench_wall}s"
  Log "Total completion tokens: ${total_completion_tokens}"
  Log "Aggregate throughput: ${aggregate_tps} tok/s"
  Log ""

  # Per-stream detail
  Log "Per-stream breakdown:"
  Log "  ID | Tokens | Time    | Tok/s  | Status  | Subject"
  Log "  ---|--------|---------|--------|---------|--------"
  while IFS='|' read -r sid subj fr pt ct tt ws tps; do
    [[ "${sid}" == "stream_id" ]] && continue
    printf "  %-3s| %-7s| %-8s| %-7s| %-8s| %s\n" "${sid}" "${ct}" "${ws}s" "${tps}" "${fr}" "${subj}"
  done < "${metrics_file}"

  Log ""
  Log "Metrics saved: ${metrics_file}"
  Log "Essays saved: ${OUTPUT_DIR}/essay_*.md"

  # Save summary
  cat > "${OUTPUT_DIR}/summary.txt" <<SUMMARY
Benchmark Summary
=================
Date:            ${timestamp}
Host:            ${HOST}:${PORT}
Model:           ${MODEL}
Streams:         ${STREAMS}
Wall time:       ${bench_wall}s
Completion tok:  ${total_completion_tokens}
Aggregate tok/s: ${aggregate_tps}
Succeeded:       ${count}
Failed:          ${failures}
SUMMARY

  Log "Summary saved: ${OUTPUT_DIR}/summary.txt"
}

CoreExec "$@"
