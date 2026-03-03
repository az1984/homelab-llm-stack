# AutoRoute v1.0 - Standalone GenAI Router

**Simple, invisible, OpenAI-compatible endpoint for intelligent request routing**

AutoRoute is a lightweight HTTP proxy that analyzes incoming requests and routes them to appropriate local GenAI endpoints. It works with Open WebUI, CLI tools, or any OpenAI-compatible client.

## What It Does

```
Client → http://autoroute.local:8080/v1/chat/completions
           ↓
       [AutoRoute]
           ↓
       Router Model (Qwen3-8B analyzes request)
           ↓
       Routes to: chat-quick / chat-heavy / chat-devel / 
                  chat-peeks / chat-looks / chat-image / etc.
           ↓
       Returns response
```

## Features

✅ **Standalone** - Single Python script, no external dependencies beyond requests/PyYAML  
✅ **OpenAI-compatible** - Works with Open WebUI, curl, SDKs, anything  
✅ **Router-based** - Uses your Qwen3-8B to analyze and route requests  
✅ **10 endpoint classes** - Text, vision, and media routing  
✅ **Ripcord override** - Manual escalation per conversation  
✅ **Smart fallbacks** - Handles offline endpoints gracefully  
✅ **Easy config** - Single YAML file with all settings  
✅ **Systemd or Docker** - Run however you want  

## Quick Start

### Option 1: Run Directly (Recommended for homelab)

```bash
# Install dependencies
pip3 install -r requirements.txt

# Edit config
nano config.yaml  # Set your VIP endpoints

# Run
python3 autoroute.py
```

Point Open WebUI at: `http://localhost:8080`

### Option 2: Systemd Service

```bash
# Install
sudo mkdir -p /opt/autoroute
sudo cp autoroute.py config.yaml /opt/autoroute/
sudo cp autoroute.service /etc/systemd/system/

# Create user
sudo useradd -r -s /bin/false autoroute
sudo chown -R autoroute:autoroute /opt/autoroute

# Start
sudo systemctl daemon-reload
sudo systemctl enable autoroute
sudo systemctl start autoroute

# Check status
sudo systemctl status autoroute
sudo journalctl -u autoroute -f
```

### Option 3: Docker

```bash
# Build
docker build -t autoroute .

# Run
docker run -d \
  --name autoroute \
  -p 8080:8080 \
  -v $(pwd)/config.yaml:/app/config.yaml:ro \
  autoroute

# Or use docker-compose
docker-compose up -d
```

## Configuration

Edit `config.yaml` to set your local endpoints:

### Required: Set Your VIPs

```yaml
router:
  vip: "http://router.local:8080"  # Your Qwen3-8B router

endpoints:
  chat-quick:
    vip: "http://chat-quick.local:8080"
  chat-heavy:
    vip: "http://chat-heavy.local:8080"
  chat-devel:
    vip: "http://chat-devel.local:8080"
  chat-peeks:
    vip: "http://chat-peeks.local:8080"
  chat-looks:
    vip: "http://chat-looks.local:8080"
  # ... etc
```

### Optional Tuning

```yaml
# Router truncation (how much context router sees)
router:
  trunc_head_chars: 3000  # First N chars
  trunc_tail_chars: 300   # Last N chars

# Timeouts
endpoints:
  chat-heavy:
    timeout: 90  # Longer for deep reasoning
  chat-devel:
    timeout: 60
```

### Fallback Configuration

```yaml
endpoints:
  chat-devel:
    probe_for_availability: true
    fallback_hard: "chat-heavy"  # Complex tasks
    fallback_light: "chat-quick"  # Simple tasks
  
  chat-looks:
    probe_for_availability: true
    fallback: "chat-peeks"
```

## Usage

### With Open WebUI

1. Open WebUI → **Settings → Connections**
2. Add connection:
   - **API URL**: `http://autoroute.local:8080`
   - **API Key**: (leave blank or any value)
3. Select `autoroute` model in chat
4. Chat normally - AutoRoute handles routing invisibly

### With Curl

```bash
curl -X POST http://localhost:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "autoroute",
    "messages": [
      {"role": "user", "content": "Explain microservices vs monoliths"}
    ]
  }'
```

### With OpenAI Python SDK

```python
from openai import OpenAI

client = OpenAI(
    base_url="http://autoroute.local:8080/v1",
    api_key="not-needed"
)

response = client.chat.completions.create(
    model="autoroute",
    messages=[
        {"role": "user", "content": "Debug this Python error..."}
    ]
)
```

## Ripcord Override

Manually force routing for a conversation:

### Escalate to Heavy Model
Send any of these in chat:
- "ripcord"
- "use the bigger model"
- "bad code"
- "switch to heavy"

Response: `"Switched to heavy model for this conversation"`

### Force Devel Model
- "force devel"
- "use devel"

Response: `"Preferring devel model for this conversation"`

### Return to Automatic
- "back to auto"
- "clear ripcord"
- "de-escalate"

Response: `"Returned to automatic routing"`

**Note:** Ripcord state is per-conversation and stored in memory. Resets on service restart.

## How Routing Works

### Step 1: Extract Last User Message
AutoRoute gets the most recent user message from the conversation.

### Step 2: Check Ripcord
If user sent a ripcord command, handle it and skip routing.

### Step 3: Call Router Model
Truncates message (head + tail) and calls your Qwen3-8B router:

```json
{
  "target": "chat-heavy",
  "mode": "research",
  "dev_depth": "hard",
  "confidence": 0.9,
  "reason": "complex architecture discussion"
}
```

### Step 4: Apply Ripcord Override
If ripcord is active for this conversation, override text routes.

