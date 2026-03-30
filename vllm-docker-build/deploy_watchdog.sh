echo "=== Creating build watchdog on phosphorus ==="

cat > /tmp/vllm_build_watchdog.sh << 'WATCHDOG_EOF'
#!/usr/bin/env bash
set -euo pipefail

BUILD_LOG="/home/agentdev/vllm-build/build.log"
STATUS_FILE="/opt/ai-tools/logs/build_status.txt"
CHECK_INTERVAL=1200
MAX_STALL_TIME=7200

last_size=0
stall_count=0

echo "=== vLLM Build Watchdog Started at $(date) ===" | tee -a "${STATUS_FILE}"

while true; do
  if [[ ! -f "${BUILD_LOG}" ]]; then
    echo "[$(date)] Waiting for build log to appear..." | tee -a "${STATUS_FILE}"
    sleep "${CHECK_INTERVAL}"
    continue
  fi

  current_size=$(stat -c%s "${BUILD_LOG}" 2>/dev/null || echo 0)
  
  if [[ "${current_size}" -eq "${last_size}" ]]; then
    ((stall_count++))
    stall_duration=$((stall_count * CHECK_INTERVAL))
    
    if [[ "${stall_duration}" -gt "${MAX_STALL_TIME}" ]]; then
      echo "[$(date)] BUILD STALLED - No log growth for ${stall_duration}s" | tee -a "${STATUS_FILE}"
      tail -100 "${BUILD_LOG}" > /tmp/build_failure.log
      echo "Last 100 lines saved to /tmp/build_failure.log" | tee -a "${STATUS_FILE}"
      break
    fi
  else
    stall_count=0
  fi
  
  if grep -q "Successfully built" "${BUILD_LOG}"; then
    echo "[$(date)] BUILD SUCCESS - Image created" | tee -a "${STATUS_FILE}"
    break
  fi
  
  if grep -q "ERROR\|FAILED\|fatal:" "${BUILD_LOG}"; then
    echo "[$(date)] BUILD FAILED - Error detected" | tee -a "${STATUS_FILE}"
    tail -100 "${BUILD_LOG}" > /tmp/build_failure.log
    break
  fi
  
  echo "[$(date)] Build running... (${current_size} bytes)" | tee -a "${STATUS_FILE}"
  last_size="${current_size}"
  sleep "${CHECK_INTERVAL}"
done

echo "[$(date)] Watchdog completed" | tee -a "${STATUS_FILE}"
WATCHDOG_EOF

echo "=== Copying watchdog to phosphorus ==="
scp /tmp/vllm_build_watchdog.sh admin@10.10.10.4:/tmp/

echo "=== Starting watchdog in tmux on phosphorus ==="
ssh admin@10.10.10.4 << 'REMOTE_EOF'
chmod +x /tmp/vllm_build_watchdog.sh
tmux new-session -d -s build_watchdog '/tmp/vllm_build_watchdog.sh'
echo "Watchdog running in tmux session 'build_watchdog'"
echo "Check status: tmux attach -t build_watchdog"
echo "Or read: /opt/ai-tools/logs/build_status.txt"
REMOTE_EOF
