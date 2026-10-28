# Running a model

## How serving works here

Because the cluster is air-gapped, a model is never downloaded at runtime. The flow is:

```
download once (operator, online) ──▶ upload to private blob (weights/current/)
          │                                      │
          │                                      ▼
          │                        blob mounted read-only at /models/current
          ▼                                      │
   seed-artifacts.sh                             ▼
                                   vLLM serves it as model "private-llm" on :8000
```

The weights live under `weights/current/` in the private storage account (mounted at
`/models/current`). vLLM always advertises the model under the stable name **`private-llm`**,
so clients never change when you swap the underlying weights — only the blob contents change.

vLLM runs with `HF_HUB_OFFLINE=1`, so it will fail fast rather than ever reach HuggingFace.

## Example: Llama 3.1 8B Instruct (the default)

`meta-llama/Llama-3.1-8B-Instruct` is the most widely used open instruct model and fits
comfortably on one A100 80 GB. It is what `kubernetes/base/30-vllm.yaml` is configured for.

> Llama 3.1 is **license-gated** on HuggingFace: accept the license on the model page once,
> then authenticate `huggingface-cli` with a token. For an ungated alternative with the same
> steps, use `Qwen/Qwen2.5-7B-Instruct` (set `--tool-call-parser=hermes` instead of `llama3_json`).

### 1. Download the weights once (on an online operator host)

```bash
pip install -U "huggingface_hub[cli]"
huggingface-cli login                       # paste an HF token that accepted the license

mkdir -p ./model
huggingface-cli download meta-llama/Llama-3.1-8B-Instruct \
  --local-dir ./model \
  --exclude "original/*"                     # skip the raw PyTorch checkpoint; keep safetensors
```

### 2. Seed it into the air-gap

```bash
ACR=<acr-name> STORAGE_ACCOUNT=<storage-account> MODEL_LOCAL_DIR=./model \
  ./scripts/seed-artifacts.sh
```

This uploads `./model/*` to `weights/current/` in the private blob container (and imports the
vLLM/LiteLLM/device-plugin images into ACR if not already done).

### 3. Deploy / restart the server

```bash
kubectl apply -f kubernetes/base/30-vllm.yaml
kubectl -n llm rollout status deploy/vllm --timeout=15m   # first load pulls weights into the pod
```

The deployment already has the matching tool-calling flags for Llama 3.x:

```yaml
- --model=/models/current
- --served-model-name=private-llm
- --tensor-parallel-size=1          # = GPU count per node
- --max-model-len=16384
- --enable-auto-tool-choice
- --tool-call-parser=llama3_json
```

### 4. Verify (from the jumpbox)

```bash
LLM_KEY=<virtual-key> ./scripts/connect-cli.sh      # runs a chat + prints client setup
```

or directly:

```bash
GW_IP=$(kubectl -n gateway get svc litellm -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl -sS "http://$GW_IP:4000/v1/chat/completions" \
  -H "Authorization: Bearer $LLM_KEY" -H "Content-Type: application/json" \
  -d '{"model":"private-llm","messages":[{"role":"user","content":"Say hello in one line."}]}' | jq .
```

## Swapping or sizing a model

| Want | Change |
|---|---|
| A different model | Re-seed new weights to `weights/current/`, then `kubectl -n llm rollout restart deploy/vllm`. Keep the served name `private-llm` so clients are unaffected. |
| A bigger model (e.g. Llama 3.1 70B on 1×A100 80GB AWQ, or multi-GPU) | Raise `--tensor-parallel-size` to the GPU count and pick a multi-GPU `gpu_node_vm_size`; drop `--max-model-len` if VRAM is tight. |
| A non-Llama family | Set `--tool-call-parser` to that family's parser (`hermes` for Qwen, `mistral` for Mistral, etc.). Mismatched parser = broken tool calls. |
| Multiple models at once | Add more `model_list` entries in `kubernetes/gateway/litellm.yaml`, each pointing at its own vLLM Service. |

## Why tool calling is on

Copilot CLI and agentic clients (aider, Continue, Cline) require the model to support
**tool/function calling and streaming**. `--enable-auto-tool-choice` + the correct
`--tool-call-parser` enable it in vLLM. Without a matching parser the endpoint still answers
plain chat, but agent features silently fail. See [connect-copilot-cli.md](connect-copilot-cli.md).
