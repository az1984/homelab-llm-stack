AutoRoute (Gen1 = Qwen3) — Unified Spec + Runbook
(Hybrid + Image Tuning + Vector/CAD + Mermaid + Vision Peeks/Looks)
===================================================================

Status
- Single Open WebUI (OWUI) instance.
- HAProxy sits in front of every runtime (text, dev, media).
- Non-streaming priority (robust tool calls > streaming).
- Gen1 assumes Qwen3-family models for routed text (router + chat-quick/heavy/devel).
- Vision is split into two endpoints:
  - chat-peeks (lightweight “eyes” for OCR/UI extraction; runs on Minis)
  - chat-looks (heavy vision reasoning; runs on Sparks when available)

----------------------------------------------------------------------
0) Goals and non-goals
----------------------------------------------------------------------

Goals
- Keep Open WebUI as the polished UX.
- Provide a single selectable OWUI “model”: autoroute (Pipe).
- AutoRoute routes each user turn to one endpoint class (all 10 chars):
  - chat-quick : fast general Q&A (default)
  - chat-heavy : deep reasoning + architecture/tradeoffs; reliable fallback for anything
  - chat-devel : implementation/debug/refactor/logs (Coder-Next 80B class), run-when-needed and may be DOWN

  - chat-peeks : lightweight vision/OCR for UI screenshots (Mini-friendly)
  - chat-looks : heavy vision reasoning (Spark real estate; may be down when Sparks run specialist heavy)

  - chat-image : raster image generation (MVP uses OWUI ComfyUI integration; manual trigger initially)
  - chat-trans : audio READ (ASR / listen / transcribe)
  - chat-watch : video READ (watch/analyze/summarize)
  - chat-speak : audio WRITE (TTS / read aloud)
  - chat-video : video WRITE (placeholder / future)

- TTS has two “profiles” under chat-speak:
  - readback: quick “read it back” (car/drive/listen), low friction
  - studio: high-quality narration/audiobook/performance, explicit request

- Level 1 media handling:
  - Images: turnkey OWUI ComfyUI integration; automation later.
  - Audio/video: route + instructions now; automate follow-up results later.

- Support “hybrid” turns (text + visual help) without async:
  - If a turn is both a full answer and a raster image prompt, ask ordering:
    “I’m going to answer this in both a message and an image. Which would you like first:
     (A) the written answer or (B) the image prompt?”

- Prefer deterministic diagrams (Mermaid/ASCII) for flowcharts/system diagrams unless user explicitly asks for raster.

- Treat vector/CAD asks as text artifacts (SVG/OpenSCAD/etc.) unless user explicitly asks for raster render.

- Provide a per-chat “ripcord” override for text quality:
  - “ripcord / bigger model / bad code” => force chat-heavy for text in that chat until cleared.

Non-goals (for now)
- True parallel streaming text while image generation runs.
- Middleware that mutates payloads (avoid LiteLLM in the mandatory request path).
- Complex ComfyUI workflows orchestrated by the router (user may call Comfy directly later).
- Fully automated browsing/citations; only a research preamble for now.
- A separate mac_* route; Minis are treated as normal pool members via HAProxy/DNS.

----------------------------------------------------------------------
1) Architecture snapshot
----------------------------------------------------------------------

Open WebUI
- Primary UX.
- Adds a Pipe “model” named: autoroute.
- Still allows manual model selection (optional) for debugging/override.

Backends (via HAProxy VIPs; Pipe does routing, not LB)
- Gen1 text endpoints:
  - Router: Qwen3-8B class (routing only; can be hosted on Minis and pooled)
  - chat-quick: Qwen3 ~30B-ish MoE class
  - chat-heavy: Qwen3-VL-235B (or other deep generalist) usually up
  - chat-devel: Coder-Next 80B class (run-when-needed)

- Vision endpoints:
  - chat-peeks: lightweight VLM (planned: Qwen3-VL-8B or Pixtral 12B) hosted on Mac Minis
  - chat-looks: heavy VLM (planned: Qwen3-VL-235B when allocated for vision) hosted on Sparks; may be down

Media
- ComfyUI configured via OWUI integration.
- ASR/TTS endpoints exist or planned.

----------------------------------------------------------------------
2) Endpoint classes and configuration
----------------------------------------------------------------------

Endpoint classes (10 chars) and required VIP env vars:

