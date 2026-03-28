# vLLM Cluster Orchestration for DGX Spark GB10

Multi-node vLLM orchestration system for running large language models across a 4-node Grace Hopper GB10 cluster with 100G RDMA networking.

## System Overview

**Hardware:**
- 4x NVIDIA GB10 (Grace Hopper GH200) nodes
- 100G RDMA fabric (10.10.10.x subnet)
- 1G management network (192.168.2.x subnet)
- Each node: 2x GPUs, 96-core Grace CPU, 480GB unified memory

**Network Topology:**
```
Node 1: magnesium    192.168.2.42 / 10.10.10.1
Node 2: aluminium    192.168.2.43 / 10.10.10.2
Node 3: silicon      192.168.2.44 / 10.10.10.3
Node 4: phosphorus   192.168.2.45 / 10.10.10.4
```

## Architecture

### Three-Layer Design

1. **`vllm_cluster_orchestrator.sh`** (Control Plane)
   - SSH orchestration across all nodes
   - Container lifecycle management
   - Image selection per model profile
   - Node filtering for multi-tenancy

2. **`vllm_cluster_mgr.sh`** (Node Agent)
   - Runs inside each Docker container
   - Ray cluster management (head/worker)
   - vLLM model loading
   - Status monitoring

3. **`cluster_config.sh`** (Configuration)
   - Node definitions
   - Docker image registry
   - Model profiles with all parameters
   - Network settings

## Quick Start

### 1. Configure Docker Registry Access

All nodes need to trust the local registry at `192.168.2.42:5000`:

```bash
# Run on your local machine
./configure_docker_registry.sh
```

This creates `/etc/docker/daemon.json` on all nodes with:
```json
{
  "insecure-registries": ["192.168.2.42:5000"]
}
```

### 2. Deploy the Cluster Manager

Copy the three scripts to your control machine:
```bash
# From your local machine or any node with SSH access
scp vllm_cluster_orchestrator.sh admin@192.168.2.42:~/
scp cluster_config.sh admin@192.168.2.42:~/
scp vllm_cluster_mgr.sh admin@192.168.2.42:~/
```

### 3. Run Your First Model

```bash
# Start 4-node cluster for DeepSeek-V3
./vllm_cluster_orchestrator.sh start-cluster 4 deepseek-v3
./vllm_cluster_orchestrator.sh load-model deepseek-v3

# Check status
./vllm_cluster_orchestrator.sh status

# Test the API
curl http://192.168.2.42:8000/v1/models

# Stop when done
./vllm_cluster_orchestrator.sh stop-model
./vllm_cluster_orchestrator.sh stop-cluster
```

## Available Docker Images

Configured in `cluster_config.sh` → `CUSTOM_IMAGES`:

| Image Name | Full Path | vLLM Version | Use Case |
|------------|-----------|--------------|----------|
| `vllm-official` | `vllm/vllm-openai:v0.17.1` | v0.17.1 | Qwen3-VL-235B (proven stable) |
| `vllm-gb10-community` | `scitrera/dgx-spark-vllm:0.14.0rc2-t5` | v0.14.0rc2 | Older DeepSeek/Qwen builds |
| `vllm-gb10-0.18.0` | `192.168.2.42:5000/vllm-gb10:0.18.0` | v0.18.0 | **NEW: DeepSeek V3/R1 with FlashMLA** |
| `vllm-nvidia-official` | `nvcr.io/nvidia/vllm:25.09-py3` | v25.09 | NVIDIA official build |

### What's in vllm-gb10:0.18.0?

**Built:** March 27, 2026 (146 minutes on phosphorus)

**Included:**
- ✅ vLLM v0.18.0
- ✅ PyTorch 2.10.0 + CUDA 12.6
- ✅ FlashAttention-2 (general attention)
- ✅ FlashMLA (DeepSeek Multi-head Latent Attention)
- ✅ Compute capability 12.1 (GB10-specific)
- ✅ Triton 3.6.0
- ✅ Punica kernels (multi-LoRA)

