# Cluster Orchestration Kit — Architecture Spec

Version: 1.0  
Last updated: 2026-06-28

This document describes how the cluster orchestration kit is structured, why it
works the way it does, and what a port to a new service type (ComfyUI, TTS,
WhisperX, SGLang, etc.) needs to implement.

---

## What This Kit Is

A thin SSH fan-out layer that manages Docker containers on a 4-node DGX Spark
cluster. It has three responsibilities:

1. **Start containers** on the right nodes with the right image and env.
2. **Exec commands** inside those containers (start Ray, load model, stop).
3. **Query state** by label or API probe without assuming names.

It is deliberately not a full orchestrator (no Kubernetes, no Nomad). The
cluster is small, homogeneous, and airgapped. The complexity budget goes into
model-specific configuration (Ray vs mp executor, TP size, port assignments,
memory tuning), not into general scheduling.

---

## File Map

```
cluster_config.sh            — Node definitions + model/service profiles (data only)
cluster_favorites.sh         — Profile aliases + multi-step sequences
cluster.env                  — API keys (local only, never deployed to nodes)
cluster.env.template         — Committed template; copy to cluster.env and fill in
vllm_cluster_orchestrator.sh — Outer shell: SSH fan-out for vLLM workloads
vllm_cluster_mgr.sh          — Inner script: runs INSIDE containers (Ray + vLLM)
scan_cluster.sh              — Standalone probe: ports + env dump across all nodes
docs/SPEC.md                 — This file
```

For a new service type, you add:

```
{service}_cluster_orchestrator.sh   — Outer shell for that service
```

And optionally (if the service has a non-trivial inner lifecycle):

```
{service}_cluster_mgr.sh            — Inner script for that service
```

---

## Node Definitions (`cluster_config.sh`)

```bash
declare -A NODES=(
  [1]="192.168.2.42:magnesium:10.10.10.1"
  [2]="192.168.2.43:aluminium:10.10.10.2"
  [3]="192.168.2.44:silicon:10.10.10.3"
  [4]="192.168.2.45:phosphorus:10.10.10.4"
)
# Format: LAN_IP:HOSTNAME:FABRIC_IP
# LAN_IP    — management/SSH network (192.168.2.x)
# HOSTNAME  — human name (magnesium, aluminium, silicon, phosphorus)
# FABRIC_IP — RDMA/NCCL network (10.10.10.x)
```

Node definitions are shared across all orchestrators. A new service type
sources `cluster_config.sh` to get `NODES`, `SSH_USER`, and `LOG_DIR`.

---

## Container Naming

Every container is named:

```
{prefix}--{profile}--n{node_num}
```

Examples:
```
vllm--qwen3.5-9b-bf16--n1
vllm--deepseek-v4-flash--n3
comfyui--sdxl-flux--n3
tts--chatterbox-turbo--n2
```

**The name is deterministic** — constructed from profile + node number, never
discovered at runtime. This means:

- `docker rm`, `docker exec`, and `docker ps --filter name=` all use
  `container_name_for(profile, node)`.
- Surgical stop can target exactly one container without touching its
  co-tenants on the same node.
- Two containers on the same node never collide as long as their profiles
  differ (which they must, by definition).

### `container_name_for` (in orchestrator)

```bash
container_name_for() {
  local profile="$1"
  local node_num="$2"
  local prefix
  prefix=$(extract_profile_field "$profile" "CONTAINER_PREFIX" "vllm")
  echo "${prefix}--${profile}--n${node_num}"
}
```

A new service type either:
- Sets `CONTAINER_PREFIX=comfyui` in each profile, or
- Hardcodes the prefix in its own `container_name_for` override.

---

## Docker Labels

Every container gets these labels at `docker run` time:

| Label                | Value                         | Purpose                              |
|----------------------|-------------------------------|--------------------------------------|
| `cluster.profile`    | profile key (e.g. `glm-4.7`) | Which profile this container runs    |
| `cluster.service`    | service type (e.g. `vllm`)   | Which orchestrator owns it           |
| `cluster.node`       | node number (1–4)             | Which node it lives on               |
| `cluster.served_name`| served model name             | Human-readable identity for status   |

`cluster.service` is the primary filter for "nuclear stop" (kill everything
managed on this node). A `comfyui` container and a `vllm` container on the
same node are both found by `docker ps --filter 'label=cluster.service'` —
nuclear stop kills both. Surgical stop targets only the specified profile.

---

## Profile Fields Reference

All profile fields live inside a `declare -A MODELS` entry in
`cluster_config.sh`. Fields are parsed by `extract_profile_field()` in the
orchestrator. Unknown fields are silently injected as env vars into the
container.

### Core fields (all service types)

