#!/usr/bin/env bash
# One-time controlled ingress: pull the images and model weights the cluster
# needs INTO the private ACR and blob container. Run this from an operator
# machine that has internet AND line-of-sight to the private endpoints
# (e.g. the jumpbox, or over VPN). After this, the cluster needs no internet.
#
# This is the single, auditable door through which anything enters the air-gap.
set -euo pipefail

: "${ACR:?set ACR to the registry name, e.g. acrprivllm}"
: "${STORAGE_ACCOUNT:?set STORAGE_ACCOUNT, e.g. stprivllmmodels}"
: "${MODEL_LOCAL_DIR:?set MODEL_LOCAL_DIR to the downloaded weights directory}"

# ---- 1. Images: import from public registries into private ACR -----------
# az acr import reaches out once; the cluster only ever pulls from ACR.
images=(
  "docker.io/vllm/vllm-openai:v0.6.3|vllm/vllm-openai:v0.6.3"
  "ghcr.io/berriai/litellm:main-stable|berriai/litellm:main-stable"
  "nvcr.io/nvidia/k8s-device-plugin:v0.16.2|nvidia/k8s-device-plugin:v0.16.2"
)
for entry in "${images[@]}"; do
  src="${entry%%|*}"; dst="${entry##*|}"
  echo ">> importing $src -> $ACR/$dst"
  az acr import --name "$ACR" --source "$src" --image "$dst" --force
done

# ---- 2. Weights: upload the model directory to the private blob container -
# Download the model once (e.g. huggingface-cli download <repo> --local-dir ...)
# into MODEL_LOCAL_DIR, then push it under weights/current/.
echo ">> uploading weights from $MODEL_LOCAL_DIR to $STORAGE_ACCOUNT/weights/current"
az storage blob upload-batch \
  --account-name "$STORAGE_ACCOUNT" \
  --destination "weights/current" \
  --source "$MODEL_LOCAL_DIR" \
  --auth-mode login \
  --overwrite

echo "Seed complete. The cluster can now run fully air-gapped."