Text
- chat-quick => CHAT_QUICK_VIP
- chat-heavy => CHAT_HEAVY_VIP
- chat-devel => CHAT_DEVEL_VIP

Vision
- chat-peeks => CHAT_PEEKS_VIP   (Mini VLM pool)
- chat-looks => CHAT_LOOKS_VIP   (heavy VLM pool; may be down)

Media
- chat-image => CHAT_IMAGE_VIP   (OWUI Comfy integration target)
- chat-trans => CHAT_TRANS_VIP
- chat-watch => CHAT_WATCH_VIP
- chat-speak => CHAT_SPEAK_VIP
- chat-video => CHAT_VIDEO_VIP   (placeholder)

Router VIP:
- ROUTER_VIP

Router truncation knobs:
- ROUTER_TRUNC_HEAD_CHARS (e.g., 3000)
- ROUTER_TRUNC_TAIL_CHARS (e.g., 300, optional)
- ROUTER_MAX_TOKENS       (e.g., 120)

Notes
- HAProxy handles health checks and load balancing behind each VIP.
- AutoRoute may probe chat-devel or chat-looks availability to decide fallback quickly.

----------------------------------------------------------------------
3) Gen1 tool-call dialect (“one lingo everywhere”)
----------------------------------------------------------------------

Canonical tool calling contract (required for tool-capable models)
- Use OpenAI-style tool_calls.
- tool_calls[].function.arguments is a JSON string containing valid JSON.
- No markdown wrapping of JSON.
- Only call tools provided in the request.
- If required info is missing, ask instead of guessing arguments.

Pipe forwarding invariants (robust tool calls)
- AutoRoute forwards request body to the selected VIP with minimal changes.
- The Pipe must NOT:
  - rewrite/reserialize tool schemas
  - reorder messages
  - inject assistant messages mid-turn
  - coerce formats

Allowed Pipe modifications:
- Prepend research preamble when mode=research.
- Set tool_choice="none" for routes where tools must be forbidden (optional).
- Truncate router input only (never truncate main request unless explicit).

----------------------------------------------------------------------
4) Router model and decision format
----------------------------------------------------------------------

Router model
- Qwen3-8B class (or similar small Qwen3).
- Router uses NO tools; outputs strict JSON only.

Router input cap (required)
- Router sees only last user message, truncated (head + optional tail), marked “(truncated for routing)”.
- Router does NOT receive whole chat history in MVP.

Router generation cap
- temperature=0
- max_tokens=ROUTER_MAX_TOKENS (~120)

Router strict JSON schema (required)
{
  "target": "chat-quick" | "chat-heavy" | "chat-devel" |
            "chat-peeks" | "chat-looks" |
            "chat-image" | "chat-trans" | "chat-watch" | "chat-speak" | "chat-video",

  "mode": "default" | "research",
  "dev_depth": "none" | "light" | "hard",
  "tts_profile": "none" | "readback" | "studio",

  "needs_image": true | false,
  "image_action": "none" | "make_now" | "tune_first",

  "needs_both": true | false,
  "both_order": "ask" | "text_first" | "image_first",

  "artifact_mode": "none" | "mermaid" | "ascii" | "svg" | "openscad",

  "confidence": 0.0,
  "reason": "short"
}

Rules
- tts_profile only meaningful when target=chat-speak; otherwise "none".
- If needs_image=false => image_action must be "none".
- If needs_both=true => both_order must be "ask" for MVP.
- artifact_mode != "none" means deliver as text artifact (not Comfy raster) unless user explicitly requests raster.
- reason is logs-only; dev_depth guides fallback if chat-devel is down.

----------------------------------------------------------------------
5) Routing rubric (the actual policy)
----------------------------------------------------------------------

Decision ordering per user turn:

Step 0: Ripcord detection (see section 8)
- If user issues override command: set/clear override, acknowledge briefly, continue routing
  (override does not supersede artifact-first rules).

Step 1: Artifact-first exceptions (text artifacts that look “image-y”)
These override raster image handling unless user explicitly requests raster.

1A) Vector/CAD/parametric outputs
- If user mentions: “vector”, “SVG”, “Inkscape”, “Illustrator”, “DXF”
  => artifact_mode="svg", needs_image=false
- If user mentions: “OpenSCAD”, “3D print”, “STL”, “parametric”, “CAD”, “3D model”
  => artifact_mode="openscad", needs_image=false
