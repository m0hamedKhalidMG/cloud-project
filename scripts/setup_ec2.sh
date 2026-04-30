#!/usr/bin/env bash
# =============================================================================
# CISC 886 – Sections 6 & 7: EC2 Setup, Ollama Deployment, OpenWebUI
# File: scripts/setup_ec2.sh
#
# Run this script on the EC2 instance after SSH-ing in:
#   ssh -i ~/.ssh/id_rsa ubuntu@<EC2_PUBLIC_IP>
#   bash setup_ec2.sh
#
# The script is idempotent: re-running it after a reboot is safe.
# =============================================================================

set -euo pipefail

NETID="20596365"                          # Replace with your actual netID
MODEL_FILE="${NETID}-llama3.2-3b-alpaca-Q4_K_M.gguf"
MODEL_DIR="/home/ubuntu/models"
OLLAMA_MODEL_NAME="${NETID}-llama3-alpaca"

# ---------------------------------------------------------------------------
# 1. System update and essential packages
# ---------------------------------------------------------------------------
echo "[1/7] Updating system packages..."
sudo apt-get update -y
sudo apt-get install -y curl docker.io docker-compose

# Allow ubuntu user to run docker without sudo
sudo usermod -aG docker ubuntu
newgrp docker || true   # activate without requiring re-login in the same shell

# ---------------------------------------------------------------------------
# 2. Install Ollama
#    The official install script downloads the appropriate binary for the
#    current OS/arch, creates a systemd service, and starts it immediately.
# ---------------------------------------------------------------------------
echo "[2/7] Installing Ollama..."
curl -fsSL https://ollama.com/install.sh | sh

# Verify Ollama is running
sleep 3
ollama list && echo "Ollama service is up."

# ---------------------------------------------------------------------------
# 3. Upload the fine-tuned GGUF model
#    This step assumes you have already scp'd the GGUF file to ~/models/
#    from your local machine or Colab session.
#
#    From your LOCAL machine (run once before this script):
#      scp -i ~/.ssh/id_rsa <LOCAL_PATH_TO_GGUF> \
#          ubuntu@<EC2_PUBLIC_IP>:~/models/
# ---------------------------------------------------------------------------
echo "[3/7] Checking for GGUF model file..."
mkdir -p "${MODEL_DIR}"

if [[ ! -f "${MODEL_DIR}/${MODEL_FILE}" ]]; then
    echo "ERROR: GGUF file not found at ${MODEL_DIR}/${MODEL_FILE}"
    echo "Please upload it with:"
    echo "  scp -i ~/.ssh/id_rsa ${MODEL_FILE} ubuntu@<EC2_IP>:${MODEL_DIR}/"
    exit 1
fi

# ---------------------------------------------------------------------------
# 4. Create an Ollama Modelfile and load the GGUF into Ollama
#    The Modelfile sets:
#      FROM       : path to the GGUF weights
#      PARAMETER  : inference defaults (temperature, context size)
#      SYSTEM     : system prompt shown before every conversation
# ---------------------------------------------------------------------------
echo "[4/7] Creating Ollama Modelfile..."
cat > /tmp/Modelfile <<EOF
FROM ${MODEL_DIR}/${MODEL_FILE}

PARAMETER temperature 0.7
PARAMETER num_ctx 2048
PARAMETER stop "<|eot_id|>"

SYSTEM """
You are a helpful, harmless, and honest AI assistant fine-tuned on instruction-following data.
Answer questions clearly and concisely.
"""
EOF

echo "[4/7] Loading model into Ollama (this may take a few minutes)..."
ollama create "${OLLAMA_MODEL_NAME}" -f /tmp/Modelfile

# Confirm the model is registered
echo "Registered Ollama models:"
ollama list

# ---------------------------------------------------------------------------
# 5. Test the model via curl (required for Section 6 deliverable)
#    Copy the output of this command into your report as the curl screenshot.
# ---------------------------------------------------------------------------
echo "[5/7] Testing model via curl..."
curl -s http://localhost:11434/api/generate \
    -d "{
        \"model\": \"${OLLAMA_MODEL_NAME}\",
        \"prompt\": \"Explain what cloud computing is in one sentence.\",
        \"stream\": false
    }" | python3 -m json.tool

# ---------------------------------------------------------------------------
# 6. Install and start OpenWebUI via Docker
#    OpenWebUI is configured to talk to the Ollama API on localhost:11434.
#    We bind port 3000 on the host (matching the security group rule).
#    --add-host host.docker.internal:host-gateway lets the container reach
#    the host's Ollama service.
#    --restart always ensures OpenWebUI restarts automatically after a
#    server reboot (satisfies the Section 7 auto-start requirement).
# ---------------------------------------------------------------------------
echo "[6/7] Starting OpenWebUI..."
docker pull ghcr.io/open-webui/open-webui:main

docker run -d \
    --name open-webui \
    --restart always \
    -p 3000:8080 \
    --add-host host.docker.internal:host-gateway \
    -e OLLAMA_BASE_URL=http://host.docker.internal:11434 \
    -v open-webui:/app/backend/data \
    ghcr.io/open-webui/open-webui:main

# Confirm container is running
docker ps --filter name=open-webui

# ---------------------------------------------------------------------------
# 7. Create a systemd service for Ollama auto-start (belt-and-suspenders)
#    Ollama's install script already creates a systemd unit, but we enable
#    it explicitly here to be certain it starts on reboot.
# ---------------------------------------------------------------------------
echo "[7/7] Enabling Ollama systemd service..."
sudo systemctl enable ollama
sudo systemctl status ollama --no-pager

echo ""
echo "============================================================"
echo "  Deployment complete!"
echo "  Ollama API : http://$(curl -s ifconfig.me):11434"
echo "  OpenWebUI  : http://$(curl -s ifconfig.me):3000"
echo "  Model name : ${OLLAMA_MODEL_NAME}"
echo "============================================================"
echo ""
echo "SECTION 6 curl command for your report:"
echo "  curl http://$(curl -s ifconfig.me):11434/api/generate \\"
echo "    -d '{\"model\":\"${OLLAMA_MODEL_NAME}\",\"prompt\":\"Hello!\",\"stream\":false}'"
