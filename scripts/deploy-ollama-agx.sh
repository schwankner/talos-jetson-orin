#!/usr/bin/env bash
# deploy-ollama-agx.sh — Deploy an AGX-only Ollama service on NodePort 31435.
#
# This targets only the isolated AGX cluster at 10.0.10.43.
# The model is pre-pulled in an initContainer so the first request is ready faster.
set -euo pipefail
source "$(dirname "$0")/common.sh"

NODE_IP="${NODE_IP:-10.0.10.43}"
KUBECONFIG_PATH="${KUBECONFIG_PATH:-${REPO_ROOT}/kubeconfig-agx}"
MANIFEST="${MANIFEST:-${REPO_ROOT}/manifests/ollama/ollama-agx.yaml}"

check_kubectl
[[ -f "${MANIFEST}" ]] || error "Manifest not found: ${MANIFEST}"
[[ -f "${KUBECONFIG_PATH}" ]] || error "kubeconfig not found: ${KUBECONFIG_PATH}. Run talosctl kubeconfig first."

export KUBECONFIG="${KUBECONFIG_PATH}"

info "Applying AGX-only Ollama manifest..."
kubectl apply -f "${MANIFEST}"

info "Waiting for rollout..."
kubectl rollout status deployment/ollama-agx -n ollama-agx --timeout=600s

info "Ollama AGX is ready at: http://${NODE_IP}:31435"
info "Models API:         http://${NODE_IP}:31435/api/tags"
info "Generate API:       http://${NODE_IP}:31435/api/generate"