- If user also asks “render/raster/image/preview”, then allow needs_image=true in addition to artifact.

1B) Flow/logic diagrams
- If user mentions: “flowchart”, “state machine”, “sequence”, “decision tree”, “pipeline diagram”
  => artifact_mode="mermaid" (default) or "ascii" (fallback), needs_image=false
- Only set needs_image=true if user explicitly asks “as an image” / “generate a picture”.

Step 2: Vision vs image-generation vs other modalities

2A) Vision reading (UI screenshots / OCR / extraction)
Route to chat-peeks by default when:
- Image is attached, OR
- User says “screenshot”, “UI”, “OCR”, “transcribe the screen”, “extract fields”, “fill this JSON schema”.

Escalate to chat-looks when:
- User explicitly requests deep visual reasoning (multi-image comparison, complex chart interpretation),
  OR user says “use the big vision model”, OR peeks fails and user requests escalation.

Fallback:
- If chat-looks is unavailable, fall back to chat-peeks.
- If chat-peeks is unavailable, fall back to chat-looks (if up) else to chat-heavy with a “paste text if possible” suggestion.

2B) Audio/video modalities
- chat-trans for audio listen/transcribe.
- chat-watch for video analysis.
- chat-speak for TTS.
- chat-video for explicit video generation (placeholder).

2C) Raster image generation intent (ComfyUI path)
If user requests raster imagery (“draw”, “sketch”, “generate an image”, “make a picture”, “mockup”, “wireframe”)
and artifact_mode="none":
- needs_image=true
- Primary target remains a text model (chat-quick or chat-heavy) for prompt planning until chat-image is live.
  (Once chat-image is live, you may set target=chat-image for automatic generation.)

TTS profile selection (only when target=chat-speak)
- Default tts_profile="readback" for “read it back” use cases:
  “read this back”, “speak this”, “say it out loud”, “I’m driving”, “listen to this”, “TTS this”
- Use tts_profile="studio" only when explicitly requested:
  “audiobook”, “narration”, “voice acting”, “high quality”, “cinematic”, “character voice(s)”, “with emotion”, “performance”, “record a snippet”
- If unclear, choose "readback".

Step 3: Text routes (architecture vs implementation)
- Architecture/tradeoffs/system design/planning/deep synthesis => chat-heavy
- Implementation/debug/refactor/logs/code writing => chat-devel
- Small/quick/general => chat-quick

Dev depth guidance
- dev_depth=light: small snippet/minor edit/simple command
- dev_depth=hard: logs/stack traces/multi-step debugging/refactor/complex scripts

Step 4: Image action selection (make_now vs tune_first)
If needs_image=true and artifact_mode="none":
- image_action="make_now" when prompt is concrete (clear subject + style/mood + no major missing constraints).
- image_action="tune_first" when underspecified or likely to need choices:
  “logo”, “brand”, “concept”, “iterate”, “wireframe my app”, “layout a sketch”, “moodboard”, vague prompts.

Step 5: Hybrid detection (both text answer + raster image prompt)
If needs_image=true AND user also needs substantial reasoning/planning:
- needs_both=true
- both_order="ask" for MVP
- Assistant asks:
  “I’m going to answer this in both a message and an image. Which would you like first:
   (A) the written answer or (B) the image prompt?”

Step 6: Research mode flag
- mode=research when user asks “cite/verify/latest/compare/fact check/what changed since…”.

----------------------------------------------------------------------
6) chat-devel run-when-needed and fallback behavior
----------------------------------------------------------------------

Assumption
- chat-devel may be intentionally offline.

Probe and fallback
- When router selects chat-devel:
  - attempt with short connect timeout (1–2s)
  - if unavailable:
    - dev_depth=hard => fallback to chat-heavy
    - dev_depth=light => fallback to chat-quick
  - only one fallback hop; no loops
  - log fallback event

Rationale
- chat-heavy can write code but is slower; it is the “always works” implementer when devel is down.

----------------------------------------------------------------------
7) Research mode (stub for now)
----------------------------------------------------------------------

When mode=research:
- Prepend research preamble:
  “State assumptions. Verify dates. If unsure, say so. Cite sources if available. Don’t guess.”
- No automated browsing in MVP.

----------------------------------------------------------------------
8) Ripcord override (per conversation/session)
----------------------------------------------------------------------

