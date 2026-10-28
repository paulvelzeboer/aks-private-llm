#!/usr/bin/env bash
# Full deploy. Run infra from anywhere with Azure access; run the kubectl steps
# from the jumpbox (via Bastion), since the API server is private.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "== 1/4 Infrastructure =="
cd "$here/terraform"
terraform init
terraform apply -auto-approve

ACR=$(terraform output -raw acr_login_server | cut -d. -f1)
STORAGE=$(terraform output -raw models_storage_account)
RG=$(terraform output -raw resource_group)
AKS=$(terraform output -raw aks_name)

echo "== 2/4 Seed images + weights into the private registry/storage =="
echo "Run, from a host that can reach the private endpoints:"
echo "  ACR=$ACR STORAGE_ACCOUNT=$STORAGE MODEL_LOCAL_DIR=./model ./scripts/seed-artifacts.sh"
read -r -p "Press enter once seeding is done..."

echo "== 3/4 Cluster credentials (private API — run this on the jumpbox) =="
az aks get-credentials --resource-group "$RG" --name "$AKS"

echo "== 4/4 Workloads =="
# Inject the storage key the blob PV needs.
KEY=$(az storage account keys list -n "$STORAGE" --query '[0].value' -o tsv)
sed \
  -e "s|<BASE64_ACCOUNT_NAME>|$(printf '%s' "$STORAGE" | base64)|" \
  -e "s|<BASE64_ACCOUNT_KEY>|$(printf '%s' "$KEY" | base64)|" \
  "$here/kubernetes/base/20-model-weights.yaml" | kubectl apply -f -

kubectl apply -f "$here/kubernetes/base/00-namespaces.yaml"
kubectl apply -f "$here/kubernetes/base/10-network-policies.yaml"
kubectl apply -f "$here/kubernetes/base/15-nvidia-device-plugin.yaml"
kubectl apply -f "$here/kubernetes/base/30-vllm.yaml"
kubectl apply -f "$here/kubernetes/gateway/litellm.yaml"

# Managed Prometheus: load the custom scrape config and restart the agent.
kubectl apply -f "$here/kubernetes/observability/ama-metrics-config.yaml"
kubectl -n kube-system rollout restart ds/ama-metrics-node deploy/ama-metrics || true

echo "Waiting for the private LLM endpoint IP..."
kubectl -n gateway get svc litellm -w

# Dashboards: import kubernetes/observability/grafana-dashboard-vllm.json into
# Managed Grafana (URL in 'terraform output grafana_endpoint'). Its Prometheus
# datasource is auto-provisioned from the Azure Monitor workspace.
