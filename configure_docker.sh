#!/bin/bash

# Configure insecure registry on all nodes
# Run from helium (your local machine)

NODES=("192.168.2.42" "192.168.2.43" "192.168.2.44" "192.168.2.45")
NODE_NAMES=("magnesium" "aluminium" "silicon" "phosphorus")

for i in "${!NODES[@]}"; do
    NODE="${NODES[$i]}"
    NAME="${NODE_NAMES[$i]}"
    
    echo "=========================================="
    echo "Configuring $NAME ($NODE)..."
    echo "=========================================="
    
    ssh admin@$NODE << 'ENDSSH'
# Stop Docker
sudo systemctl stop docker

# Create daemon.json
sudo mkdir -p /etc/docker
sudo tee /etc/docker/daemon.json > /dev/null << 'EOF'
{
  "insecure-registries": ["192.168.2.42:5000"]
}
EOF

# Start Docker
sudo systemctl start docker

# Verify
echo "Docker status:"
sudo systemctl status docker --no-pager | head -5
echo ""
echo "Registry config:"
cat /etc/docker/daemon.json
ENDSSH
    
    echo "✓ $NAME configured"
    echo ""
done

echo "=========================================="
echo "✓ All nodes configured"
echo "=========================================="
