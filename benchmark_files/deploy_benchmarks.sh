#!/usr/bin/env bash
# Deploy benchmark suite to Node 1 (magnesium)
# Run this from your Mac to copy everything over

set -e

NODE1="admin@192.168.2.42"
REMOTE_DIR="/home/admin/benchmarks"

echo "=== Deploying Benchmark Suite to Node 1 ==="

# Create remote directory
ssh "$NODE1" "mkdir -p $REMOTE_DIR"

# Copy benchmark scripts
scp benchmark_suite.sh "$NODE1:$REMOTE_DIR/"
scp compare_results.sh "$NODE1:$REMOTE_DIR/"

# Make executable
ssh "$NODE1" "chmod +x $REMOTE_DIR/*.sh"

echo "✅ Benchmark suite deployed to $NODE1:$REMOTE_DIR"
echo ""
echo "Next steps:"
echo "  1. Wait for Qwen3-VL-235B to finish loading"
echo "  2. SSH to Node 1: ssh $NODE1"
echo "  3. Run: cd ~/benchmarks && ./benchmark_suite.sh current ./results/qwen3vl_235b"
