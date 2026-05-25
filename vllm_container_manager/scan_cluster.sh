#!/usr/bin/env bash
# scan_cluster.sh — probe all nodes/ports for running models + env dump
set -euo pipefail

NODES=("192.168.2.42:magnesium" "192.168.2.43:aluminium" "192.168.2.44:silicon" "192.168.2.45:phosphorus")
PORTS=(8000 8001 8002 8003)

echo "=== Cluster Model Scan: $(date) ==="
echo ""

for node_entry in "${NODES[@]}"; do
  IFS=':' read -r ip name <<< "${node_entry}"
  echo "--- ${name} (${ip}) ---"

  # Dump container env if vllm container exists
  container_name=$(ssh -o ConnectTimeout=2 admin@${ip} \
    "sudo docker ps --format '{{.Names}}' 2>/dev/null | grep vllm | head -1" 2>/dev/null || true)

  if [[ -n "${container_name}" ]]; then
    echo "  Container: ${container_name}"
    echo "  Env:"
    ssh admin@${ip} "sudo docker exec ${container_name} env 2>/dev/null" \
      | grep -E 'SERVED_MODEL|TOOL_CALL|REASONING|TENSOR_PARALLEL|MAX_MODEL_LEN|GPU_MEMORY' \
      | sort | sed 's/^/    /'
  else
    echo "  Container: none"
  fi

  # Probe ports
  for port in "${PORTS[@]}"; do
    result=$(curl -sf --connect-timeout 2 "http://${ip}:${port}/v1/models" 2>/dev/null || true)
    if [[ -n "${result}" ]]; then
      models=$(echo "${result}" | jq -r '.data[].id' 2>/dev/null | paste -sd',' -)
      echo "  :${port} → ${models}"
    else
      echo "  :${port} → (no response)"
    fi
  done
  echo ""
done

echo "=== Scan complete ==="
