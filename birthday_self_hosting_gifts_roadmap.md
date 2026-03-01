# Birthday Self-Hosting Gifts Roadmap

Timeframe: **Now → late February**

Goal: Two tangible “gifts” to Future You by your birthday:
- **Gift A:** Local, long-context GPT-OSS-120B as your day‑to‑day work copilot for the Logic Apps doc tool.
- **Gift B:** A creative-writing + media stack that can help with novel revisions, cover art, and a not‑terrible audiobook.

---

## Timeline at a Glance

- **Now → Nov 30**
  - ✅ Stabilize Spark #1 base stack (Docker, NVIDIA toolkit, llama.cpp working reliably).
  - ☐ Stand up GPT-OSS-20B locally as a known‑good reference.

- **Dec 1 → Dec 15**
  - ☐ Get GPT-OSS-120B running with long-ish context (>= 64k effective via GGUF/Yarn where stable).
  - ☐ Wire GPT-OSS-120B into OpenWebUI / Cline for the Logic App doc tool 1.1 / 1.2 work.

- **Dec 16 → Early Jan**
  - ☐ Stand up at least one “good at prose” large model (Dolphin 70B / Mistral‑Large / similar) with big context.
  - ☐ Integrate that model into your writing workflow as a chapter‑aware co‑writer.

- **Early Jan → Late Feb**
  - ☐ Bring up image generation (cover art) in your homelab.
  - ☐ Bring up high‑quality TTS for a not‑terrible audiobook.
  - ☐ Do an end‑to‑end run: chapter revisions → cover → sample audio.

---

## Gift A: GPT-OSS-120B Long-Context Work Copilot

### A1. Solidify the Base Stack (This Week)

- [ ] Confirm Spark #1 GPU stack
  - [ ] `nvidia-smi` clean, no ghost processes.
  - [ ] Docker + NVIDIA runtime tested with a CUDA container.
- [ ] Confirm model storage layout
  - [ ] `/opt/ai-models` (or final path) exists, owned by your `admin` user and group.
  - [ ] HF and GGUF subtrees in place and reasonably named.
- [ ] Confirm llama.cpp service is working
  - [ ] A small GGUF model loads in a Dockerized llama.cpp.
  - [ ] Simple test completion via `curl` against the HTTP API.

### A2. GPT-OSS-20B as a “Known Good” Baseline

- [ ] Download and place **GPT-OSS-20B GGUF**
  - [ ] Choose a balanced quant (e.g., MXFP4 / Q4_K / similar) that fits comfortably.
  - [ ] Store under `/opt/ai-models/gguf/gpt-oss-20b/`.
- [ ] Update `docker-compose.yml`
  - [ ] Point `llamacpp` at the GPT-OSS-20B GGUF path.
  - [ ] Set context length to a safe but useful value (e.g., 32k or 64k depending on quant).
- [ ] Sanity tests
  - [ ] `curl` a short prompt, verify completions look sane.
  - [ ] Hit it from OpenWebUI / LibreChat as a backend.
  - [ ] Time cold start vs warm generations.

### A3. Stand Up GPT-OSS-120B with Long Context (Early December)

- [ ] Download GPT-OSS-120B weights
  - [ ] HF “dense” version under `/opt/ai-models/gpt-oss/gpt-oss-120b/`.
  - [ ] At least one **long‑context GGUF** (Yarn‑ready) under `/opt/ai-models/gguf/gpt-oss-120b/`.
- [ ] Decide **first serving path**
  - Option 1: **llama.cpp** (simpler, reliable, great for GGUF + Yarn).
  - Option 2: vLLM / TRT‑LLM later if/when support for GB10 / FP8 variants is smooth.
  - [ ] Start with the path that requires the least “Triton lore” today.
- [ ] Configure GPT-OSS-120B service
  - [ ] New llama.cpp container or second instance for 120B.
  - [ ] Conservative context length (e.g., 32k) for stability.
  - [ ] Test bumping context toward 64k+ if GGUF + hardware allows.
- [ ] Wire into tools
  - [ ] Add GPT-OSS-120B as a separate model in OpenWebUI.
  - [ ] Add as a model in Cline with long context settings.
  - [ ] Test on a **copy** of the Logic Apps repo to avoid misfires.

### A4. Integrate with Logic Apps Documentation Tool (Mid December)

- [ ] Capture current workflow
  - [ ] Write a short README snippet or note: “How I use ChatGPT today for this project.”
