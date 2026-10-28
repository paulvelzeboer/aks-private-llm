# Private, air-gapped LLM on AKS

A fully controlled self-hosted LLM platform on Azure Kubernetes Service. Open-weight
models run on GPU nodes behind a private network with **default-deny egress**, every
request is authenticated and audited, and nothing — control plane, inference API, or
registry — is exposed to the internet. Clients talk to it through an OpenAI-compatible
endpoint on a private IP.

```
                         ┌───────────────────────── Azure VNet 10.42.0.0/16 (no public ingress) ─────────────────────────┐
                         │                                                                                                │
   operator ──Bastion──▶ │  jumpbox ──kubectl / curl──▶  [internal LB :4000]                                              │
   (Entra ID)            │                                       │                                                        │
                         │                                       ▼                                                        │
                         │   namespace: gateway          ┌──────────────┐    auth (virtual keys) + budgets               │
                         │                                │   LiteLLM    │    + FULL prompt/response audit ──▶ stdout     │
                         │                                └──────┬───────┘                                   │            │
                         │                                       │ (NetworkPolicy: gateway→llm:8000 only)    │            │
                         │   namespace: llm   GPU pool    ┌──────▼───────┐                                   │            │
                         │   (default-deny egress)        │  vLLM :8000  │◀── weights (blob, private EP)     │            │
                         │                                └──────────────┘                                   │            │
                         │                                       ▲                                           │            │
                         │   images ◀── ACR (private EP)   ──────┘                                           ▼            │
                         │                                                                          Log Analytics        │
                         │        all node egress ──UDR──▶ [Azure Firewall: DEFAULT DENY + log] ─────────────┘            │
                         └────────────────────────────────────────────────────────────────────────────────────────────┘
                                                                    │ (only mandatory AKS platform FQDNs, logged)
                                                                    ▼ everything else DENIED
```

## What "controlled" means here

| Requirement | How it is enforced |
|---|---|
| External data blocked | AKS `outbound_type = userDefinedRouting` → all node traffic hits an Azure Firewall whose policy is **default-deny**. Pods also get a `default-deny` NetworkPolicy (Cilium). The model pod has zero outbound except cluster DNS. |
| Air-gapped artifacts | ACR + model-weights blob have `public_network_access = false` and are reachable only via private endpoints. Images and weights are seeded **once** (`seed-artifacts.sh`); at runtime vLLM runs with `HF_HUB_OFFLINE=1`. |
| Monitored | Firewall logs (every allow **and** deny), Container Insights, and LiteLLM's per-request audit all stream to Log Analytics (KQL in `kubernetes/observability/audit-queries.kql`). Live metrics go to **Managed Prometheus**; dashboards in **Managed Grafana** (import `kubernetes/observability/grafana-dashboard-vllm.json`). Both private. |
| Controlled access | Private API server, no local accounts (Entra ID + Azure RBAC). The LLM API is an **internal** load balancer; reachable only inside the VNet via Bastion/VPN. LiteLLM issues per-client virtual keys with budgets. |
| CLI access | OpenAI-compatible endpoint → **GitHub Copilot CLI** (BYOK), the `llm` CLI, aider, Continue, Cline, or the OpenAI SDK. See `docs/connect-copilot-cli.md` and `scripts/connect-cli.sh`. |

> **On "fully air-gapped":** Azure's *managed* AKS control plane requires a small set of
> platform FQDNs (control-plane registration, MCR system images, Entra, time). These carry
> **no workload data** and are the only allow rules in `firewall.tf`; everything else is denied
> and logged. From the data/workload perspective the cluster is air-gapped. For a *literal* zero-FQDN
> air-gap you additionally need a private package mirror and a private MCR cache in ACR, then
> remove the firewall allow rules — see `docs/architecture.md`.

