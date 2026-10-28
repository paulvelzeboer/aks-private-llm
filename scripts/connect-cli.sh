#!/usr/bin/env bash
# Talk to the private LLM from a CLI. Run on the jumpbox (or any VNet host),
# because the gateway lives on an internal load balancer only.
#
# The endpoint is OpenAI-compatible, so any client that accepts a base URL
# works: GitHub Copilot CLI (BYOK — see docs/connect-copilot-cli.md), the `llm`
# CLI, aider, Continue, Cline, Claude Code (OpenAI base override), or the
# openai SDK.
set -euo pipefail

GW_IP=$(kubectl -n gateway get svc litellm -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
BASE="http://${GW_IP}:4000/v1"
: "${LLM_KEY:?export LLM_KEY to a virtual key minted from the LiteLLM master key}"

echo "Private LLM endpoint: $BASE"

# --- raw curl smoke test ---------------------------------------------------
curl -sS "$BASE/chat/completions" \
  -H "Authorization: Bearer $LLM_KEY" \
  -H "Content-Type: application/json" \
  -d '{"model":"private-llm","messages":[{"role":"user","content":"Say hello in one line."}]}' | jq .

cat <<EOF

# --- wire up the 'llm' CLI (Simon Willison) -------------------------------
pip install llm
export OPENAI_API_BASE="$BASE"
export OPENAI_API_KEY="\$LLM_KEY"
llm -m private-llm "Summarise this repo's security posture."

# --- or aider --------------------------------------------------------------
export OPENAI_API_BASE="$BASE"
export OPENAI_API_KEY="\$LLM_KEY"
aider --model openai/private-llm

# --- or GitHub Copilot CLI (BYOK) -----------------------------------------
# npm install -g @github/copilot   # sign in to GitHub on first run
export COPILOT_PROVIDER_BASE_URL="$BASE"
export COPILOT_MODEL="private-llm"
export COPILOT_PROVIDER_API_KEY="\$LLM_KEY"
copilot -p "Explain this repo's security posture." --model private-llm
# Full guide + gotchas: docs/connect-copilot-cli.md

# --- or the openai python SDK ---------------------------------------------
# from openai import OpenAI
# client = OpenAI(base_url="$BASE", api_key="\$LLM_KEY")
# client.chat.completions.create(model="private-llm", messages=[...])
EOF
