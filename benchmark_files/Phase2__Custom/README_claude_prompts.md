# Claude Prompt Generator
## Batch Image/Document Processing for Manual Claude Testing

This script generates ready-to-paste prompts for testing Claude's vision capabilities on batches of receipts, screenshots, or documents.

## Overview

**Problem:** You have 50 grocery receipts and want to test if Claude can extract data as accurately as a local vLLM model.

**Solution:** This script organizes your data into numbered prompt files that you copy-paste into Claude chat, one at a time.

## Folder Structure

Each subfolder = one discrete task. All images in a subfolder are related (same receipt from different angles, same error from multiple screenshots, etc.).

```
your_data/
  purchase_001/           # First discrete purchase
    receipt_front.jpg     # Full receipt
    receipt_closeup.jpg   # Close-up of same receipt
  purchase_002/           # Second discrete purchase  
    receipt.jpg
  purchase_003/           # Third discrete purchase
    img1.jpg              # Maybe front
    img2.jpg              # Maybe back
    img3.jpg              # Maybe close-up
```

## Usage

```bash
./generate_claude_prompts.sh <task_type> <data_directory>
```

### Task Types

1. **groceries** - Extract items, prices, totals from receipts
2. **jamf** - Extract device info from Jamf Pro screenshots (JSON)
3. **logic_errors** - Diagnose Azure Logic App errors
4. **pdf_receipts** - Extract purchase data from PDF receipts (JSON)

### Examples

```bash
# Grocery receipt batch (50 purchases)
./generate_claude_prompts.sh groceries ~/Desktop/receipts_batch_jan2026

# Jamf device screenshots (20 devices)
./generate_claude_prompts.sh jamf ~/Desktop/jamf_screenshots

# Logic App errors (10 errors)
./generate_claude_prompts.sh logic_errors ~/Desktop/logic_errors
```

## Output

The script generates:

```
claude_prompts_TIMESTAMP/
  000_BATCH_ALL.txt       # Master instructions
  001_purchase_001.txt    # First item prompt
  002_purchase_002.txt    # Second item prompt
  003_purchase_003.txt    # Third item prompt
  ...
```

Each numbered file contains:
- **STEP 1:** List of files to upload
- **STEP 2:** Prompt to paste
- **STEP 3:** Where to save Claude's response

## Workflow

### 1. Generate Prompts

```bash
./generate_claude_prompts.sh groceries ./my_receipts
# Output: claude_prompts_20260315_120000/
```

### 2. Read Master Instructions

```bash
cat claude_prompts_20260315_120000/000_BATCH_ALL.txt
```

### 3. Process Each Item

Open `001_purchase_001.txt`:
1. Upload the 2 images listed
2. Paste the prompt (between `---BEGIN PROMPT---` and `---END PROMPT---`)
3. Save Claude's response to `claude_outputs/purchase_001.txt`

Repeat for `002_*.txt`, `003_*.txt`, etc.

### 4. Save Responses

```bash
mkdir -p claude_outputs
# Then save each Claude response as:
#   claude_outputs/purchase_001.txt
#   claude_outputs/purchase_002.txt
#   ...
```

## Batch Processing Tip

You can process multiple items in **one Claude conversation**:

1. Upload images for item 1 → paste prompt 1 → save response 1
2. Upload images for item 2 → paste prompt 2 → save response 2  
3. Upload images for item 3 → paste prompt 3 → save response 3
4. Continue...

No need to start a new chat for each item!

## Example: Grocery Receipt

**Your folder:**
```
receipts/
  walmart_jan15/
    receipt.jpg
    closeup_produce.jpg
  target_jan16/
    receipt_front.jpg
```

**Generated prompt (001_walmart_jan15.txt):**
```
STEP 1: Upload these 2 file(s) to Claude chat:
  - receipts/walmart_jan15/receipt.jpg
  - receipts/walmart_jan15/closeup_produce.jpg

STEP 2: Paste this prompt:

---BEGIN PROMPT---
Extract ALL information from these grocery receipt image(s) and format as:

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
- If multiple images show the SAME receipt, reconcile into ONE list
- Extract EVERY item with exact pricing
- Be precise with numbers
---END PROMPT---

STEP 3: Save Claude's response to:
  claude_outputs/walmart_jan15.txt
```

## Comparison with Local vLLM

After collecting Claude responses, compare with local vLLM outputs:

```bash
# Local vLLM outputs in: vllm_outputs/purchase_001.txt
# Claude outputs in:     claude_outputs/purchase_001.txt

diff vllm_outputs/purchase_001.txt claude_outputs/purchase_001.txt
```

**Success criteria:**
- Both models extract 100% of items = local can replace Claude
- Claude extracts 100%, local 95% = keep Claude for this task
- Local faster + "good enough" = maybe use local anyway (cost savings)

## Adding Custom Task Types

Edit the script and add a new case in the `case "$TASK_TYPE" in` section:

```bash
your_custom_task)
    TASK_NAME="Your Task Description"
    PROMPT_TEMPLATE='Your prompt here
    
    With whatever format you want Claude to output
    
    **Instructions:**
    - Specific guidance here'
    ;;
```

Then use: `./generate_claude_prompts.sh your_custom_task ./your_data`

## Files

- `generate_claude_prompts.sh` - Main script
- `README_claude_prompts.md` - This file

## Tips

1. **Organize first:** Put all related images in one subfolder before running script
2. **Consistent naming:** Use `purchase_001`, `purchase_002` not random names  
3. **Batch size:** 20-50 items per batch is manageable for manual testing
4. **Save as you go:** Don't process 50 items then realize you forgot to save responses
5. **Use Projects:** Create a Claude Project for each batch test to keep conversations organized

## Troubleshooting

**"No subdirectories found"**
- Make sure data directory has subfolders, not loose image files
- Structure should be: `data_dir/subfolder1/image.jpg` not `data_dir/image.jpg`

**"No images/PDFs found"**  
- Check file extensions (.jpg, .jpeg, .png, .pdf)
- Make sure images are IN the subfolders, not in parent directory

**Prompt too long**
- If subfolder has 20+ images, Claude may hit context limits
- Split into multiple subfolders (e.g., `receipt_001a/`, `receipt_001b/`)

## Future Enhancements

- [ ] Auto-upload via Claude API (no manual copy-paste)
- [ ] Side-by-side comparison viewer (Claude vs vLLM)
- [ ] Accuracy scoring (compare structured outputs)
- [ ] Batch upload multiple items at once
- [ ] Export to spreadsheet for easier comparison