Scope
- Per conversation, stored in memory (single OWUI instance).
- Resets on OWUI restart (acceptable for MVP).

Commands (examples)
Escalate: “ripcord”, “use the bigger model”, “try the bigger model”, “bad code”, “switch to heavy”, “go heavy”
Clear: “back to auto”, “clear ripcord”, “return to autoroute”, “de-escalate”

Modes
- auto (default)
- force_heavy (force text routes to chat-heavy)
- force_devel (prefer chat-devel for implementation; fallback to chat-heavy if down)

Application order
- Artifact-first rules win.
- Vision routing (peeks/looks) wins for image-attached UI extraction tasks.
- Then override applies to text-only routes (quick/heavy/devel).

----------------------------------------------------------------------
9) Level 1 media handling (MVP behaviors)
----------------------------------------------------------------------

Artifact outputs (text, not Comfy raster)
- mermaid: output Mermaid code block.
- ascii: output ASCII diagram.
- svg: output raw SVG.
- openscad: output OpenSCAD code.

Vision reading (chat-peeks/chat-looks)
- For UI screenshot -> JSON schema tasks:
  - Provide STRICT JSON output per user schema.
  - If uncertainty, use null and optionally an “uncertain_fields” array (if schema allows).
- If peeks misses fields and user asks to escalate, route to looks when available.

Raster image generation (ComfyUI path)
- If needs_both=true: ask which first (A text / B image prompt).
- If image_action="make_now":
  - Provide a ready-to-run ComfyUI prompt verbatim + minimal defaults.
  - Include: “I can make that image for you now.”
- If image_action="tune_first":
  - Ask 2–5 targeted questions (style, aspect ratio, must-include, avoid list).
  - Include: “Would you like to tune the prompt before making the image yourself?”

chat-image (MVP)
- Use OWUI ComfyUI integration; manual trigger initially.
- AutoRoute does not submit Comfy jobs directly in MVP.

chat-trans (MVP)
- Provide upload/link instructions; transcript + timestamps.
- Automation later.

chat-watch (MVP)
- Provide upload/link instructions; summary + key timestamps.
- Automation later.

chat-speak (MVP)
- tts_profile=readback: TTS-ready script, minimal clarifiers.
- tts_profile=studio: gather constraints, deliver polished narration script.
- Automation later.

chat-video (placeholder)
- Acknowledge not configured or route to future endpoint if present.

----------------------------------------------------------------------
10) Logging and observability
----------------------------------------------------------------------

Log per request:
- timestamp
- router decision (target/mode/dev_depth/tts_profile/needs_image/image_action/needs_both/both_order/artifact_mode/confidence)
- router truncation lengths
- chosen VIP/class
- latency
- chat-devel and chat-looks availability/fallback events
- errors/retries

----------------------------------------------------------------------
11) Phased rollout plan
----------------------------------------------------------------------

Phase A — Baselines
- Confirm each VIP accepts OpenAI-compatible envelope.
- Verify tool calling works directly against Qwen3 endpoints (baseline).

Phase B — ComfyUI MVP
- Configure OWUI Comfy integration; confirm manual image generation works.

Phase C — AutoRoute Pipe MVP (non-streaming)
- Implement router call (truncated input) + strict JSON parse.
- Implement routing to VIPs (HAProxy).
- Implement chat-devel probe + fallback.
- Implement chat-looks probe + fallback to chat-peeks for vision.
- Implement ripcord override.
- Implement artifact_mode outputs (mermaid/svg/openscad).
- Implement needs_both + both_order question.
- Confirm tool-call reliability unchanged vs direct calls.

Phase D — Vision continuity
- Stand up chat-peeks (Qwen3-VL-8B or Pixtral 12B) on Minis.
- Confirm UI screenshot -> JSON schema extraction works with acceptable latency.
- Confirm chat-looks can be down without losing vision entirely.

Phase E (later) — Follow-up messages / automation
- Post separate replies when Comfy/ASR/TTS completes; optional direct tool orchestration.

----------------------------------------------------------------------
12) Small implementation checks
----------------------------------------------------------------------

- Pipe networking: can OWUI reach each HAProxy VIP?
- Pipe API contract: confirm Pipe return type expected by your OWUI version.
- Identify conversation id available to the Pipe for ripcord keying.

End of plan.
