#!/usr/bin/env bash
# Benchmark Suite - Performance & Quality Testing
# Prerequisites: vLLM server must already be running
#
# This script is a DUMB CLIENT - it just sends requests to your server.
# You are responsible for starting the server beforehand.
#
# Usage:
#   ./benchmark_suite.sh <output_dir> <endpoint_url> [model_name] [api_key]

set -euo pipefail

OUTPUT_DIR="${1:-}"
ENDPOINT_URL="${2:-}"
MODEL_NAME="${3:-auto}"
API_KEY="${4:-}"

if [[ -z "$OUTPUT_DIR" ]] || [[ -z "$ENDPOINT_URL" ]]; then
    cat <<'USAGE'
Usage: ./benchmark_suite.sh <output_dir> <endpoint_url> [model_name] [api_key]

Arguments:
  output_dir   - Where to save results
  endpoint_url - Base URL (e.g., http://192.168.2.42:8000)
  model_name   - Model identifier (default: auto-detect)
  api_key      - Optional API key

Examples:
  # Test local vLLM (already running)
  ./benchmark_suite.sh ./results/qwen3vl http://192.168.2.42:8000

  # Test with explicit model name
  ./benchmark_suite.sh ./results/qwen35 http://192.168.2.43:8001 qwen3.5-122b

  # Test remote API with auth
  ./benchmark_suite.sh ./results/claude https://api.anthropic.com claude-3-opus sk-ant-...

Workflow:
  1. Start your server FIRST (separate task):
     ./vllm_cluster_orchestrator-alt.sh start-cluster 2
     ./vllm_cluster_orchestrator-alt.sh load-model qwen3-vl-235b
     # Wait for "Model loaded successfully"
  
  2. Run this benchmark:
     ./benchmark_suite.sh ./results/baseline http://192.168.2.42:8000

Prerequisites:
  - pip install vllm[benchmark]  (for performance tests)
  - pip install lm-evaluation-harness  (for quality tests)
USAGE
    exit 1
fi

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
mkdir -p "$OUTPUT_DIR"
LOG_FILE="$OUTPUT_DIR/benchmark_${TIMESTAMP}.log"

Log() {
    echo "[$(date +'%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

Log "=========================================="
Log "BENCHMARK SUITE"
Log "=========================================="
Log "Output: $OUTPUT_DIR"
Log "Endpoint: $ENDPOINT_URL"
Log "Timestamp: $TIMESTAMP"
Log ""

# ============================================================================
# HEALTH CHECK
# ============================================================================

Log "Checking server health..."

if ! curl -s -f "${ENDPOINT_URL}/v1/models" -o /dev/null 2>&1; then
    Log "✗ FAILED: Server not responding"
    Log ""
    Log "Troubleshooting:"
    Log "  1. Is server running? Check: curl ${ENDPOINT_URL}/v1/models"
    Log "  2. Is URL correct? Try: curl ${ENDPOINT_URL}/health"
    Log "  3. Firewall blocking? Check network access"
    Log ""
    exit 1
fi

# Auto-detect model name
if [[ "$MODEL_NAME" == "auto" ]]; then
    MODEL_NAME=$(curl -s "${ENDPOINT_URL}/v1/models" | jq -r '.data[0].id // "unknown"' 2>/dev/null || echo "unknown")
    Log "✓ Server healthy, detected model: $MODEL_NAME"
else
    Log "✓ Server healthy, using model: $MODEL_NAME"
fi

Log ""

# ============================================================================
# PART 1: Performance Benchmarks
# ============================================================================

Log "=========================================="
Log "PART 1: Performance Benchmarks"
Log "=========================================="
Log ""

if ! command -v vllm >/dev/null 2>&1; then
    Log "⚠️  vllm not installed, skipping performance tests"
    Log "   Install: pip install vllm[benchmark]"
    Log ""
else
    # Throughput
    Log "[1/4] Throughput (max load, 100 prompts)"
    vllm bench serve \
        --backend vllm \
        --base-url "$ENDPOINT_URL" \
        --model "$MODEL_NAME" \
        --endpoint /v1/completions \
        --dataset-name random \
        --num-prompts 100 \
        --random-input-len 2048 \
        --random-output-len 512 \
        --request-rate inf \
        --save-results \
        --result-filename "$OUTPUT_DIR/01_throughput.json" \
        2>&1 | tee -a "$LOG_FILE" || Log "  ⚠️  Failed"
    
    Log ""
    
    # Latency
    Log "[2/4] Latency (light load)"
    vllm bench serve \
        --backend vllm \
        --base-url "$ENDPOINT_URL" \
        --model "$MODEL_NAME" \
        --endpoint /v1/completions \
        --dataset-name random \
        --num-prompts 50 \
        --random-input-len 1024 \
        --random-output-len 256 \
        --request-rate 1 \
        --max-concurrency 1 \
        --save-results \
        --result-filename "$OUTPUT_DIR/02_latency.json" \
        2>&1 | tee -a "$LOG_FILE" || Log "  ⚠️  Failed"
    
    Log ""
    
    # Concurrency
    Log "[3/4] Concurrency (10 concurrent)"
    vllm bench serve \
        --backend vllm \
        --base-url "$ENDPOINT_URL" \
        --model "$MODEL_NAME" \
        --endpoint /v1/completions \
        --dataset-name random \
        --num-prompts 100 \
        --random-input-len 512 \
        --random-output-len 128 \
        --request-rate inf \
        --max-concurrency 10 \
        --save-results \
        --result-filename "$OUTPUT_DIR/03_concurrency.json" \
        2>&1 | tee -a "$LOG_FILE" || Log "  ⚠️  Failed"
    
    Log ""
    
    # Long context
    Log "[4/4] Long context (32K tokens)"
    vllm bench serve \
        --backend vllm \
        --base-url "$ENDPOINT_URL" \
        --model "$MODEL_NAME" \
        --endpoint /v1/completions \
        --dataset-name random \
        --num-prompts 10 \
        --random-input-len 32000 \
        --random-output-len 1000 \
        --request-rate 1 \
        --max-concurrency 1 \
        --save-results \
        --result-filename "$OUTPUT_DIR/04_longcontext.json" \
        2>&1 | tee -a "$LOG_FILE" || Log "  ⚠️  Failed (32K may exceed model limit)"
    
    Log ""
fi

# ============================================================================
# PART 2: Quality Benchmarks
# ============================================================================

Log "=========================================="
Log "PART 2: Quality Benchmarks"
Log "=========================================="
Log ""

if ! command -v lm_eval >/dev/null 2>&1; then
    Log "⚠️  lm_eval not installed, skipping quality tests"
    Log "   Install: pip install lm-evaluation-harness"
    Log ""
else
    # Build model args
    MODEL_ARGS="model=${MODEL_NAME},base_url=${ENDPOINT_URL}/v1,tokenizer_backend=huggingface,num_concurrent=4,max_retries=3"
    if [[ -n "$API_KEY" ]]; then
        MODEL_ARGS="${MODEL_ARGS},api_key=${API_KEY}"
    fi
    
    # MMLU
    Log "[5/6] MMLU (30-60 min)"
    lm_eval \
        --model local-completions \
        --tasks mmlu \
        --model_args "$MODEL_ARGS" \
        --batch_size auto \
        --output_path "$OUTPUT_DIR/05_mmlu" \
        --log_samples \
        2>&1 | tee -a "$LOG_FILE" || Log "  ⚠️  Failed"
    
    Log ""
    
    # HumanEval
    Log "[6/6] HumanEval (10-20 min)"
    lm_eval \
        --model local-completions \
        --tasks humaneval \
        --model_args "$MODEL_ARGS" \
        --batch_size auto \
        --output_path "$OUTPUT_DIR/06_humaneval" \
        --log_samples \
        2>&1 | tee -a "$LOG_FILE" || Log "  ⚠️  Failed"
    
    Log ""
fi

# ============================================================================
# SUMMARY
# ============================================================================

Log "=========================================="
Log "BENCHMARK COMPLETE"
Log "=========================================="
Log ""

# Create summary
cat > "$OUTPUT_DIR/summary.md" <<EOF
# Benchmark Results

**Endpoint:** $ENDPOINT_URL  
**Model:** $MODEL_NAME  
**Date:** $(date)

## Results

- \`01_throughput.json\` - Max throughput
- \`02_latency.json\` - Latency (light load)
- \`03_concurrency.json\` - Concurrency (10 concurrent)
- \`04_longcontext.json\` - Long context (32K)
- \`05_mmlu/\` - MMLU accuracy
- \`06_humaneval/\` - HumanEval coding

## Quick Stats

\`\`\`bash
# Throughput (tok/s)
jq '.throughput' $OUTPUT_DIR/01_throughput.json

# Latency (ms)
jq '.mean_ttft_ms' $OUTPUT_DIR/02_latency.json

# MMLU accuracy
jq '.results.mmlu.acc' $OUTPUT_DIR/05_mmlu/results.json

# HumanEval pass@1
jq '.results.humaneval.pass@1' $OUTPUT_DIR/06_humaneval/results.json
\`\`\`
EOF

Log "Results: $OUTPUT_DIR"
Log "Summary: $OUTPUT_DIR/summary.md"
Log ""
