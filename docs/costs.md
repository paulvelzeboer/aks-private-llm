# Cost model

> **Estimates only.** Figures are rough **West Europe pay-as-you-go** rates and change
> often; Spot prices in particular fluctuate by the hour and region. Treat this as a shape,
> not a quote — always confirm in the
> [Azure Pricing Calculator](https://azure.microsoft.com/pricing/calculator/). Excludes data
> egress, taxes, and support plans. ~730 hours/month assumed for always-on items.

## The two parts of the bill

Cost splits into a **fixed security perimeter** (always on while the platform exists) and the
**GPU** (the dominant, variable line — and where Spot helps).

### Fixed perimeter — always on

| Component | SKU | ~ Rate | ~ Monthly |
|---|---|---|---|
| Azure Firewall | Standard | ~$1.25/hr + $0.016/GB | **~$900** |
| Azure Bastion | Standard | ~$0.29/hr + egress | ~$210 |
| System node pool | 2× Standard_D4s_v5 | ~$0.192/hr each | ~$280 |
| Managed Grafana | Standard | ~$0.09/hr | ~$65 |
| Log Analytics | PAYG ingest | ~$2.76/GB | ~$30–85 |
| Managed Prometheus | per samples | ~$0.16/10M | ~$10–30 |
| ACR | Premium (private endpoints) | ~$1.67/day | ~$50 |
| Blob (weights) | ~150 GB Standard LRS | ~$0.02/GB | ~$3 |
| Public IPs | 2× Standard static | ~$3.6 each | ~$7 |
| **Perimeter subtotal** | | | **~$1,550–1,600** |

Azure Firewall Standard is the single biggest fixed cost. It is the enforcement + audit point
for the air-gap, so it is load-bearing — but see the levers below if the posture allows a cheaper SKU.

### GPU — the dominant, variable line

`Standard_NC24ads_A100_v4` = 1× A100 80 GB.

| Mode | ~ Rate | ~ Monthly (24/7) |
|---|---|---|
| On-demand | ~$3.40–3.67/hr | **~$2,500–2,680** |
| **Spot (this repo's default)** | ~$0.70–1.40/hr (varies) | **~$500–1,000** |
| Spot + scale-to-zero | pay only for running hours | e.g. ~170 h/mo ≈ **~$120–240** |

Spot typically saves **~60–90%** versus on-demand. The tradeoff: Azure can reclaim Spot capacity
with ~30 seconds' notice, so the model pod may be evicted and restarted when capacity is tight.
For a controlled internal inference service that is usually acceptable; if you need guaranteed
uptime, set the GPU pool back to on-demand (`priority` / `eviction_policy` in `terraform/aks.tf`).

## Scenarios (perimeter + GPU)

| Scenario | ~ Monthly |
|---|---|
| On-demand GPU, 24/7 | **~$4,100–4,300** |
| **Spot GPU, 24/7 (default)** | **~$2,100–2,600** |
| Spot GPU, business hours only (~170 h, scale to zero) | **~$1,700–1,850** |

Once you scale the GPU down, the fixed perimeter dominates — so the biggest remaining lever is
the perimeter SKUs, not the GPU.

## Cost levers (in rough order of impact)

1. **Keep Spot** (already the default) — the largest single saving.
2. **Scale the GPU pool to zero when idle.** `gpu_min_count = 0` is already set, so the *pool*
   can empty; to actually drop to zero, scale the vLLM Deployment to 0 replicas when not in use
   (`kubectl -n llm scale deploy/vllm --replicas=0`), or drive it with KEDA on request volume.
3. **Cheaper perimeter if the posture allows:** Azure Firewall **Basic** (~$0.40/hr vs $1.25) or
   Bastion **Developer/Basic**. These reduce controls/throughput — weigh against the air-gap
   requirements before changing.
4. **Smaller GPU SKU** for smaller models (e.g. a single L4/A10 class) cuts the GPU rate sharply.
5. **Drop Managed Grafana** and rely on Log Analytics dashboards if you don't need Prometheus UI.
6. **Right-size Log Analytics retention** (default 90 days in `terraform/aks.tf`).

## Tuning knobs (Terraform variables)

| Variable | Default | Effect |
|---|---|---|
| `gpu_spot_max_price` | `-1` | Max $/hr for Spot (`-1` = up to on-demand, evict on capacity only) |
| `gpu_min_count` | `0` | Autoscaler floor; `0` allows scale-to-zero |
| `gpu_node_count` | `1` | Initial GPU nodes |
| `gpu_node_max_count` | `3` | Autoscaler ceiling |
| `gpu_node_vm_size` | `Standard_NC24ads_A100_v4` | GPU SKU |