- [ ] Create a **local-only** profile
  - [ ] OpenWebUI / LibreChat preset that targets GPT-OSS-120B only.
  - [ ] Token / context settings tuned to your typical prompts (big context, short diff‑style output).
- [ ] Run a real task with GPT-OSS-120B
  - [ ] Use it to assist in going from v1.0 → v1.1 of the Logic Apps tool.
  - [ ] Compare quality vs ChatGPT: clarity, hallucinations, refactor help.
- [ ] Define success criteria
  - [ ] “I can comfortably use GPT-OSS-120B for half a day on this project without needing to bail out to ChatGPT.”
  - [ ] Latency is acceptable for your work cadence (even if slower per token).

---

## Gift B: Creative Writing + Media Stack for the Novel

### B1. Choose and Stand Up a Creative Model (Late Dec / Early Jan)

- [ ] Shortlist candidates
  - [ ] Dolphin‑Mistral‑24B (Venice) – you already have it; good baseline.
  - [ ] Larger creative model (Dolphin‑70B / Mistral‑Large / similar) for richer prose.
  - [ ] Possibly also test GPT-OSS-120B for creative work.
- [ ] Stand up one candidate at a time
  - [ ] Add GGUF/HF weights to `/opt/ai-models`.
  - [ ] New llama.cpp or vLLM service for the creative model.
  - [ ] At least ~32k context; stretch to 64k if stable.
- [ ] Run **chapter‑level tests**
  - [ ] Feed in a single chapter + notes and ask for a scene rewrite.
  - [ ] Ask for continuity checks (names, locations, tone).
  - [ ] Note which model “gets you” stylistically.
- [ ] Pick a **primary co‑writer model** by early January.

### B2. Integrate into Writing Workflow (Early January)

- [ ] Define the “Second Draft Ritual”
  - [ ] How you’ll feed in chapters (one at a time? 2–3 at a time?).
  - [ ] What you ask it for: line edits, tone tightening, plot‑hole hunting, etc.
- [ ] Set up IDE / editor integration
  - [ ] VSCode + Cline pointing at the creative model for inline edits.
  - [ ] Or use OpenWebUI with a dedicated “Novel Draft 2” space.
- [ ] Milestone: by early January
  - [ ] You’ve run at least **two chapters** fully through the new co‑writer model.
  - [ ] You feel it’s adding genuine value, not just noise.

### B3. Image Generation for the Cover (January)

- [ ] Pick the image stack
  - [ ] ComfyUI on a GPU with enough VRAM.
  - [ ] Or an existing local SD/WebUI you trust.
- [ ] Prepare prompts and references
  - [ ] A 2–3 paragraph “back cover blurb” to feed into the image system.
  - [ ] Style references (artists, vibes, color palettes) written down.
- [ ] Milestones
  - [ ] [ ] First rough cover concept generated.
  - [ ] [ ] Refined cover you’d be willing to show friends.
  - [ ] [ ] Final export in print + ebook resolutions.

### B4. Audio Generation for a “Not-Terrible” Audiobook (January → Feb)

- [ ] Choose TTS stack
  - [ ] At least one high‑quality local TTS (e.g., neural voices, good prosody).
  - [ ] Decide on 1–2 voices that fit the book.
- [ ] Wire TTS into a simple pipeline
  - [ ] Take chapter text → TTS → WAV/MP3.
  - [ ] Simple folder structure: `audio/chapters/ch01.mp3`, etc.
- [ ] Milestones
  - [ ] [ ] First full chapter rendered as audio.
  - [ ] [ ] Fix obvious mispronunciations (character names, places).
  - [ ] [ ] Render 3–5 key chapters you’d be proud to share.

### B5. End-to-End “Book Flow” (By Birthday)

- [ ] Run one complete loop
  - [ ] Take a chapter from rough draft → LLM revision → final text.
  - [ ] Generate or tweak a cover concept.
  - [ ] Produce a chapter audio file.
- [ ] Success definition
  - [ ] “If the internet vanished tomorrow, I could still:
    - Use my local model to revise the novel.
    - Make new cover variants.
    - Export decent audio for friends.”

---

## Parking Lot / TBD

- [ ] Evaluate multi-node clustering (two Sparks) for even larger models **after** GPT-OSS-120B is boringly stable.
- [ ] Decide how much of this stack you want version‑controlled (Docker compose files, configs, prompt templates).
- [ ] Revisit Qwen‑Omni / multimodal **only if** there’s a clear use case beyond text.

