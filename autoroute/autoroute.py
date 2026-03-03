#!/usr/bin/env python3
"""
AutoRoute - Intelligent router for local GenAI stack
Routes OpenAI-compatible requests to appropriate local endpoints based on content analysis
"""

import http.server
import socketserver
import json
import requests
import logging
import yaml
import sys
from pathlib import Path
from typing import Dict, Any, Optional
from urllib.parse import urlparse

# Load configuration
def load_config(config_path: str = "config.yaml") -> Dict[str, Any]:
    """Load configuration from YAML file"""
    config_file = Path(config_path)
    if not config_file.exists():
        print(f"ERROR: Config file not found: {config_path}")
        sys.exit(1)
    
    with open(config_file, 'r') as f:
        return yaml.safe_load(f)

# Global config and state
CONFIG = load_config()
RIPCORD_STATE = {}  # {conversation_id: "auto" | "force_heavy" | "force_devel"}

# Setup logging
log_level = getattr(logging, CONFIG['server']['log_level'].upper())
log_config = {
    'level': log_level,
    'format': '%(asctime)s - %(name)s - %(levelname)s - %(message)s'
}
if 'file' in CONFIG.get('logging', {}):
    log_config['filename'] = CONFIG['logging']['file']

logging.basicConfig(**log_config)
logger = logging.getLogger('autoroute')


class AutoRouteHandler(http.server.BaseHTTPRequestHandler):
    """HTTP request handler for AutoRoute proxy"""
    
    def do_POST(self):
        """Handle POST requests to /v1/chat/completions"""
        if self.path != '/v1/chat/completions':
            self.send_error(404, "Not Found - Only /v1/chat/completions supported")
            return
        
        try:
            # Read request body
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length)
            request_data = json.loads(body.decode('utf-8'))
            
            if CONFIG['logging'].get('log_payloads', False):
                logger.debug(f"Incoming request: {json.dumps(request_data, indent=2)}")
            
            # Route the request
            response_data, status_code = route_request(request_data)
            
            # Send response
            self.send_response(status_code)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(response_data).encode('utf-8'))
            
        except json.JSONDecodeError as e:
            logger.error(f"Invalid JSON in request: {e}")
            self.send_error(400, f"Invalid JSON: {str(e)}")
        except Exception as e:
            logger.error(f"Error processing request: {e}", exc_info=True)
            self.send_error(500, "Internal server error")
    
    def do_GET(self):
        """Handle GET requests (health check)"""
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps({"status": "healthy"}).encode('utf-8'))
        else:
            self.send_error(404, "Not Found")
    
    def log_message(self, format, *args):
        """Override to use our logger"""
        logger.info(f"{self.address_string()} - {format % args}")


def extract_last_user_message(messages: list) -> str:
    """Extract the last user message from conversation"""
    for msg in reversed(messages):
        if msg.get("role") == "user":
            content = msg.get("content", "")
            if isinstance(content, str):
                return content
            elif isinstance(content, list):
                # Handle multimodal content
                text_parts = []
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "text":
                        text_parts.append(item.get("text", ""))
                return " ".join(text_parts)
    return ""


def truncate_for_router(text: str) -> str:
    """Truncate message for router analysis (head + tail)"""
    router_config = CONFIG['router']
    head_chars = router_config['trunc_head_chars']
    tail_chars = router_config['trunc_tail_chars']
    
    if len(text) <= head_chars:
        return text
    
    head = text[:head_chars]
    
    if tail_chars > 0:
        tail = text[-tail_chars:]
        return f"{head}\n... (truncated for routing) ...\n{tail}"
    
    return f"{head}\n... (truncated for routing)"


def check_ripcord(user_message: str, conversation_id: str) -> Optional[str]:
    """
    Check for ripcord commands and update state
    Returns response message if ripcord triggered, None otherwise
    """
    if not CONFIG['ripcord']['enabled']:
        return None
    
    lower_msg = user_message.lower().strip()
    
    # Check escalate triggers
    for trigger in CONFIG['ripcord']['escalate_triggers']:
        if trigger in lower_msg:
            RIPCORD_STATE[conversation_id] = "force_heavy"
            logger.info(f"Ripcord activated: force_heavy for conversation {conversation_id}")
            return "Switched to heavy model for this conversation"
    
    # Check force devel triggers
    for trigger in CONFIG['ripcord']['force_devel_triggers']:
        if trigger in lower_msg:
            RIPCORD_STATE[conversation_id] = "force_devel"
            logger.info(f"Ripcord activated: force_devel for conversation {conversation_id}")
            return "Preferring devel model for this conversation"
    
    # Check clear triggers
    for trigger in CONFIG['ripcord']['clear_triggers']:
        if trigger in lower_msg:
            RIPCORD_STATE.pop(conversation_id, None)
            logger.info(f"Ripcord cleared for conversation {conversation_id}")
            return "Returned to automatic routing"
    
    return None