| Field              | Type   | Default    | Description                                  |
|--------------------|--------|------------|----------------------------------------------|
| `CONTAINER_PREFIX` | string | `vllm`     | Prefix for container name                    |
| `SERVICE_TYPE`     | string | `vllm`     | Used in `cluster.service` label              |
| `DOCKER_IMAGE`     | string | (required) | Key into `CUSTOM_IMAGES` or full image path  |

### vLLM-specific fields

| Field                      | Description                                               |
|----------------------------|-----------------------------------------------------------|
| `MODEL_DIR`                | Path to model weights (local SSD or NFS)                  |
| `SERVED_MODEL_NAME`        | Name(s) exposed via `/v1/models` (comma-separated)        |
| `TENSOR_PARALLEL_SIZE`     | Number of GPUs / nodes for this model                     |
| `CLUSTER_EXECUTOR_BACKEND` | `ray` or `mp` (multiprocessing, no Ray)                   |
| `VLLM_API_PORT`            | HTTP API port (do NOT use `VLLM_PORT` — ZMQ conflict)     |
| `VLLM_MASTER_PORT`         | PyTorch/NCCL rendezvous port (default: 29500)             |
| `GPU_MEMORY_UTILIZATION`   | Fraction of GPU memory for vLLM (0.0–1.0)                 |
| `MAX_MODEL_LEN`            | Context window in tokens                                  |
| `MAX_NUM_SEQS`             | Max concurrent sequences                                  |
| `KV_CACHE_DTYPE`           | `auto`, `fp8`, `bfloat16`                                 |
| `QUANTIZATION`             | `awq`, `awq_marlin`, `fp8`, etc. (omit for ct format)     |
| `ENFORCE_EAGER`            | `0` = CUDA graphs enabled, `1` = eager only               |
| `ENABLE_PREFIX_CACHING`    | `0` or `1` (must be `0` for DeltaNet/Mamba hybrids)       |
| `TOOL_CALL_PARSER`         | Parser name for tool calling                              |
| `REASONING_PARSER`         | Parser name for chain-of-thought / thinking tokens        |
| `LOAD_FORMAT`              | `safetensors`, `instanttensor`, etc.                      |
| `RAY_OBJECT_STORE_GB`      | Ray object store size per node                            |
| `VLLM_EXTRA_ARGS`          | Appended verbatim to vLLM CLI (e.g. `--disable-custom-all-reduce`) |

Any field not consumed by `extract_profile_field()` explicitly is injected
into the container as an environment variable. This is the extension mechanism:
add a new env var to a profile and it appears inside the container.

---

## The `.env` Injection Pattern

`cluster.env` is sourced **locally** by the orchestrator at startup. Values
are passed to containers via `-e KEY=VALUE` at `docker run` and `docker exec`
time. Keys are never written to disk on the nodes.

The orchestrator builds `ENV_INJECT_ARGS` at startup:

```bash
ENV_INJECT_ARGS=""
while IFS= read -r line; do
  [[ -z "$line" || "$line" =~ ^# ]] && continue
  [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]] || continue
  key="${line%%=*}"; value="${line#*=}"
  [[ -z "$value" ]] && continue
  ENV_INJECT_ARGS="${ENV_INJECT_ARGS} -e ${key}=$(printf '%q' "${value}")"
done < "${ENV_FILE}"
```

`ENV_INJECT_ARGS` is appended to every `docker run` and `docker exec` call.
A new orchestrator for a different service type can source the same `.env`
and use the same `ENV_INJECT_ARGS` variable — no extra work.

---

## Surgical vs Nuclear Stop

```
stop-cluster              → nuclear: kill all managed containers on selected nodes
stop-cluster PROFILE      → surgical: kill only containers for this profile
```

Nuclear stop queries `docker ps --filter 'label=cluster.service'` — it finds
any container that was started by any orchestrator in this kit, regardless of
name or service type. It also cleans up legacy `vllm-node-N` containers
(pre-rename-scheme) for backward compatibility during migration.

Surgical stop constructs the exact container name via `container_name_for()`
and targets only that name. It cannot accidentally kill a co-tenant.

---

## Porting to a New Service Type

To add ComfyUI, TTS, WhisperX, or any other containerized service:

### 1. Add profiles to `cluster_config.sh`

```bash
declare -A COMFYUI_MODELS=(
  [sdxl-flux]="
    CONTAINER_PREFIX=comfyui
    SERVICE_TYPE=comfyui
    DOCKER_IMAGE=comfyui-dgx
    COMFYUI_PORT=8188
    GPU_MEMORY_UTILIZATION=0.90
  "
)
```

Or extend the existing `MODELS` array — whatever keeps the config readable.
The orchestrator for that service type reads its own profile map.

