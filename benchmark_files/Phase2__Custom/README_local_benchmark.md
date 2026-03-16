# Local vLLM Benchmark Runner
## Automated Batch Image Processing for vLLM Vision Models

This script processes batches of images using your local vLLM cluster, sending all images from each subfolder together in a single API call.

## Key Concept

**Each subfolder = one discrete task.**

All images in a subfolder are sent to vLLM in **ONE API call**, just like you'd upload multiple images to Claude chat for a single task.

```
receipts/
  purchase_001/           # ONE API call with 2 images
    receipt_front.jpg
    receipt_closeup.jpg
  purchase_002/           # SEPARATE API call with 1 image
    receipt.jpg
  purchase_003/           # THIRD API call with 3 images
    img1.jpg
    img2.jpg
    img3.jpg
```

## Usage

```bash
./local_benchmark.sh <task_type> <data_dir> [vllm_endpoint] [model_name]
```

### Arguments

1. **task_type** - Type of task (groceries, jamf, logic_errors, pdf_receipts)
2. **data_dir** - Directory with subfolders (one per task)
3. **vllm_endpoint** - API URL (default: http://192.168.2.42:8000)
4. **model_name** - Model name (default: chat-heavy)

### Examples

```bash
# Grocery receipts on default endpoint
./local_benchmark.sh groceries ./my_receipts

# Jamf screenshots on specific node
./local_benchmark.sh jamf ./screenshots http://192.168.2.43:8001

# Logic App errors with specific model
./local_benchmark.sh logic_errors ./errors http://192.168.2.42:8002 qwen3-vl-235b
```

## Data Structure

**Required:**
```
your_data/
  item_001/        # Subfolder = task boundary
    file1.jpg
    file2.jpg
  item_002/
    file.jpg
```

**Not this:**
```
your_data/       # ❌ Images directly in root
  file1.jpg
  file2.jpg
```

## How It Works

### For Each Subfolder

1. **Find all images** in the subfolder
2. **Encode to base64** (all images)
3. **Build API request** with content array:
   ```json
   {
     "messages": [{
       "role": "user",
       "content": [
         {"type": "text", "text": "Extract..."},
         {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}},
         {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
       ]
     }]
   }
   ```
4. **Send ONE API call** to vLLM
5. **Save response** to `vllm_outputs_TIMESTAMP/item_name.txt`

### Example API Call

For folder `purchase_001/` with 2 images:

```bash
curl -X POST http://192.168.2.42:8000/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "chat-heavy",
    "messages": [{
      "role": "user",
      "content": [
        {"type": "text", "text": "Extract ALL information from these grocery receipt image(s)..."},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQ..."}},
        {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,/9j/4AAQ..."}}
      ]
    }],
    "max_tokens": 4096,
    "temperature": 0.1
  }'
```

## Output Structure

```
vllm_outputs_20260315_120000/
  benchmark.log           # Detailed log with timestamps
  summary.txt             # High-level summary
  purchase_001.txt        # Response for first item
  purchase_002.txt        # Response for second item
  purchase_003.txt        # Response for third item
  ...
```

## Prompts

The script uses **identical prompts** as the Claude prompt generator. This ensures fair comparison:

- **groceries** → Markdown table + CSV export
- **jamf** → JSON schema
- **logic_errors** → Analysis + fix steps
- **pdf_receipts** → JSON schema

## Logging

Real-time progress with timestamps:

```
[12:34:56] ==========================================
[12:34:56] vLLM Benchmark: Grocery Receipt Extraction
[12:34:56] ==========================================
[12:34:56] Found 3 items to process
[12:34:56] 
[12:34:56] ==========================================
[12:34:56] [1/3] Processing: purchase_001
[12:34:56] ==========================================
[12:34:56]   Found 2 image(s)
[12:34:56]   Encoding: receipt_front.jpg
[12:34:56]   Encoding: receipt_closeup.jpg
[12:34:57]   Sending request to vLLM (2 images in one call)...
[12:35:12]   ✓ Response saved (15s, 3247 tokens)
```

## Error Handling

If an API call fails:
- Error logged to `benchmark.log`
- Full response saved to `item_name.txt.error.json`
- Processing continues to next item
- Final summary shows error count

## Comparison with Claude

### Workflow

1. **Organize data** in subfolders
2. **Run local benchmark** (automated, overnight):
   ```bash
   ./local_benchmark.sh groceries ./receipts
   # Output: vllm_outputs_TIMESTAMP/
   ```
3. **Generate Claude prompts** (manual copy-paste):
   ```bash
   ./generate_claude_prompts.sh groceries ./receipts
   # Output: claude_prompts_TIMESTAMP/
   ```
4. **Process Claude prompts** (manual, during day)
   - Upload images per prompt file
   - Paste prompt
   - Save to `claude_outputs/`
5. **Compare results**:
   ```bash
   diff vllm_outputs_*/purchase_001.txt claude_outputs/purchase_001.txt
   ```

### Side-by-Side Comparison

```
receipts/
  purchase_001/
    receipt_front.jpg
    receipt_closeup.jpg

# vLLM (automated)
vllm_outputs_20260315_120000/purchase_001.txt

# Claude (manual)
claude_outputs/purchase_001.txt

# Compare
diff -u vllm_outputs_20260315_120000/purchase_001.txt \
        claude_outputs/purchase_001.txt
```

## Performance Notes

### Rate Limiting

Script waits 2 seconds between API calls to avoid overwhelming vLLM:

```bash
# After each item (except last)
sleep 2
```

Adjust if needed:
```bash
# Faster (if vLLM can handle it)
sleep 1

# Slower (if getting timeouts)
sleep 5
```

### Batch Size

For 50 receipts:
- Estimated time: 50 items × (15s inference + 2s sleep) = ~14 minutes
- Perfect for overnight processing

### Memory

vLLM must have enough KV cache for multiple images per request:
- 1 image: ~1000 tokens
- 2 images: ~2000 tokens
- 3 images: ~3000 tokens
- etc.

Check vLLM config:
```bash
# In cluster_config.sh model profile
MAX_MODEL_LEN=180000        # Total context
MAX_NUM_SEQS=2              # Concurrent requests
GPU_MEMORY_UTILIZATION=0.80 # Leave headroom for KV cache
```

## Troubleshooting

### "No subdirectories found"

Make sure data has subfolders:
```bash
# Wrong
data/
  image1.jpg
  image2.jpg

# Correct
data/
  item_001/
    image1.jpg
  item_002/
    image2.jpg
```

### "Empty response from vLLM"

Check error file:
```bash
cat vllm_outputs_*/item_name.txt.error.json
```

Common causes:
- vLLM out of memory (too many images)
- Context length exceeded (reduce MAX_MODEL_LEN)
- Model crashed (check vLLM logs)

### "Connection refused"

vLLM not running or wrong endpoint:
```bash
# Check vLLM status
curl http://192.168.2.42:8000/v1/models

# Use correct endpoint
./local_benchmark.sh groceries ./data http://192.168.2.43:8001
```

## Advanced Usage

### Custom Model

```bash
# Use specific vLLM model
./local_benchmark.sh groceries ./data http://192.168.2.42:8002 qwen3.5-vision
```

### Custom Prompts

Edit the script and modify the `PROMPT_TEMPLATE` in the task type case:

```bash
case "$TASK_TYPE" in
    my_custom_task)
        TASK_NAME="My Custom Task"
        PROMPT_TEMPLATE='Your custom prompt here...'
        ;;
```

### Multiple Endpoints

Process same data on different nodes:

```bash
# Node 1 (Qwen3-VL-235B)
./local_benchmark.sh groceries ./data http://192.168.2.42:8000

# Node 2 (Qwen3.5-9B)
./local_benchmark.sh groceries ./data http://192.168.2.43:8002

# Compare outputs
diff vllm_outputs_20260315_120000/purchase_001.txt \
     vllm_outputs_20260315_120100/purchase_001.txt
```

## Integration with Orchestrator

The benchmark can run alongside cluster orchestrator:

```bash
# Start cluster with vision model
cd /path/to/orchestrator
./vllm_cluster_orchestrator-alt.sh start-cluster 2
./vllm_cluster_orchestrator-alt.sh load-model qwen3-vl-235b

# Wait for model to load
sleep 30

# Run benchmark
cd /path/to/benchmark
./local_benchmark.sh groceries ./receipts http://192.168.2.42:8000
```

## Files

- `local_benchmark.sh` - Main benchmark script
- `README_local_benchmark.md` - This file

## Next Steps

1. Organize your data into subfolders
2. Run local benchmark (automated)
3. Run Claude prompts (manual)
4. Compare results
5. Answer: **Can local vLLM replace Claude for this task?**

## Success Metrics

- **100% accuracy match** = Local can replace Claude ✅
- **95% accuracy, much faster** = Maybe use local anyway 🤔
- **80% accuracy** = Keep Claude for critical tasks 📊
- **Different strengths** = Use both (route by task type) 🔀
