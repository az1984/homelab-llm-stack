#!/usr/bin/env bash
# Compare benchmark results between two stacks

set -euo pipefail

CURRENT_DIR="${1:-./results/current}"
NEW_DIR="${2:-./results/new}"
OUTPUT_FILE="./benchmark_comparison_$(date +%Y%m%d_%H%M%S).md"

if [[ ! -d "$CURRENT_DIR" ]] || [[ ! -d "$NEW_DIR" ]]; then
    echo "Usage: $0 <current_results_dir> <new_results_dir>"
    exit 1
fi

echo "Comparing benchmarks:"
echo "  Current: $CURRENT_DIR"
echo "  New:     $NEW_DIR"
echo "  Output:  $OUTPUT_FILE"

cat > "$OUTPUT_FILE" <<'EOF'
# Benchmark Comparison: Current vs New Stack

## Executive Summary

EOF

# Extract key metrics using jq
echo "## Performance Metrics (vLLM)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "### Throughput Comparison" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "| Benchmark | Current | New | Change |" >> "$OUTPUT_FILE"
echo "|-----------|---------|-----|--------|" >> "$OUTPUT_FILE"

# Helper function to extract metric from JSON
extract_metric() {
    local file="$1"
    local metric="$2"
    if [[ -f "$file" ]]; then
        jq -r ".$metric // \"N/A\"" "$file" 2>/dev/null || echo "N/A"
    else
        echo "N/A"
    fi
}

# Compare throughput
for bench in "01_heavy_throughput" "04_coder_throughput" "05_quick_throughput" "06_vision_throughput"; do
    current_val=$(extract_metric "$CURRENT_DIR/${bench}.json" ".throughput")
    new_val=$(extract_metric "$NEW_DIR/${bench}.json" ".throughput")
    
    # Handle vision benchmark (only exists in current stack)
    if [[ "$bench" == "06_vision_throughput" ]] && [[ "$new_val" == "N/A" ]]; then
        new_val="N/A (separate VL-8B)"
        change="Architecture change"
    elif [[ "$current_val" != "N/A" ]] && [[ "$new_val" != "N/A" ]]; then
        change=$(awk "BEGIN {printf \"%.1f%%\", (($new_val - $current_val) / $current_val) * 100}")
    else
        change="N/A"
    fi
    
    echo "| $bench | $current_val | $new_val | $change |" >> "$OUTPUT_FILE"
done

echo "" >> "$OUTPUT_FILE"
echo "### Latency Comparison (TTFT - Time to First Token)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "| Benchmark | Current (ms) | New (ms) | Change |" >> "$OUTPUT_FILE"
echo "|-----------|--------------|----------|--------|" >> "$OUTPUT_FILE"

for bench in "02_heavy_latency" "06_heavy_longcontext"; do
    current_val=$(extract_metric "$CURRENT_DIR/${bench}.json" ".mean_ttft_ms")
    new_val=$(extract_metric "$NEW_DIR/${bench}.json" ".mean_ttft_ms")
    
    if [[ "$current_val" != "N/A" ]] && [[ "$new_val" != "N/A" ]]; then
        change=$(awk "BEGIN {printf \"%.1f%%\", (($new_val - $current_val) / $current_val) * 100}")
    else
        change="N/A"
    fi
    
    echo "| $bench | $current_val | $new_val | $change |" >> "$OUTPUT_FILE"
done

echo "" >> "$OUTPUT_FILE"
echo "## Quality Metrics (lm-evaluation-harness)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "| Task | Current | New | Change |" >> "$OUTPUT_FILE"
echo "|------|---------|-----|--------|" >> "$OUTPUT_FILE"

# Compare MMLU
current_mmlu=$(extract_metric "$CURRENT_DIR/07_heavy_mmlu/results.json" ".results.mmlu.acc")
new_mmlu=$(extract_metric "$NEW_DIR/07_heavy_mmlu/results.json" ".results.mmlu.acc")

if [[ "$current_mmlu" != "N/A" ]] && [[ "$new_mmlu" != "N/A" ]]; then
    change=$(awk "BEGIN {printf \"%.2f%%\", (($new_mmlu - $current_mmlu) / $current_mmlu) * 100}")
else
    change="N/A"
fi

