# Architecture & decisions

## Threat model / goals

1. **No model or data egress.** A compromised or misbehaving model pod must not be able to
   exfiltrate prompts, weights, or anything else to the internet.
2. **No public attack surface.** Control plane, inference API, registry, and storage are all
   private. The only public IPs belong to the firewall (egress NAT) and Bastion (operator access).
3. **Full attributable audit.** Every inference request — who, what model, prompt, completion,
   tokens — is retained and queryable, as is every blocked egress attempt.
4. **Usable from a CLI** over an OpenAI-compatible API.

## Layered egress control (defence in depth)

| Layer | Mechanism | File |
|---|---|---|
| Pod | Cilium `default-deny` NetworkPolicy per namespace; only DNS + the one allowed hop | `kubernetes/base/10-network-policies.yaml` |
| Node → VNet edge | `outbound_type = userDefinedRouting`; UDR 0.0.0.0/0 → firewall | `terraform/aks.tf`, `network.tf` |
| VNet edge | Azure Firewall policy, **default deny**, threat-intel deny, allow only platform FQDNs | `terraform/firewall.tf` |
| Artifact sources | ACR + blob `public_network_access = false`, private endpoints only | `terraform/registry.tf` |
| Runtime | `HF_HUB_OFFLINE=1`, `TRANSFORMERS_OFFLINE=1` on vLLM | `kubernetes/base/30-vllm.yaml` |

Any single layer failing still leaves the others. The firewall is the authoritative audit point
for egress because it sees and logs traffic from every pod regardless of NetworkPolicy state.

## Key decisions

**vLLM over Ollama.** Production throughput, continuous batching, tensor parallelism, and solid
OpenAI tool-calling. Ollama is simpler but lower throughput; swap the `llm` namespace Deployment
if you prefer it — the gateway and network model are unchanged.

**LiteLLM as the gateway.** It is the single control/audit plane: OpenAI-compatible surface,
virtual API keys with per-key budgets and rate limits, and per-request logging. This keeps vLLM
itself unauthenticated-but-unreachable (only the gateway can reach it, enforced by NetworkPolicy),
and puts all policy in one auditable place. For stateless operation drop the `database_url` and use
the master key only; for multi-tenant attribution keep Postgres.

**Internal load balancer, not Ingress/App Gateway.** The brief is a private endpoint for CLI
clients, not a public web app. An internal LB gives a stable private VNet IP with no public surface.
Add Private DNS + a VPN/ExpressRoute if clients live outside this VNet.

**Managed observability, not a self-hosted Prometheus/Grafana stack.** Two complementary planes,
both Azure-managed so nothing new is exposed or operated:

- *Audit / logs* — Container Insights, firewall diagnostics, and LiteLLM per-request logs into
  **Log Analytics** (query with `audit-queries.kql`). This is the forensic, attributable record.
- *Live metrics* — the in-cluster `ama-metrics` agent (`monitor_metrics {}`) scrapes vLLM
  (`:8000/metrics`) and LiteLLM (`:4000/metrics`) via `ama-metrics-config.yaml` into an Azure
  Monitor workspace (**Managed Prometheus**), surfaced in **Managed Grafana** by importing
  `grafana-dashboard-vllm.json`. Grafana is private (`public_network_access = false`), reached from
  the VNet like every other surface.

Running a self-hosted Prometheus/Grafana would duplicate this and add an operational burden and a
TSDB to secure, for no gain. GPU-level panels (SM utilisation, memory, temp) need a DCGM exporter
DaemonSet, seeded like the other images; the vLLM KV-cache panel already proxies GPU pressure
without it.

**Bastion + jumpbox for access.** The API server is private (`private_cluster_enabled = true`), so
`kubectl` and the LLM endpoint are only reachable from inside the VNet. Bastion gives browser/SSH
access with no inbound ports on any VM; Entra ID + Azure RBAC replace local cluster accounts.

## The one controlled ingress

`scripts/seed-artifacts.sh` is the single, deliberate door through which anything enters the
air-gap: `az acr import` copies images into private ACR, and the model weights are uploaded to
private blob. This runs once, from an operator host, and is the thing to gate with change control.
After it, the cluster needs no internet.

## Hardening path to a literal zero-FQDN air-gap

The default keeps the mandatory AKS platform FQDNs in the firewall allowlist (control-plane only,
no data). To remove even those:

1. Enable an **ACR cache** / mirror for `mcr.microsoft.com` system images so node bootstrap pulls
   from ACR over the private endpoint.
2. Host a **private OS package mirror** (Ubuntu/Mariner) in the VNet for node security updates.
3. Point NTP at an in-VNet time source.
4. Delete the `application_rule_collection` allow rules in `firewall.tf`; the firewall then denies
   100% of egress. Expect to manage node image/security updates manually.

## Scaling

- **More throughput:** raise `gpu_node_max_count` and vLLM `replicas`; LiteLLM round-robins.
- **Bigger model:** multi-GPU node SKU + `--tensor-parallel-size=N`.
- **Idle cost:** autoscale the GPU pool to zero; the perimeter (firewall, Bastion) stays up.
