#!/usr/bin/env bash
# cluster_favorites.sh
#
# Sourced by vllm_cluster_orchestrator.sh at startup.
# Defines profile aliases (FAVORITES) and multi-step action sequences (SEQUENCES).
#
# Usage from orchestrator:
#   ./vllm_cluster_orchestrator.sh fav ds4-up
#   ./vllm_cluster_orchestrator.sh fav list
#
# Adding a favorite alias:
#   FAVORITES[ds4]="deepseek-v4-flash"
#
# Adding a sequence:
#   Define a function named seq_<name>() that calls orchestrator commands
#   directly (they run in the same process), then register it:
#   SEQUENCES[ds4-up]="seq_ds4_up|Spin down nodes 3+4, bring up DeepSeek V4 Flash"
#   Format: "function_name|Human-readable description"

# ==============================================================================
# Profile Aliases
# ==============================================================================
# Short names that expand to full profile keys in MODELS[].
# These are resolved before any orchestrator command runs.
#
declare -A FAVORITES=(
  # DeepSeek V4 Flash
  [ds4]="deepseek-v4-flash"
  [ds4-tp2]="deepseek-v4-flash-tp2"
  [ds4-local]="deepseek-v4-flash-tp2-local"

  # Qwen3.5
  [q122]="qwen3.5-122b-tp1-cust"
  [q122-univ]="qwen3.5-122b-tp1-univ"
  [q122-fallback]="qwen3.5-122b"
  [q397]="qwen3.5-397b-autoround"
  [q397-tp4]="qwen3.5-397b-autoround-tp4"
  [q9b]="qwen3.5-9b"
  [q9b-bf16]="qwen3.5-9b-bf16"

  # GLM
  [glm]="glm-4.7"

  # MiniMax
  [mm]="minimax-m2.7"
  [mm-tp2]="minimax-m2.7-tp2"

  # Qwen3 VL
  [vl235]="qwen3-vl-235b"
)

# ==============================================================================
# Multi-Step Sequences
# ==============================================================================
# Each sequence is a shell function (seq_<name>) plus a registration entry.
# Functions call the orchestrator's cmd_* functions directly — they run in the
# same process and have full access to ACTIVE_NODES and all config.
#
# Convention: sequences should log what they're doing at each step.
# They may call cmd_stop_cluster, cmd_start_cluster, cmd_load_model directly.
#
# Registration format:
#   SEQUENCES[alias]="function_name|Description shown in fav list"

declare -A SEQUENCES=()

# ------------------------------------------------------------------------------
# ds4-up: Stop nodes 3+4, bring up DeepSeek V4 Flash (TP=4 across all nodes)
# ------------------------------------------------------------------------------
seq_ds4_up() {
  Log "[fav] ds4-up: stopping all nodes..."
  ACTIVE_NODES=(1 2 3 4)
  cmd_stop_cluster

  Log "[fav] ds4-up: starting cluster for deepseek-v4-flash..."
  ACTIVE_NODES=(1 2 3 4)
  cmd_start_cluster "deepseek-v4-flash"

  Log "[fav] ds4-up: loading model..."
  ACTIVE_NODES=(1 2 3 4)
  cmd_load_model "deepseek-v4-flash"
}
SEQUENCES[ds4-up]="seq_ds4_up|Stop all nodes, start DeepSeek V4 Flash TP=4 across all nodes"

# ------------------------------------------------------------------------------
# ds4-tp2-up: DeepSeek V4 Flash on nodes 3+4 only (TP=2)
# ------------------------------------------------------------------------------
seq_ds4_tp2_up() {
  Log "[fav] ds4-tp2-up: stopping nodes 3,4..."
  ACTIVE_NODES=(3 4)
  cmd_stop_cluster

  Log "[fav] ds4-tp2-up: starting cluster..."
  ACTIVE_NODES=(3 4)
  cmd_start_cluster "deepseek-v4-flash-tp2"

  Log "[fav] ds4-tp2-up: loading model..."
  ACTIVE_NODES=(3 4)
  cmd_load_model "deepseek-v4-flash-tp2"
}
SEQUENCES[ds4-tp2-up]="seq_ds4_tp2_up|DeepSeek V4 Flash TP=2 on nodes 3+4"