echo "| MMLU (accuracy) | $current_mmlu | $new_mmlu | $change |" >> "$OUTPUT_FILE"

# Compare HumanEval
current_humaneval=$(extract_metric "$CURRENT_DIR/08_coder_humaneval/results.json" ".results.humaneval.pass@1")
new_humaneval=$(extract_metric "$NEW_DIR/08_coder_humaneval/results.json" ".results.humaneval.pass@1")

if [[ "$current_humaneval" != "N/A" ]] && [[ "$new_humaneval" != "N/A" ]]; then
    change=$(awk "BEGIN {printf \"%.2f%%\", (($new_humaneval - $current_humaneval) / $current_humaneval) * 100}")
else
    change="N/A"
fi

echo "| HumanEval (pass@1) | $current_humaneval | $new_humaneval | $change |" >> "$OUTPUT_FILE"

echo "" >> "$OUTPUT_FILE"
echo "## Detailed Analysis" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "### Memory Efficiency" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "**Current Stack:**" >> "$OUTPUT_FILE"
echo "- Qwen3-235B: ~234GB (2 nodes)" >> "$OUTPUT_FILE"
echo "- Qwen3-Coder-80B: ~40GB" >> "$OUTPUT_FILE"
echo "- Qwen3-Next-30B: ~30GB" >> "$OUTPUT_FILE"
echo "- Total: ~304GB active" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "**New Stack:**" >> "$OUTPUT_FILE"
echo "- Qwen3.5-122B × 2: ~122GB (Node 2)" >> "$OUTPUT_FILE"
echo "- Qwen3.5-35B × 3: ~54GB (Nodes 1, 3, 4)" >> "$OUTPUT_FILE"
echo "- Total: ~176GB active" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "**Savings:** ~128GB (42% reduction)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "### Context Window" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "| Model | Current | New | Improvement |" >> "$OUTPUT_FILE"
echo "|-------|---------|-----|-------------|" >> "$OUTPUT_FILE"
echo "| Heavy | 200K (2 slots) | 262K | +62K (+31%) |" >> "$OUTPUT_FILE"
echo "| Coder | 32K | 262K | +230K (+719%) |" >> "$OUTPUT_FILE"
echo "| Quick | 32K | 262K | +230K (+719%) |" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "**Note:** Current stack (Qwen3-VL-235B) supports max 2 concurrent 200K streams" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "### Vision Architecture" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "**Current Stack:**" >> "$OUTPUT_FILE"
echo "- Qwen3-VL-235B: Integrated vision + language model" >> "$OUTPUT_FILE"
echo "- Vision capability built into heavy model" >> "$OUTPUT_FILE"
echo "- 2 concurrent 200K streams (vision + text)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "**New Stack:**" >> "$OUTPUT_FILE"
echo "- Qwen3.5-122B: Pure language model (no vision)" >> "$OUTPUT_FILE"
echo "- Qwen3-VL-8B: Dedicated vision model (16GB)" >> "$OUTPUT_FILE"
echo "- Architectural split: heavy for reasoning, VL-8B for vision" >> "$OUTPUT_FILE"
echo "- 2x VL-8B instances for parallel vision tasks" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "**Implication:** Vision workloads move from 235B to dedicated VL-8B (faster, lighter)" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "## Recommendations" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "Based on benchmark results:" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "- [ ] Review performance delta (throughput, latency)" >> "$OUTPUT_FILE"
echo "- [ ] Review quality delta (MMLU, HumanEval)" >> "$OUTPUT_FILE"
echo "- [ ] Test real-world workloads (OpenWebUI, OpenTerminal)" >> "$OUTPUT_FILE"
echo "- [ ] Verify memory savings match expectations" >> "$OUTPUT_FILE"
echo "- [ ] If acceptable, proceed with migration" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"

echo "---" >> "$OUTPUT_FILE"
echo "" >> "$OUTPUT_FILE"
echo "*Generated: $(date)*" >> "$OUTPUT_FILE"

echo ""
echo "Comparison complete! Results written to:"
echo "  $OUTPUT_FILE"
echo ""
echo "Next steps:"
echo "  1. Review the comparison report"
echo "  2. Test OpenWebUI and OpenTerminal with both stacks"
echo "  3. Make migration decision"
