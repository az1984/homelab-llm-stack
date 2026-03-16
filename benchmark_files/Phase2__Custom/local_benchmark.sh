#!/usr/bin/env bash
# Local vLLM benchmark runner - batch image processing
# Each subfolder = one discrete task (all images sent together in ONE API call)
#
# Usage:
#   ./local_benchmark.sh groceries ./receipts http://192.168.2.42:8000

set -euo pipefail

TASK_TYPE="${1:-}"
DATA_DIR="${2:-}"
VLLM_ENDPOINT="${3:-http://192.168.2.42:8000}"
MODEL_NAME="${4:-chat-heavy}"
OUTPUT_DIR="./vllm_outputs_$(date +%Y%m%d_%H%M%S)"
LOG_FILE="${OUTPUT_DIR}/benchmark.log"

if [[ -z "$TASK_TYPE" ]] || [[ -z "$DATA_DIR" ]]; then
    cat <<'USAGE'
Usage: ./local_benchmark.sh <task_type> <data_dir> [vllm_endpoint] [model_name]

Task types:
  groceries    - Grocery receipt extraction
  jamf         - Jamf Pro UI extraction  
  logic_errors - Logic App error diagnosis
  pdf_receipts - PDF receipt extraction

Arguments:
  task_type      - Type of task (see above)
  data_dir       - Directory containing subfolders (one per item)
  vllm_endpoint  - vLLM API URL (default: http://192.168.2.42:8000)
  model_name     - Model name (default: chat-heavy)

Data structure:
  data-dir/
    item_001/          # All images for ONE task
      image1.jpg       # Sent together in ONE API call
      image2.jpg
    item_002/
      image.jpg

Example:
  ./local_benchmark.sh groceries ./my_receipts
  ./local_benchmark.sh jamf ./screenshots http://192.168.2.43:8001
USAGE
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

Log() {
    echo "[$(date +'%H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# Define prompts for each task type (same as Claude prompts)
case "$TASK_TYPE" in
    groceries)
        TASK_NAME="Grocery Receipt Extraction"
        PROMPT_TEMPLATE='Extract ALL information from these grocery receipt image(s) and format as:

## Receipt Summary
- Store: [name]
- Date: YYYY-MM-DD
- Time: HH:MM (if visible)
- Total: $X.XX

## Items Purchased
| Item | Quantity | Unit Price | Total |
|------|----------|------------|-------|
| ... | ... | ... | ... |

## CSV Export
```csv
item,quantity,unit_price,total
...
```

**Instructions:**
- If multiple images show the SAME receipt (different angles/close-ups), reconcile them into ONE list
- Extract EVERY item with exact pricing
- Include taxes, discounts, subtotals if shown
- Be precise with numbers (match receipt exactly)'
        ;;
    
    jamf)
        TASK_NAME="Jamf Pro Device Information Extraction"
        PROMPT_TEMPLATE='Extract device management information from these Jamf Pro screenshot(s) and format as JSON:

```json
{
  "device_name": "string or null",
  "serial_number": "string or null",
  "asset_tag": "string or null",
  "management_status": "string or null",
  "last_check_in": "ISO8601 or null",
  "os_version": "string or null",
  "installed_profiles": ["list", "or", "null"],
  "pending_commands": ["list", "or", "null"],
  "hardware_info": {
    "model": "string or null",
    "storage": "string or null",
    "memory": "string or null"
  },
  "user_info": {
    "assigned_user": "string or null",
    "email": "string or null"
  }
}
```

**Instructions:**
- If multiple screenshots show DIFFERENT views of the SAME device/policy, merge information
- Extract ONLY visible text from the UI
- Use null for any fields not visible
- Dates in ISO8601 format (YYYY-MM-DDTHH:MM:SSZ)
- Return valid JSON only'
        ;;
    
    logic_errors)
        TASK_NAME="Logic App Error Diagnosis"
        PROMPT_TEMPLATE='Analyze these Azure Logic App Designer error screenshot(s) and provide:

