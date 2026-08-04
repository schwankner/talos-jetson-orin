#!/usr/bin/env bash
# deploy-vllm-agx.sh — Deploy the AGX-only vLLM service on NodePort 31435.
#
# This replaces the Ollama AGX deployment. The API is OpenAI-compatible at /v1.
set -euo pipefail
source "$(dirname "$0")/common.sh"

KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/kubeconfig-agx}"
MANIFEST="${MANIFEST:-${REPO_ROOT}/manifests/vllm/vllm-agx.yaml}"

check_kubectl
[[ -f "${MANIFEST}" ]] || error "Manifest not found: ${MANIFEST}"
[[ -f "${KUBECONFIG_PATH}" ]] || error "kubeconfig not found: ${KUBECONFIG_PATH}. Run talosctl kubeconfig first."

export KUBECONFIG="${KUBECONFIG_PATH}"

info "Removing ollama-agx namespace (if present)..."
kubectl delete namespace ollama-agx --ignore-not-found=true

info "Applying AGX-only vLLM manifest..."
kubectl apply -f "${MANIFEST}"

info "Waiting for rollout..."
kubectl rollout status deployment/vllm-agx -n vllm-agx --timeout=1800s

info "vLLM AGX is ready at: http://10.0.10.43:31435/v1"
info "Models API:           http://10.0.10.43:31435/v1/models"
info "Chat API:             http://10.0.10.43:31435/v1/chat/completions"
