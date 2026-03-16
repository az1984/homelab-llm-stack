#!/usr/bin/env bash
# Generate Claude prompts from organized folder structure
# Each subfolder = one discrete task (all images in folder are related)
#
# Usage:
#   ./generate_claude_prompts.sh groceries ./receipts
#   ./generate_claude_prompts.sh jamf ./screenshots

set -euo pipefail

TASK_TYPE="${1:-}"
DATA_DIR="${2:-}"
OUTPUT_DIR="./claude_prompts_$(date +%Y%m%d_%H%M%S)"

if [[ -z "$TASK_TYPE" ]] || [[ -z "$DATA_DIR" ]]; then
    cat <<'USAGE'
Usage: ./generate_claude_prompts.sh <task_type> <data_dir>

Task types:
  groceries    - Grocery receipt extraction
  jamf         - Jamf Pro UI extraction  
  logic_errors - Logic App error diagnosis
  pdf_receipts - PDF receipt extraction

Data structure:
  data-dir/
    purchase_001/    # All images for ONE purchase
      receipt_1.jpg  # Full receipt
      receipt_2.jpg  # Close-up of same receipt
    purchase_002/
      receipt.jpg

Example:
  ./generate_claude_prompts.sh groceries ./my_receipts
USAGE
    exit 1
fi

mkdir -p "$OUTPUT_DIR"

# Define prompts for each task type
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
        echo "Valid types: groceries, jamf, logic_errors, pdf_receipts"
        exit 1
        ;;
esac

echo "Generating Claude prompts for: $TASK_NAME"
echo "Data directory: $DATA_DIR"
echo ""

# Find all subdirectories (each is one discrete task)
mapfile -t SUBDIRS < <(find "$DATA_DIR" -mindepth 1 -maxdepth 1 -type d | sort)

if [[ ${#SUBDIRS[@]} -eq 0 ]]; then
    echo "ERROR: No subdirectories found in $DATA_DIR"
    echo ""
    echo "Expected structure:"
    echo "  $DATA_DIR/"
    echo "    item_001/    # One discrete task"
    echo "      image1.jpg"
    echo "      image2.jpg"
    echo "    item_002/"
    echo "      image.jpg"
    exit 1
fi

echo "Found ${#SUBDIRS[@]} items to process"
echo ""

# Generate prompts
for idx in "${!SUBDIRS[@]}"; do
    subdir="${SUBDIRS[$idx]}"
    item_num=$((idx + 1))
    item_name=$(basename "$subdir")
    
    echo "[$item_num/${#SUBDIRS[@]}] Processing: $item_name"
    
    # Find all images in this subdirectory
    mapfile -t images < <(find "$subdir" -type f \( -iname "*.jpg" -o -iname "*.jpeg" -o -iname "*.png" -o -iname "*.pdf" \) | sort)
    
    if [[ ${#images[@]} -eq 0 ]]; then
        echo "  WARNING: No images/PDFs found in $subdir"
        continue
    fi
    
    echo "  Found ${#images[@]} file(s)"
    
    # Create prompt file
    prompt_file="$OUTPUT_DIR/$(printf '%03d' $item_num)_${item_name}.txt"
    
    cat > "$prompt_file" <<EOF
========================================
ITEM $item_num: $item_name
========================================

STEP 1: Upload these ${#images[@]} file(s) to Claude chat:
EOF
    
    for img in "${images[@]}"; do
        echo "  - $img" >> "$prompt_file"
    done
    
    cat >> "$prompt_file" <<EOF

STEP 2: Paste this prompt:

---BEGIN PROMPT---
$PROMPT_TEMPLATE
---END PROMPT---

STEP 3: Save Claude's response to:
  claude_outputs/${item_name}.txt

---

NOTE: All files above are for the SAME item. 
If there are multiple images (different angles, close-ups), 
reconcile all information into a SINGLE response.

========================================
EOF
    
    echo "  ✓ Created: $prompt_file"
done

# Create master batch file
cat > "$OUTPUT_DIR/000_BATCH_ALL.txt" <<EOF
========================================
BATCH PROCESSING: $TASK_NAME
========================================

Total items: ${#SUBDIRS[@]}
Generated: $(date)

INSTRUCTIONS:
1. Open each numbered file (001_*.txt, 002_*.txt, etc.)
2. Upload the files listed in STEP 1
3. Paste the prompt from STEP 2
4. Save Claude's response per STEP 3
5. Repeat for next file

FILES TO PROCESS:
EOF

for idx in "${!SUBDIRS[@]}"; do
    item_num=$((idx + 1))
    item_name=$(basename "${SUBDIRS[$idx]}")
    printf "  %03d_%s.txt\n" "$item_num" "$item_name" >> "$OUTPUT_DIR/000_BATCH_ALL.txt"
done

cat >> "$OUTPUT_DIR/000_BATCH_ALL.txt" <<EOF

OUTPUT STRUCTURE:
Create this directory to save responses:

  mkdir -p claude_outputs

Then save each response as:
EOF

for subdir in "${SUBDIRS[@]}"; do
    echo "  claude_outputs/$(basename "$subdir").txt" >> "$OUTPUT_DIR/000_BATCH_ALL.txt"
done

cat >> "$OUTPUT_DIR/000_BATCH_ALL.txt" <<EOF

========================================

TIP: You can process multiple items in ONE Claude conversation.
Just upload → paste → save → repeat for next item.

========================================
EOF

echo ""
echo "=========================================="
echo "PROMPT GENERATION COMPLETE"
echo "=========================================="
echo "Generated: ${#SUBDIRS[@]} prompt files"
echo "Location: $OUTPUT_DIR"
echo ""
echo "Next steps:"
echo "  1. cat $OUTPUT_DIR/000_BATCH_ALL.txt"
echo "  2. cat $OUTPUT_DIR/001_*.txt"
echo "  3. Upload files + paste prompt to Claude"
echo "  4. mkdir -p claude_outputs"
echo "  5. Save responses to claude_outputs/"
echo ""