### Step 5: Apply Fallback Logic
If target endpoint is down, fall back:
- `chat-devel` down → `chat-heavy` (hard) or `chat-quick` (light)
- `chat-looks` down → `chat-peeks`
- `chat-peeks` down → `chat-heavy`

### Step 6: Forward Request
Send original request (unchanged) to final endpoint, return response.

## Routing Rubric

The router uses these rules (from your spec):

**Vision:**
- UI screenshots/OCR → `chat-peeks`
- Deep visual reasoning → `chat-looks`

**Text:**
- Architecture/tradeoffs → `chat-heavy`
- Implementation/debug → `chat-devel`
- Quick/general → `chat-quick`

**Media:**
- Audio transcription → `chat-trans`
- Video analysis → `chat-watch`
- TTS → `chat-speak`
- Image generation → `chat-image`

**Special:**
- Research requests → adds verification preamble
- Diagrams → suggests Mermaid/ASCII/SVG

## Monitoring & Debugging

### Check Logs

```bash
# Systemd
sudo journalctl -u autoroute -f

# Docker
docker logs -f autoroute

# Direct run
# Logs to stdout
```

Look for:
```
INFO - Router decision: {'target': 'chat-heavy', 'reason': '...'}
INFO - Routing to chat-heavy: complex reasoning required
INFO - Forwarding to http://chat-heavy.local:8080
```

### Test Router Directly

```bash
curl -X POST http://router.local:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "router",
    "messages": [{"role": "user", "content": "debug my code"}],
    "temperature": 0,
    "max_tokens": 120
  }'
```

Verify it returns valid JSON with routing decision.

### Test Endpoints

```bash
# Health check
curl http://chat-quick.local:8080/health

# Actual request
curl -X POST http://chat-quick.local:8080/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "quick",
    "messages": [{"role": "user", "content": "hello"}]
  }'
```

### Enable Debug Logging

In `config.yaml`:
```yaml
server:
  log_level: "DEBUG"

logging:
  log_payloads: true  # Warning: verbose!
```

## Troubleshooting

### "Router call failed" errors

**Check:**
- Is `router.vip` correct in config.yaml?
- Is router model running?
- Can you curl it directly?

**Fix:**
```bash
# Test router
curl http://router.local:8080/health

# Check AutoRoute logs for details
```

### Always routes to chat-heavy

**Possible causes:**
- Router failing (check logs)
- Router returning invalid JSON
- Fallback logic triggering

**Debug:**
- Check logs for "Router decision"
- Test router directly
- Enable debug logging

### Endpoint timeout errors

**Increase timeout in config.yaml:**
```yaml
endpoints:
  chat-heavy:
    timeout: 120  # 2 minutes
```

### Ripcord not working

**Check:**
- Is `ripcord.enabled: true` in config?
- Are you using exact trigger phrases?
- Ripcord only affects text routes (not vision/media)

## Performance

**Expected latency:**
- Router decision: <5 seconds
- Total overhead: 5-10 seconds vs direct endpoint
- Most time is spent in actual LLM generation, not routing

**Optimization:**
- Reduce `router.trunc_head_chars` for faster routing
- Increase `router.max_tokens` if decisions seem rushed
- Tune endpoint timeouts based on your hardware

## Architecture

```
┌─────────────────┐
│   Open WebUI    │  (or any OpenAI client)
│  or curl/SDK    │
└────────┬────────┘
         │ POST /v1/chat/completions
         ▼
┌─────────────────┐
│   AutoRoute     │  Python HTTP server
│   Proxy (8080)  │  - config.yaml
└────────┬────────┘  - ripcord state in memory
         │
         ├─ GET router decision
         │  ▼
         │  ┌──────────────┐
         │  │ Router Model │  Qwen3-8B
         │  │  (VIP)       │  Returns JSON decision
         │  └──────────────┘
         │
         ├─ Apply overrides & fallbacks
         │
         └─ Forward to target VIP
            ▼
    ┌──────────────┬──────────────┬──────────────┐
    │ chat-quick   │ chat-heavy   │ chat-devel   │
    │ chat-peeks   │ chat-looks   │ chat-image   │
    │ chat-trans   │ chat-watch   │ chat-speak   │
    └──────────────┴──────────────┴──────────────┘
         All behind HAProxy load balancers
```

## Migration & Maintenance

### Moving to New Hardware

1. Copy `/opt/autoroute` to new machine
2. Edit `config.yaml` if VIP addresses changed
3. Restart service

That's it. No databases, no state to migrate (except in-memory ripcord state which is session-based).

### Upgrading

1. Stop service
2. Replace `autoroute.py`
3. Check `config.yaml` for new options
4. Start service

### Backup

Just backup `config.yaml`. Everything else is code or ephemeral state.

## Comparison vs Pipelines (v2.0 Future)

**v1.0 (This - Standalone):**
- ✅ No extra containers
- ✅ Easy to migrate
- ✅ Works with any OpenAI client
- ❌ Config via YAML file (no UI)

**v2.0 (Pipelines - Future):**
- ❌ Extra container to manage
- ❌ Open WebUI specific
- ✅ Nice admin UI for config
- ✅ Valves for per-user settings

For homelab single-user: v1.0 is simpler.  
For multi-user with GUI preferences: v2.0 makes sense.

## Files

- `autoroute.py` - Main proxy server (~400 lines)
- `config.yaml` - All configuration
- `requirements.txt` - Python dependencies (requests, PyYAML)
- `autoroute.service` - systemd service file
- `Dockerfile` - Optional containerization
- `docker-compose.yaml` - Optional Docker Compose

## Requirements

- Python 3.8+
- requests library
- PyYAML library
- OpenAI-compatible router endpoint (Qwen3-8B)
- OpenAI-compatible target endpoints (your local models)

## License

MIT

---

**Built for homelab GenAI stacks. Simple. Invisible. Works.**