**Excluded:**
- ❌ FlashAttention-3 (doesn't compile on GB10 ARM with CUDA 12.6)
- ❌ DeepGEMM (requires CUDA 13.0)

**Best for:** DeepSeek V3, DeepSeek R1, DeepSeek-V3-dense

## Model Profiles

Configured in `cluster_config.sh` → `MODELS`:

### DeepSeek Models (use vllm-gb10-0.18.0)

**deepseek-v3-dense** - 4-node, 143K context
```bash
./vllm_cluster_orchestrator.sh start-cluster 4 deepseek-v3-dense
./vllm_cluster_orchestrator.sh load-model deepseek-v3-dense
```
- Image: `vllm-gb10-0.18.0` (local registry)
- TP: 4 nodes
- Context: 143,360 tokens
- Memory: 88% GPU utilization

**deepseek-v3** - 4-node, 143K context  
**deepseek-r1** - 4-node, 163K context (FP8 KV cache)  
**deepseek-v3-future** - 4-node, 163K context (FP8 KV cache, 2 seqs)

### Qwen Models

**qwen3-vl-235b** - 2-node, 200K context
```bash
./vllm_cluster_orchestrator.sh --nodes 1,2 start-cluster 2 qwen3-vl-235b
./vllm_cluster_orchestrator.sh --nodes 1,2 load-model qwen3-vl-235b
```
- Image: `vllm-official` (v0.17.1 - proven stable)
- TP: 2 nodes
- Vision-language model

**qwen3.5-122b** - 2-node, 131K context
- Image: `vllm-gb10-community`
- TP: 2 nodes

## Advanced Usage

### Multi-Tenancy (Run Multiple Models)

Run two models simultaneously on different node pairs:

```bash
# Qwen3-VL on nodes 1-2
./vllm_cluster_orchestrator.sh --nodes 1,2 start-cluster 2 qwen3-vl-235b
./vllm_cluster_orchestrator.sh --nodes 1,2 load-model qwen3-vl-235b

# Qwen3.5-122B on nodes 3-4
./vllm_cluster_orchestrator.sh --nodes 3,4 start-cluster 2 qwen3.5-122b
./vllm_cluster_orchestrator.sh --nodes 3,4 load-model qwen3.5-122b

# Now both are running!
# Qwen3-VL:     http://192.168.2.42:8000/v1
# Qwen3.5-122B: http://192.168.2.44:8000/v1
```

### Adding a New Model Profile

Edit `cluster_config.sh`:

```bash
declare -gA MODELS=(
  # ... existing models ...
  
  [my-new-model]="
    DOCKER_IMAGE=vllm-gb10-0.18.0
    MODEL_DIR=/opt/ai-models/hf/my-model-path
    SERVED_MODEL_NAME=my-model
    TENSOR_PARALLEL_SIZE=4
    QUANTIZATION=awq
    MAX_MODEL_LEN=32768
    MAX_NUM_SEQS=4
    GPU_MEMORY_UTILIZATION=0.90
    ENABLE_PREFIX_CACHING=1
    ENABLE_CHUNKED_PREFILL=1
    KV_CACHE_DTYPE=auto
    TRUST_REMOTE_CODE=1
    VLLM_PORT=8000
    RAY_OBJECT_STORE_GB=2
  "
)
```

### Adding a New Docker Image

1. Build or pull the image on node1 (magnesium)
2. Tag for local registry:
   ```bash
   docker tag my-image:tag 192.168.2.42:5000/my-image:tag
   docker push 192.168.2.42:5000/my-image:tag
   ```

3. Add to `cluster_config.sh`:
   ```bash
   declare -gA CUSTOM_IMAGES=(
     # ... existing images ...
     [my-custom-image]="192.168.2.42:5000/my-image:tag"
   )
   ```

4. Reference in model profiles:
   ```bash
   DOCKER_IMAGE=my-custom-image
   ```

## Commands Reference

### vllm_cluster_orchestrator.sh

**Cluster lifecycle:**
```bash
# Start N-node cluster (optionally pre-configure for a model profile)
./vllm_cluster_orchestrator.sh start-cluster N [PROFILE]

# Load a model profile
./vllm_cluster_orchestrator.sh load-model PROFILE

# Stop model (keep containers running)
./vllm_cluster_orchestrator.sh stop-model

# Check status
./vllm_cluster_orchestrator.sh status

# Stop all containers
./vllm_cluster_orchestrator.sh stop-cluster
```

**Node filtering:**
```bash
# Only use specific nodes
./vllm_cluster_orchestrator.sh --nodes 1,2 start-cluster 2 qwen3-vl-235b
./vllm_cluster_orchestrator.sh --nodes 1,2 load-model qwen3-vl-235b
```

## Troubleshooting

### Check Logs

**On head node (node 1):**
```bash
ssh admin@192.168.2.42
sudo docker exec -it vllm-node-1 bash
tail -f /opt/ai-tools/logs/vllm-cluster/vllm_chat-heavy_node1.log
tail -f /opt/ai-tools/logs/vllm-cluster/ray_node1.log
```

**On worker nodes:**
```bash
ssh admin@192.168.2.43  # node 2
sudo docker exec -it vllm-node-2 bash
tail -f /opt/ai-tools/logs/vllm-cluster/ray_node2.log
```

### Common Issues

**"No module named 'vllm'"**
- Wrong Docker image - check `DOCKER_IMAGE` in model profile
- Image not pulled - run `start-cluster` first

**"Tensor parallel size mismatch"**
- Not enough active nodes
- Check: `./vllm_cluster_orchestrator.sh --nodes 1,2,3,4 start-cluster 4`

**"Ray head not reachable"**
- RDMA network issue
- Check: `ssh admin@192.168.2.42 'ping 10.10.10.2'`
- Restart Ray: `./vllm_cluster_orchestrator.sh stop-cluster` then retry

**"Out of memory"**
- Lower `GPU_MEMORY_UTILIZATION` (try 0.85)
- Reduce `MAX_MODEL_LEN`
- Reduce `MAX_NUM_SEQS`

**"Docker registry HTTP error"**
- Run `configure_docker_registry.sh` on all nodes
- Verify: `cat /etc/docker/daemon.json` on each node

### Ray Dashboard

Access at `http://192.168.2.42:8265` (head node) to see:
- Node health
- GPU utilization
- Task distribution
- Object store usage

## Performance Tips

1. **Use RDMA fabric (10.10.10.x)** for Ray communication
2. **Enable prefix caching** for repeated prompts
3. **Enable chunked prefill** for long contexts
4. **Use FP8 KV cache** for 2x context at 163K+ tokens
5. **Tune `MAX_NUM_SEQS`** based on workload:
   - Throughput: 4-8 seqs
   - Latency: 1-2 seqs

## File Structure

```
/opt/ai-tools/
├── logs/vllm-cluster/          # Logs (mounted into containers)
│   ├── vllm_<model>_node1.log
│   ├── ray_node1.log
│   └── ...
└── run/vllm-cluster/           # State files (mounted into containers)
    ├── ray_node1.pid
    └── vllm_api.pid

~/                               # Control scripts (run from here)
├── vllm_cluster_orchestrator.sh
├── cluster_config.sh
└── vllm_cluster_mgr.sh
```

## Next Steps

### Build vLLM v0.18.0 with CUDA 13.0 (v1.1)

For models that benefit from FlashAttention-3 (Llama, Qwen, Mixtral):

```bash
# Edit Dockerfile.vllm-v0.18.0-gb10:
# - Change base: nvidia/cuda:13.0.0-devel-ubuntu24.04
# - Update PyTorch: --index-url https://download.pytorch.org/whl/cu130
# - Re-enable DeepGEMM build

# Build:
cd ~/vllm-build
./build_vllm_v0.18.0_gb10.sh

# Tag as v1.1:
docker tag vllm-gb10:0.18.0 192.168.2.42:5000/vllm-gb10:0.18.0-cuda13
docker push 192.168.2.42:5000/vllm-gb10:0.18.0-cuda13

# Add to cluster_config.sh:
[vllm-gb10-0.18.0-cuda13]="192.168.2.42:5000/vllm-gb10:0.18.0-cuda13"
```

## Support

**Logs:** `/opt/ai-tools/logs/vllm-cluster/`  
**State:** `/opt/ai-tools/run/vllm-cluster/`  
**Models:** `/opt/ai-models/hf/`

For issues with the orchestration system, check:
1. SSH connectivity: `ssh admin@192.168.2.42`
2. Docker running: `ssh admin@192.168.2.42 'sudo docker ps'`
3. RDMA network: `ping 10.10.10.1`
4. Registry access: `curl http://192.168.2.42:5000/v2/_catalog`
