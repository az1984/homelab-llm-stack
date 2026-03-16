#!/usr/bin/env bash
# Real-world benchmark: PDF to structured markdown
# Tests Qwen3-VL-235B's document understanding

set -euo pipefail

VLLM_ENDPOINT="${1:-http://192.168.2.42:8000}"
PDF_PATH="${2:-}"
OUTPUT_DIR="${3:-./vision_results}"

if [[ -z "$PDF_PATH" ]]; then
    echo "Usage: $0 <vllm_endpoint> <pdf_path> [output_dir]"
    echo "Example: $0 http://192.168.2.42:8000 ./test.pdf"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Convert PDF to images (one image per page)
echo "Converting PDF to images..."
pdftoppm -png "$PDF_PATH" "$OUTPUT_DIR/page"

# Count pages
PAGE_COUNT=$(ls -1 "$OUTPUT_DIR"/page-*.png 2>/dev/null | wc -l)
echo "Processing $PAGE_COUNT pages..."

# Prompt template for document transcription
SYSTEM_PROMPT="You are an expert document transcriber. Convert the document image to clean, well-formatted markdown. Preserve structure (headings, lists, tables), but improve formatting for readability. Include ALL text content."

cat > "$OUTPUT_DIR/benchmark_${TIMESTAMP}.jsonl" <<EOF
EOF

START_TIME=$(date +%s)

for page_img in "$OUTPUT_DIR"/page-*.png; do
    PAGE_NUM=$(basename "$page_img" | sed 's/page-//;s/.png//')
    echo "Processing page $PAGE_NUM..."
    
    # Encode image as base64
    IMG_B64=$(base64 -i "$page_img")
    
    # Call vLLM API
    RESPONSE=$(curl -s -X POST "${VLLM_ENDPOINT}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d @- <<PAYLOAD
{
  "model": "Qwen3-VL-235B",
  "messages": [
    {
      "role": "system",
      "content": "$SYSTEM_PROMPT"
    },
    {
      "role": "user",
      "content": [
        {
          "type": "image_url",
          "image_url": {
            "url": "data:image/png;base64,$IMG_B64"
          }
        },
        {
          "type": "text",
          "text": "Transcribe this document page to markdown. Preserve all structure and content."
        }
      ]
    }
  ],
  "temperature": 0.1,
  "max_tokens": 4096
}
PAYLOAD
)
    
    # Extract result
    CONTENT=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
    TOKENS=$(echo "$RESPONSE" | jq -r '.usage.total_tokens')
    
    # Save to markdown
    cat >> "$OUTPUT_DIR/transcription_${TIMESTAMP}.md" <<PAGEMD

---
## Page $PAGE_NUM

$CONTENT

PAGEMD
    
    # Log metrics
    echo "{\"page\": $PAGE_NUM, \"tokens\": $TOKENS, \"timestamp\": $(date +%s)}" >> "$OUTPUT_DIR/benchmark_${TIMESTAMP}.jsonl"
done

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))

echo ""
echo "=== PDF Transcription Benchmark Complete ==="
echo "Pages processed: $PAGE_COUNT"
echo "Total time: ${DURATION}s"
echo "Avg time per page: $((DURATION / PAGE_COUNT))s"
echo ""
echo "Results:"
echo "  Transcription: $OUTPUT_DIR/transcription_${TIMESTAMP}.md"
echo "  Metrics: $OUTPUT_DIR/benchmark_${TIMESTAMP}.jsonl"
