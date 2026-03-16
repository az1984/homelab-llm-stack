#!/usr/bin/env bash
# Real-world benchmark: Screenshot to structured JSON
# Tests structured output capabilities

set -euo pipefail

VLLM_ENDPOINT="${1:-http://192.168.2.42:8000}"
SCREENSHOT_PATH="${2:-}"
OUTPUT_DIR="${3:-./vision_results}"

if [[ -z "$SCREENSHOT_PATH" ]]; then
    echo "Usage: $0 <vllm_endpoint> <screenshot_path> [output_dir]"
    echo "Example: $0 http://192.168.2.42:8000 ./dashboard.png"
    exit 1
fi

mkdir -p "$OUTPUT_DIR"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# Encode image
IMG_B64=$(base64 -i "$SCREENSHOT_PATH")

# JSON schema for structured output
SCHEMA='{
  "type": "object",
  "properties": {
    "screen_type": {
      "type": "string",
      "enum": ["dashboard", "form", "table", "code", "terminal", "webpage", "other"]
    },
    "elements": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "type": {"type": "string"},
          "label": {"type": "string"},
          "value": {"type": "string"},
          "position": {"type": "string"}
        },
        "required": ["type", "label"]
      }
    },
    "actions_available": {
      "type": "array",
      "items": {"type": "string"}
    },
    "text_content": {
      "type": "string",
      "description": "All readable text in the screenshot"
    }
  },
  "required": ["screen_type", "elements", "text_content"]
}'

SYSTEM_PROMPT="Extract all UI elements, text, and interactive components from this screenshot. Return structured JSON following the provided schema."

echo "Analyzing screenshot: $SCREENSHOT_PATH"
START_TIME=$(date +%s%N)

# Call vLLM with guided JSON decoding
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
          "text": "Analyze this screenshot and extract all elements as structured JSON."
        }
      ]
    }
  ],
  "temperature": 0.1,
  "max_tokens": 8192,
  "guided_json": $SCHEMA
}
PAYLOAD
)

END_TIME=$(date +%s%N)
DURATION_MS=$(((END_TIME - START_TIME) / 1000000))

# Save results
echo "$RESPONSE" | jq '.' > "$OUTPUT_DIR/screenshot_analysis_${TIMESTAMP}.json"

# Extract structured content
STRUCTURED=$(echo "$RESPONSE" | jq -r '.choices[0].message.content')
echo "$STRUCTURED" | jq '.' > "$OUTPUT_DIR/structured_output_${TIMESTAMP}.json"

# Metrics
TOKENS=$(echo "$RESPONSE" | jq -r '.usage.total_tokens')
TTFT=$(echo "$RESPONSE" | jq -r '.metrics.time_to_first_token_ms // 0')

echo ""
echo "=== Screenshot Analysis Complete ==="
echo "Time: ${DURATION_MS}ms"
echo "TTFT: ${TTFT}ms"
echo "Tokens: $TOKENS"
echo ""
echo "Results:"
echo "  Raw response: $OUTPUT_DIR/screenshot_analysis_${TIMESTAMP}.json"
echo "  Structured output: $OUTPUT_DIR/structured_output_${TIMESTAMP}.json"
echo ""
echo "Preview:"
jq '.' "$OUTPUT_DIR/structured_output_${TIMESTAMP}.json"