def call_router(user_message: str) -> Dict[str, Any]:
    """Call router model to get routing decision"""
    truncated = truncate_for_router(user_message)
    router_config = CONFIG['router']
    
    router_prompt = f"""You are a routing decision maker. Analyze this user message and return ONLY a JSON object with routing decisions.

User message:
{truncated}

Return strict JSON format:
{{
  "target": "chat-quick|chat-heavy|chat-devel|chat-peeks|chat-looks|chat-image|chat-trans|chat-watch|chat-speak|chat-video",
  "mode": "default|research",
  "dev_depth": "none|light|hard",
  "tts_profile": "none|readback|studio",
  "needs_image": true|false,
  "image_action": "none|make_now|tune_first",
  "needs_both": true|false,
  "both_order": "ask|text_first|image_first",
  "artifact_mode": "none|mermaid|ascii|svg|openscad",
  "confidence": 0.0-1.0,
  "reason": "brief explanation"
}}

Routing rubric:
- Vision (image attached): chat-peeks for UI/OCR, chat-looks for deep reasoning
- Audio/video: chat-trans (transcribe), chat-watch (analyze), chat-speak (TTS), chat-video (generate)
- Raster images: set needs_image=true, target stays text model for prompt planning
- Architecture/tradeoffs/system design: chat-heavy
- Implementation/debug/code writing: chat-devel (dev_depth=hard for complex, light for simple)
- Quick/general questions: chat-quick
- Research/cite/verify requests: mode=research
- Diagrams/flowcharts: artifact_mode=mermaid/ascii/svg/openscad (NOT raster)

Respond with ONLY the JSON object, no markdown, no explanation."""

    try:
        response = requests.post(
            f"{router_config['vip']}/v1/chat/completions",
            json={
                "model": "router",
                "messages": [{"role": "user", "content": router_prompt}],
                "temperature": router_config['temperature'],
                "max_tokens": router_config['max_tokens']
            },
            timeout=router_config['timeout']
        )
        response.raise_for_status()
        
        result = response.json()
        content = result["choices"][0]["message"]["content"].strip()
        
        # Clean up potential markdown wrapping
        if content.startswith("```json"):
            content = content.replace("```json", "").replace("```", "").strip()
        elif content.startswith("```"):
            content = content.replace("```", "").strip()
        
        decision = json.loads(content)
        
        if CONFIG['logging'].get('log_decisions', True):
            logger.info(f"Router decision: {decision}")
        
        return decision
        
    except Exception as e:
        logger.error(f"Router call failed: {e}")
        # Fallback to chat-heavy
        return {
            "target": "chat-heavy",
            "mode": "default",
            "dev_depth": "none",
            "tts_profile": "none",
            "needs_image": False,
            "image_action": "none",
            "needs_both": False,
            "both_order": "ask",
            "artifact_mode": "none",
            "confidence": 0.5,
            "reason": "router failed, fallback to heavy"
        }


def apply_ripcord_override(decision: Dict[str, Any], conversation_id: str) -> Dict[str, Any]:
    """Apply ripcord override to routing decision"""
    if conversation_id not in RIPCORD_STATE:
        return decision
    
    ripcord_mode = RIPCORD_STATE[conversation_id]
    original_target = decision["target"]
    
    # Only override text routes
    if original_target in ["chat-quick", "chat-heavy", "chat-devel"]:
        if ripcord_mode == "force_heavy":
            decision["target"] = "chat-heavy"
            decision["reason"] = f"ripcord override: {original_target} -> chat-heavy"
        elif ripcord_mode == "force_devel":
            decision["target"] = "chat-devel"
            decision["reason"] = f"ripcord override: {original_target} -> chat-devel"
        
        logger.info(f"Ripcord override applied: {original_target} -> {decision['target']}")
    
    return decision


def probe_endpoint(endpoint_name: str) -> bool:
    """Check if endpoint is available"""
    if not CONFIG['probing']['enabled']:
        return True
    
    endpoint_config = CONFIG['endpoints'].get(endpoint_name, {})
    if not endpoint_config.get('probe_for_availability', False):
        return True
    
    vip = endpoint_config['vip']
    probe_config = CONFIG['probing']
    
    try:
        method = probe_config['method']
        path = probe_config['path']
        url = f"{vip}{path}"
        
        if method == "HEAD":
            response = requests.head(url, timeout=probe_config['timeout'])
        else:
            response = requests.get(url, timeout=probe_config['timeout'])
        
        return response.status_code < 400
    except:
        return False


