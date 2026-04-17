#!/usr/bin/env bash
# =============================================================================
# Armada Bridge — GitOps Bootstrap
# Installs: Helm, ArgoCD, Sealed Secrets, kubeseal CLI, ArgoCD CLI
# Usage: bash bootstrap.sh
# =============================================================================
set -euo pipefail

ARGOCD_HTTP_PORT="30080"
ARGOCD_HTTPS_PORT="30443"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info()    { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()     { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# =============================================================================
# Step 1 — Helm
# =============================================================================
info "=== Step 1: Install Helm ==="
if command -v helm &>/dev/null; then
  info "Helm already installed: $(helm version --short)"
else
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  info "Helm installed: $(helm version --short)"
fi

# =============================================================================
# Step 2 — ArgoCD
# =============================================================================
info "=== Step 2: Install ArgoCD ==="
kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

if helm status argocd -n argocd &>/dev/null; then
  info "ArgoCD already installed, skipping."
else
  helm install argocd argo/argo-cd \
    --namespace argocd \
    --set server.service.type=NodePort \
    --set server.service.nodePorts.http="${ARGOCD_HTTP_PORT}" \
    --set server.service.nodePorts.https="${ARGOCD_HTTPS_PORT}" \
    --set configs.params."server\.insecure"=true \
    --wait
  info "ArgoCD installed."
fi

ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath="{.data.password}" 2>/dev/null | base64 -d || echo "(secret not found — already changed)")

info "ArgoCD UI : http://$(hostname -I | awk '{print $1}'):${ARGOCD_HTTP_PORT}"
info "Login     : admin / ${ARGOCD_PASSWORD}"

# =============================================================================
# Step 3 — Sealed Secrets
# =============================================================================
info "=== Step 3: Install Sealed Secrets ==="
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets 2>/dev/null || true
helm repo update sealed-secrets

if helm status sealed-secrets -n kube-system &>/dev/null; then
  info "Sealed Secrets already installed, skipping."
else
  helm install sealed-secrets sealed-secrets/sealed-secrets \
    --namespace kube-system \
    --set fullnameOverride=sealed-secrets-controller \
    --wait
  info "Sealed Secrets installed."
fi

# =============================================================================
# Step 4 — kubeseal CLI
# =============================================================================
info "=== Step 4: Install kubeseal CLI ==="
if command -v kubeseal &>/dev/null; then
  info "kubeseal already installed: $(kubeseal --version)"
else
  KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest \
    | grep tag_name | cut -d '"' -f 4 | sed 's/v//')

  if [[ -z "${KUBESEAL_VERSION}" ]]; then
    KUBESEAL_VERSION="0.27.3"
    warn "Could not detect latest kubeseal version, defaulting to ${KUBESEAL_VERSION}"
  fi

  curl -Lo /tmp/kubeseal.tar.gz \
    "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
  tar xzf /tmp/kubeseal.tar.gz -C /tmp kubeseal
  sudo mv /tmp/kubeseal /usr/local/bin/kubeseal
  rm -f /tmp/kubeseal.tar.gz
  info "kubeseal installed: $(kubeseal --version)"
fi

# =============================================================================
# Step 5 — ArgoCD CLI
# =============================================================================
info "=== Step 5: Install ArgoCD CLI ==="
if command -v argocd &>/dev/null; then
  info "ArgoCD CLI already installed: $(argocd version --client --short 2>/dev/null || echo 'installed')"
else
  curl -sSL -o /tmp/argocd-linux-amd64 \
    https://github.com/argoproj/argo-cd/releases/latest/download/argocd-linux-amd64
  sudo install -m 555 /tmp/argocd-linux-amd64 /usr/local/bin/argocd
  rm -f /tmp/argocd-linux-amd64
  info "ArgoCD CLI installed."
fi

# Login to ArgoCD
if [[ "${ARGOCD_PASSWORD}" != "(secret not found"* ]]; then
  argocd login "localhost:${ARGOCD_HTTP_PORT}" \
    --username admin \
    --password "${ARGOCD_PASSWORD}" \
    --insecure 2>/dev/null && info "ArgoCD CLI logged in." || warn "ArgoCD CLI login failed — retry manually."
fi

# =============================================================================
# Step 6 — Verify
# =============================================================================
info "=== Step 6: Verify ==="
echo ""
echo "ArgoCD pods:"
kubectl get pods -n argocd

echo ""
echo "Sealed Secrets:"
kubectl get pods -n kube-system | grep sealed

echo ""
info "Bootstrap complete."
info "ArgoCD UI : http://$(hostname -I | awk '{print $1}'):${ARGOCD_HTTP_PORT}"
info "Password  : ${ARGOCD_PASSWORD}"