## Error Summary
**What Failed:** [1-2 sentence summary]

## Error Details
- **Error Type:** [e.g., InvalidTemplate, Timeout, AuthenticationFailed]
- **Component:** [which connector/action failed]
- **Error Message:** [exact error text from screenshot]

## Root Cause Analysis
[Detailed explanation of the most likely cause]

## Fix Steps
1. [First concrete step]
2. [Second step]
3. [Continue numbered steps]
4. [Final verification step]

## Prevention
[How to avoid this error in future]

**Instructions:**
- If multiple screenshots show the SAME error from different angles, synthesize into ONE analysis
- Be specific with connector names and configuration details visible
- Provide actionable fix steps, not generic advice
- Reference specific UI elements visible in screenshots'
        ;;
    
    pdf_receipts)
        TASK_NAME="PDF Receipt Data Extraction"
        PROMPT_TEMPLATE='Extract purchase information from this PDF receipt and format as JSON:

```json
{
  "vendor": "store/company name",
  "order_number": "string or null",
  "date": "YYYY-MM-DD",
  "items": [
    {
      "description": "item name/description",
      "quantity": 1,
      "unit_price": 0.00,
      "total": 0.00
    }
  ],
  "subtotal": 0.00,
  "tax": 0.00,
  "shipping": 0.00,
  "total": 0.00,
  "payment_method": "last 4 digits or null"
}
```

**Instructions:**
- Extract ALL items from the receipt
- Include exact prices (match receipt)
- If receipt spans multiple pages, aggregate all items
- Return valid JSON only'
        ;;
    
    *)
        echo "Unknown task type: $TASK_TYPE"
        exit 1
        ;;
esac

# Convert image to base64
ImageToBase64() {
    local img_path="$1"
    local mime_type
    
    case "${img_path,,}" in
        *.jpg|*.jpeg) mime_type="image/jpeg" ;;
        *.png) mime_type="image/png" ;;
        *.pdf) mime_type="application/pdf" ;;
        *) 
            Log "WARNING: Unknown file type: $img_path"
            mime_type="image/jpeg"
            ;;
    esac
    
    local base64_data
    base64_data=$(base64 -w 0 "$img_path")
    
    echo "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:${mime_type};base64,${base64_data}\"}}"
}

# Call vLLM API with multiple images from ONE folder
CallVLLM() {
    local prompt="$1"
    local output_file="$2"
    shift 2
    local images=("$@")
    
    # Build content array: [text, image1, image2, ...]
    local content="["
    
    # Add text prompt
    content+="{\"type\":\"text\",\"text\":$(jq -R -s '.' <<< "$prompt")}"
    
    # Add all images from this folder
    for img in "${images[@]}"; do
        Log "  Encoding: $(basename "$img")"
        local img_json
        img_json=$(ImageToBase64 "$img")
        content+=",${img_json}"
    done
    
    content+="]"
    
    # Build request
    local request_json
    request_json=$(jq -n \
        --arg model "$MODEL_NAME" \
        --argjson content "$content" \
        '{
            model: $model,
            messages: [{
                role: "user",
                content: $content
            }],
            max_tokens: 4096,
            temperature: 0.1
        }')
    
    Log "  Sending request to vLLM (${#images[@]} images in one call)..."
    local start_time
    start_time=$(date +%s)
    
    # Call API
    local response
    response=$(curl -s -X POST "${VLLM_ENDPOINT}/v1/chat/completions" \
        -H "Content-Type: application/json" \
        -d "$request_json")
    
    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))
    
    # Extract response content
    local content_text
    content_text=$(echo "$response" | jq -r '.choices[0].message.content // empty')
    
    if [[ -z "$content_text" ]]; then
        Log "  ERROR: Empty response from vLLM"
        echo "$response" | jq '.' > "${output_file}.error.json"
        return 1
    fi
    
    # Save response
    echo "$content_text" > "$output_file"
    
    # Extract stats
    local tokens_used
    tokens_used=$(echo "$response" | jq -r '.usage.total_tokens // 0')
    
    Log "  ✓ Response saved (${duration}s, ${tokens_used} tokens)"
    
    return 0
}