# ------------------------------------------------------------------------------
# glm-up: GLM-4.7 on all four nodes (TP=4)
# ------------------------------------------------------------------------------
seq_glm_up() {
  Log "[fav] glm-up: stopping all nodes..."
  ACTIVE_NODES=(1 2 3 4)
  cmd_stop_cluster

  Log "[fav] glm-up: starting cluster..."
  ACTIVE_NODES=(1 2 3 4)
  cmd_start_cluster "glm-4.7"

  Log "[fav] glm-up: loading model..."
  ACTIVE_NODES=(1 2 3 4)
  cmd_load_model "glm-4.7"
}
SEQUENCES[glm-up]="seq_glm_up|Stop all nodes, start GLM-4.7 TP=4 across all nodes"

# ------------------------------------------------------------------------------
# q122-prod: Production 122B — independent TP=1 on nodes 1 and 2
# ------------------------------------------------------------------------------
seq_q122_prod() {
  Log "[fav] q122-prod: stopping nodes 1,2..."
  ACTIVE_NODES=(1 2)
  cmd_stop_cluster

  Log "[fav] q122-prod: starting node 1..."
  ACTIVE_NODES=(1)
  cmd_start_cluster "qwen3.5-122b-tp1-cust"
  cmd_load_model "qwen3.5-122b-tp1-cust"

  Log "[fav] q122-prod: starting node 2..."
  ACTIVE_NODES=(2)
  cmd_start_cluster "qwen3.5-122b-tp1-cust"
  cmd_load_model "qwen3.5-122b-tp1-cust"
}
SEQUENCES[q122-prod]="seq_q122_prod|Production 122B: independent TP=1 on nodes 1+2 behind HAProxy"

# ------------------------------------------------------------------------------
# q397-heavy: 397B AutoRound on nodes 1+2 (TP=2), leave 3+4 free
# ------------------------------------------------------------------------------
seq_q397_heavy() {
  Log "[fav] q397-heavy: stopping nodes 1,2..."
  ACTIVE_NODES=(1 2)
  cmd_stop_cluster

  Log "[fav] q397-heavy: starting cluster..."
  ACTIVE_NODES=(1 2)
  cmd_start_cluster "qwen3.5-397b-autoround"

  Log "[fav] q397-heavy: loading model..."
  ACTIVE_NODES=(1 2)
  cmd_load_model "qwen3.5-397b-autoround"
}
SEQUENCES[q397-heavy]="seq_q397_heavy|397B AutoRound TP=2 on nodes 1+2, leaves 3+4 free"

# ------------------------------------------------------------------------------
# mm-tp2: MiniMax M2.7 on nodes 3+4 (TP=2)
# ------------------------------------------------------------------------------
seq_mm_tp2() {
  Log "[fav] mm-tp2: stopping nodes 3,4..."
  ACTIVE_NODES=(3 4)
  cmd_stop_cluster

  Log "[fav] mm-tp2: starting cluster..."
  ACTIVE_NODES=(3 4)
  cmd_start_cluster "minimax-m2.7-tp2"

  Log "[fav] mm-tp2: loading model..."
  ACTIVE_NODES=(3 4)
  cmd_load_model "minimax-m2.7-tp2"
}
SEQUENCES[mm-tp2]="seq_mm_tp2|MiniMax M2.7 TP=2 on nodes 3+4"

# ==============================================================================
# Resolver (used by orchestrator — do not remove)
# ==============================================================================
# Expands a favorite alias to a full profile name.
# Returns the input unchanged if it's not a registered alias.
resolve_favorite() {
  local input="$1"
  echo "${FAVORITES[$input]:-$input}"
}

# Checks if a string is a registered sequence name.
is_sequence() {
  local name="$1"
  [[ -n "${SEQUENCES[$name]:-}" ]]
}

# Runs a registered sequence by name.
run_sequence() {
  local name="$1"
  local entry="${SEQUENCES[$name]:-}"
  [[ -z "$entry" ]] && { Log "ERROR: No sequence named '${name}'"; return 1; }
  local fn
  fn="$(echo "$entry" | cut -d'|' -f1)"
  Log "Running sequence: ${name}"
  "${fn}"
}