> **On Copilot CLI:** GitHub Copilot CLI supports a custom OpenAI-compatible provider (BYOK) via
> `COPILOT_PROVIDER_BASE_URL` + `COPILOT_MODEL`, so it can point at this platform's private endpoint
> (the model must expose tool calling + streaming, which the deployment enables). Step-by-step in
> [`docs/connect-copilot-cli.md`](docs/connect-copilot-cli.md). Any other base-URL-aware client
> (`llm`, aider, Continue, Cline, OpenAI/Azure SDKs) works against the same endpoint too.

## Layout

```
terraform/   VNet, private AKS + GPU pool, Azure Firewall egress lockdown,
             private ACR + blob, Bastion + jumpbox, Log Analytics
kubernetes/
  base/      namespaces, NetworkPolicies, NVIDIA device plugin, model weights, vLLM
  gateway/   LiteLLM auth + audit proxy on an internal load balancer
  observability/  Log Analytics KQL audit queries, Managed Prometheus scrape
                  config, importable Grafana dashboard
scripts/     seed-artifacts.sh (one-time ingress), deploy.sh, connect-cli.sh
docs/        architecture.md — decisions, tradeoffs, hardening path
             running-a-model.md — serve/swap a model + Llama 3.1 8B example
             connect-copilot-cli.md — point GitHub Copilot CLI at the endpoint
             costs.md — cost model, Spot savings, cost levers
```

## Deploy

Prereqs: Azure subscription with GPU quota for the chosen SKU, `az`, `terraform`, `kubectl`,
an SSH public key, and a one-time download of your model weights.

```bash
# 1. Infra (from anywhere with Azure access)
cd terraform && terraform init && terraform apply

# 2. Seed the air-gap (from a host that can reach the private endpoints)
ACR=<acr> STORAGE_ACCOUNT=<sa> MODEL_LOCAL_DIR=./model ../scripts/seed-artifacts.sh

# 3+4. Workloads (from the jumpbox, via Bastion — the API server is private)
../scripts/deploy.sh

# Talk to it
LLM_KEY=<virtual-key> ../scripts/connect-cli.sh
```

`deploy.sh` runs the whole sequence; the steps are listed separately above so you can see
where the trust boundary (step 2, the only controlled ingress) sits.

### Dashboards

`deploy.sh` applies the Prometheus scrape config and restarts the agent. To see the dashboards:

```bash
terraform -chdir=terraform output grafana_endpoint   # private Grafana URL
# Open it from the jumpbox (via Bastion), then import:
#   kubernetes/observability/grafana-dashboard-vllm.json
# Pick the auto-provisioned Managed Prometheus datasource when prompted.
```

Grafana is private, so log in from inside the VNet. Set `grafana_admin_object_id` (your Entra
object ID) in Terraform to get Grafana Admin, or assign the role afterwards. GPU hardware panels
(SM %, memory, temp) need a DCGM exporter DaemonSet seeded into ACR; the included vLLM KV-cache
panel approximates GPU pressure without it.

## Cost

The GPU pool dominates the bill, so it runs on **Spot by default** (`priority = "Spot"` in
`terraform/aks.tf`) — typically **~60–90% cheaper** than on-demand, with the tradeoff that Azure
can reclaim the node (~30s notice) and the model pod restarts. `gpu_min_count = 0` also lets the
pool scale to zero when idle.

Rough West Europe pay-as-you-go monthly estimates (full breakdown + levers in
[`docs/costs.md`](docs/costs.md)):

| Scenario | ~ Monthly |
|---|---|
| On-demand GPU, 24/7 | ~$4,100–4,300 |
| **Spot GPU, 24/7 (default)** | **~$2,100–2,600** |
| Spot GPU, business hours + scale-to-zero | ~$1,700–1,850 |

A fixed security perimeter (Azure Firewall ~$900/mo, Bastion, system pool, observability) is
~$1,550/mo and stays up while the platform exists — once the GPU scales down, it dominates. For
guaranteed uptime, switch the GPU pool back to on-demand. See `docs/costs.md` for cheaper-SKU levers.