# Main processing
Log "=========================================="
Log "vLLM Benchmark: $TASK_NAME"
Log "=========================================="
Log "Data directory: $DATA_DIR"
Log "vLLM endpoint: $VLLM_ENDPOINT"
Log "Model: $MODEL_NAME"
Log "Output: $OUTPUT_DIR"
Log ""

# Find all subdirectories (each is one discrete task)
mapfile -t SUBDIRS < <(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [[ ${#SUBDIRS[@]} -eq 0 ]]; then
    Log "ERROR: No subdirectories found in $DATA_DIR"
    Log ""
    Log "Expected structure:"
    Log "  $DATA_DIR/"
    Log "    item_001/    # One discrete task"
    Log "      image1.jpg"
    Log "      image2.jpg"
    Log "    item_002/"
    Log "      image.jpg"
    exit 1
fi

Log "Found ${#SUBDIRS[@]} items to process"
Log ""

# Process each item
total_items=${#SUBDIRS[@]}
success_count=0
error_count=0

for idx in "${!SUBDIRS[@]}"; do
    subdir="${SUBDIRS[$idx]}"
    item_num=$((idx + 1))
    item_name=$(basename "$subdir")
    
    Log "=========================================="
    Log "[$item_num/$total_items] Processing: $item_name"
    Log "=========================================="
    
    # Find all images in this subdirectory
    mapfile -t images < <(find "$subdir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.pdf" \) | sort)
    
    if [[ ${#images[@]} -eq 0 ]]; then
        Log "  WARNING: No images found in $subdir"
        Log "  Skipping..."
        Log ""
        continue
    fi
    
    Log "  Found ${#images[@]} image(s)"
    
    # Output file
    output_file="${OUTPUT_DIR}/${item_name}.txt"
    
    # Call vLLM with ALL images from this folder (one API call)
    if CallVLLM "$PROMPT_TEMPLATE" "$output_file" "${images[@]}"; then
        ((success_count++))
    else
        ((error_count++))
    fi
    
    Log ""
    
    # Rate limiting - avoid overwhelming the API
    if [[ $item_num -lt $total_items ]]; then
        sleep 2
    fi
done

# Summary
Log "=========================================="
Log "BENCHMARK COMPLETE"
Log "=========================================="
Log "Total items: $total_items"
Log "Successful: $success_count"
Log "Errors: $error_count"
Log ""
Log "Results saved to: $OUTPUT_DIR"
Log ""

# Create summary file
cat > "${OUTPUT_DIR}/summary.txt" <<EOF
vLLM Benchmark Summary
======================

Task: $TASK_NAME
Date: $(date)

Endpoint: $VLLM_ENDPOINT
Model: $MODEL_NAME
Data: $DATA_DIR

Results:
  Total items: $total_items
  Successful: $success_count
  Errors: $error_count

Output files:
$(for subdir in "${SUBDIRS[@]}"; do
    item_name=$(basename "$subdir")
    if [[ -f "${OUTPUT_DIR}/${item_name}.txt" ]]; then
        echo "  ✓ ${item_name}.txt"
    else
        echo "  ✗ ${item_name}.txt (failed)"
    fi
done)

Next steps:
1. Review outputs in: $OUTPUT_DIR
2. Compare with Claude outputs (if running parallel test)
3. Check accuracy for each item

EOF

Log "Summary written to: ${OUTPUT_DIR}/summary.txt"
Log ""

if [[ $error_count -gt 0 ]]; then
    Log "⚠️  Some items failed - check .error.json files"
    exit 1
fi

Log "✅ All items processed successfully"
