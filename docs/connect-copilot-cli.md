# Connect GitHub Copilot CLI to the private LLM

GitHub Copilot CLI supports a **custom OpenAI-compatible model provider (BYOK)**, so you can
point it at this platform's private endpoint instead of GitHub's hosted models. The vLLM server
here is OpenAI-compatible and has tool calling + streaming enabled, which Copilot CLI requires.

> **Where this runs:** Copilot CLI runs on the **operator side** — your laptop or the jumpbox —
> not inside the air-gapped cluster. The CLI itself still talks to GitHub to authenticate the
> agent, but **model inference is routed to your private endpoint**. Run it from a host on the
> VNet (the jumpbox, via Bastion) so it can reach the internal load balancer. The cluster stays
> air-gapped regardless of what the client does.

## Prerequisites

- Copilot CLI installed and signed in: `npm install -g @github/copilot` then `copilot` (it will
  prompt for GitHub auth on first run). A Copilot subscription is still needed to run the agent.
- A LiteLLM **virtual key** (`LLM_KEY`) minted from the gateway master key.
- Network line-of-sight to the gateway's internal IP (you are on the jumpbox/VNet).

## Configure the custom provider

Copilot CLI reads the provider from environment variables. `type` defaults to `openai`, which is
what vLLM/LiteLLM speak.

```bash
# Private gateway endpoint (OpenAI-compatible). Note the /v1 suffix.
GW_IP=$(kubectl -n gateway get svc litellm -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

export COPILOT_PROVIDER_BASE_URL="http://${GW_IP}:4000/v1"
export COPILOT_MODEL="private-llm"          # the served-model-name from vLLM
export COPILOT_PROVIDER_API_KEY="$LLM_KEY"  # your LiteLLM virtual key
```

Then launch and select the custom model:

```bash
copilot
# inside the session:
/model private-llm
```

or non-interactively:

```bash
copilot -p "Explain what terraform/firewall.tf enforces." --model private-llm
```

## Notes & gotchas

- **Tool calling is mandatory.** Copilot CLI only works with models that support function calling
  and streaming. The deployment enables this (`--enable-auto-tool-choice --tool-call-parser
  llama3_json`); if you swap to a non-Llama model, set the matching parser or agent actions fail.
  See [running-a-model.md](running-a-model.md).
- **Single auth header only.** Copilot CLI authenticates the provider with one `Authorization`
  header and cannot send custom headers — the LiteLLM virtual key works, but any gateway that
  needs extra headers will not.
- **HTTPS in production.** The example uses `http://` on the internal LB. For anything beyond a
  lab, terminate TLS (e.g. an internal ingress with a private CA) and use `https://`.
- **Variable names can change.** BYOK in Copilot CLI is evolving; if `COPILOT_PROVIDER_*` is
  rejected, check the current page:
  <https://docs.github.com/en/copilot/how-tos/copilot-cli/customize-copilot/use-byok-models>.

## Prefer a pure-OSS client?

If you'd rather not depend on a Copilot subscription, any base-URL-aware client gives the same
experience against the same endpoint — see `scripts/connect-cli.sh` for `llm`, `aider`, and the
OpenAI SDK, all pointed at `COPILOT_PROVIDER_BASE_URL` / `OPENAI_API_BASE`.