def apply_fallback(decision: Dict[str, Any]) -> Dict[str, Any]:
    """Apply fallback logic if endpoint is unavailable"""
    target = decision["target"]
    endpoint_config = CONFIG['endpoints'].get(target, {})
    
    if not endpoint_config.get('probe_for_availability', False):
        return decision
    
    if not probe_endpoint(target):
        logger.warning(f"{target} unavailable, applying fallback")
        
        # chat-devel fallback
        if target == "chat-devel":
            if decision["dev_depth"] == "hard":
                fallback = endpoint_config.get('fallback_hard', 'chat-heavy')
            else:
                fallback = endpoint_config.get('fallback_light', 'chat-quick')
            
            decision["target"] = fallback
            decision["reason"] += f" (devel down, fallback to {fallback})"
        
        # chat-looks fallback
        elif target == "chat-looks":
            fallback = endpoint_config.get('fallback', 'chat-peeks')
            decision["target"] = fallback
            decision["reason"] += f" (looks down, fallback to {fallback})"
        
        # chat-peeks fallback (last resort)
        elif target == "chat-peeks":
            fallback = endpoint_config.get('fallback', 'chat-heavy')
            decision["target"] = fallback
            decision["reason"] += f" (peeks down, fallback to {fallback} - suggest pasting text)"
    
    return decision


def prepend_research_preamble(messages: list, mode: str) -> list:
    """Prepend research preamble if mode=research"""
    if mode != "research":
        return messages
    
    preamble = CONFIG['research']['preamble']
    modified = messages.copy()
    
    # Insert as system message or prepend to first message
    if modified and modified[0].get("role") == "system":
        modified[0]["content"] = f"{modified[0]['content']}\n\n{preamble}"
    else:
        modified.insert(0, {"role": "system", "content": preamble})
    
    return modified


def route_request(request_data: Dict[str, Any]) -> tuple[Dict[str, Any], int]:
    """
    Main routing logic
    Returns: (response_data, status_code)
    """
    try:
        messages = request_data.get("messages", [])
        user_message = extract_last_user_message(messages)
        
        # Extract conversation ID (use a hash of first message or model field as proxy)
        conversation_id = request_data.get("model", "default")
        
        # Check for ripcord commands
        ripcord_response = check_ripcord(user_message, conversation_id)
        if ripcord_response:
            # Return simple text response
            return {
                "id": "ripcord-response",
                "object": "chat.completion",
                "created": 0,
                "model": "autoroute",
                "choices": [{
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": ripcord_response
                    },
                    "finish_reason": "stop"
                }]
            }, 200
        
        # Call router for decision
        decision = call_router(user_message)
        
        # Apply ripcord override
        decision = apply_ripcord_override(decision, conversation_id)
        
        # Apply fallback logic
        decision = apply_fallback(decision)
        
        # Log final decision
        logger.info(f"Routing to {decision['target']}: {decision['reason']}")
        
        # Get target endpoint
        target = decision['target']
        endpoint_config = CONFIG['endpoints'].get(target)
        
        if not endpoint_config:
            logger.error(f"Unknown target: {target}")
            return {"error": f"Unknown target: {target}"}, 500
        
        endpoint_url = endpoint_config['vip']
        
        # Modify messages for research mode
        modified_messages = prepend_research_preamble(messages, decision['mode'])
        
        # Prepare forwarding payload
        payload = {**request_data, "messages": modified_messages}
        
        # Forward to endpoint
        logger.info(f"Forwarding to {endpoint_url}")
        response = requests.post(
            f"{endpoint_url}/v1/chat/completions",
            json=payload,
            headers={"Content-Type": "application/json"},
            timeout=endpoint_config.get('timeout', 60)
        )
        
        if CONFIG['logging'].get('log_payloads', False):
            logger.debug(f"Response from {target}: {response.text[:500]}")
        
        return response.json(), response.status_code
        
    except requests.exceptions.Timeout:
        logger.error(f"Timeout forwarding to {target}")
        return {"error": "Request timeout"}, 504
    except requests.exceptions.RequestException as e:
        logger.error(f"Error forwarding to {target}: {e}")
        return {"error": f"Forwarding error: {str(e)}"}, 502
    except Exception as e:
        logger.error(f"Unexpected error: {e}", exc_info=True)
        return {"error": "Internal server error"}, 500


class ThreadedHTTPServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    """Threaded HTTP server to handle multiple requests concurrently"""
    daemon_threads = True


def main():
    """Start the AutoRoute proxy server"""
    host = CONFIG['server']['host']
    port = CONFIG['server']['port']
    
    logger.info("="*60)
    logger.info("AutoRoute Proxy Server Starting")
    logger.info("="*60)
    logger.info(f"Listening on {host}:{port}")
    logger.info(f"Router: {CONFIG['router']['vip']}")
    logger.info(f"Endpoints configured: {len(CONFIG['endpoints'])}")
    logger.info(f"Ripcord: {'enabled' if CONFIG['ripcord']['enabled'] else 'disabled'}")
    logger.info("="*60)
    
    server = ThreadedHTTPServer((host, port), AutoRouteHandler)
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Shutting down AutoRoute...")
        server.shutdown()


if __name__ == '__main__':
    main()