### 2. Write `{service}_cluster_orchestrator.sh`

Copy `vllm_cluster_orchestrator.sh` as a starting point. You must keep:

- `source cluster_config.sh` (node defs)
- `source cluster_favorites.sh` (aliases, sequences)
- The `.env` sourcing block (`ENV_INJECT_ARGS`)
- `container_name_for()` — or override it if the naming scheme differs
- Docker label set (`cluster.profile`, `cluster.service`, `cluster.node`, `cluster.served_name`)
- `cmd_stop_cluster()` with nuclear/surgical modes

You replace:

- `ensure_container()` — remove vLLM/Ray-specific flags; add service-specific ports/volumes
- `cmd_load_model()` — replace with your service's start command
- `_wait_for_vllm()` — replace with your service's health check
- `VLLM_PROBE_PORTS` — replace with your service's API ports

You can delete:

- All Ray start/stop logic (unless your service uses Ray)
- `vllm_cluster_mgr.sh` copy/exec (unless your service has a similar inner script)
- Page cache drop logic (vLLM-specific; NFS weight loading fills the kernel page cache)

### 3. Write `{service}_cluster_mgr.sh` (optional)

Only needed if your service has a non-trivial inner lifecycle (process management,
health checking, graceful shutdown) that needs to run *inside* the container.
Simple services (ComfyUI, WhisperX) can just start directly in `docker run`
with a real entrypoint instead of `sleep infinity` + exec.

### 4. Add sequences to `cluster_favorites.sh`

```bash
seq_comfyui_up() {
  Log "[fav] comfyui-up: stopping node 3..."
  ACTIVE_NODES=(3)
  # Call your orchestrator's commands directly
  comfyui_cmd_stop_cluster
  comfyui_cmd_start "sdxl-flux"
}
SEQUENCES[comfyui-up]="seq_comfyui_up|Start ComfyUI SDXL+Flux on node 3"
```

Or add cross-orchestrator sequences (e.g., tear down GLM on nodes 1-4, bring
up 397B on 1-2, bring up ComfyUI on 3).

---

## Co-tenancy Notes

Multiple containers can run on the same node simultaneously as long as:

1. They have different profiles (and therefore different container names).
2. They don't fight over GPU memory. The `GPU_MEMORY_UTILIZATION` field for
   each profile must be sized so the sum leaves headroom. vLLM claims its
   allocation at startup — start the heavy model first, then the lighter
   co-tenant, so vLLM claims its share before the co-tenant sees available
   memory.
3. They don't share ports. Each profile must specify a unique `VLLM_API_PORT`
   (or equivalent) per node.

Planned co-tenant map (when 397B TP=4 is running at GPU_MEM_UTIL=0.80):
```
magnesium  (node 1) → Whisper STT   (~3GB,  port 8103)
aluminium  (node 2) → Fish2 TTS     (~4GB,  port 8104)
silicon    (node 3) → ComfyUI       (light workflows only, port 8188)
phosphorus (node 4) → Qwen3.5-9B   (~18GB, port 8002)
```

---

## Known Constraints and Gotchas

**`VLLM_PORT` is reserved.** vLLM uses it internally for ZMQ IPC between the
API server and EngineCore. Setting it externally causes a port conflict. Always
use `VLLM_API_PORT` in profiles; the mgr script handles the alias.

**NFS page cache exhaustion.** Loading large models from NFS fills the kernel
page cache. The orchestrator drops page cache at 5 windows during weight
loading (15–25%, 35–45%, 55–65%, 75–85%, 90%+). This is specific to the NFS
weight path — local SSD loads don't need it.

**TP=2 OOM on unified memory.** At TP=2, vLLM's Marlin weight prep spike
(~20GB transient) can exceed available memory on unified-memory GPUs. Symptoms:
Ray OOM kill during startup, or NFS page cache exhaustion. Mitigations: local
SSD weight path, `CLUSTER_EXECUTOR_BACKEND=mp` (bypasses Ray OOM monitor),
`GPU_MEMORY_UTILIZATION` tuned below 0.88.

**DeltaNet / Mamba hybrid models.** Qwen3.5 GDN models require
`ENABLE_PREFIX_CACHING=0` (hybrid linear attention crashes with prefix cache)
and `MAX_NUM_BATCHED_TOKENS>=8192` (Mamba block size = 4176). Do not set
`QUANTIZATION` for compressed-tensors format models.

**`COMPILATION_CONFIG` JSON.** The `extract_profile_field` parser uses
`cut -d'=' -f2`, which breaks on values containing `=` (JSON booleans, etc.).
For profiles using `COMPILATION_CONFIG`, the value is passed verbatim as an
env var; verify the container sees it correctly with `docker exec env | grep COMP`.
