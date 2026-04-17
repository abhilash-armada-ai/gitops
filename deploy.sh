#!/usr/bin/env bash
# =============================================================================
# Armada Bridge — GitOps Bootstrap Script
#
# One-time bootstrap only. After Step 4, ArgoCD manages ALL deployments from
# https://github.com/abhilash-armada-ai/gitops — nothing is applied locally.
#
# Deployment order is enforced by ArgoCD sync waves (no shell polling):
#   infrastructure: wave 0 (longhorn) → wave 1 → wave 2 → wave 3
#   platform:       wave 1 (kamaji)   → wave 2 → wave 3 → wave 4
# =============================================================================
set -euo pipefail

ARGOCD_NS="argocd"

echo "=== Step 1: Create namespaces ==="
kubectl apply -f "$(dirname "$0")/namespaces.yaml"

echo ""
echo "=== Step 2: Register Helm repositories in ArgoCD ==="
# Public repos (no auth needed)
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: argocd-cm
  namespace: argocd
  labels:
    app.kubernetes.io/name: argocd-cm
EOF

# ArgoCD discovers public Helm repos automatically from Application specs.
# For the private GitLab Helm repo, register it:
echo "Registering private GitLab Helm repo..."
kubectl create secret generic gitlab-helm-repo \
  --namespace="${ARGOCD_NS}" \
  --from-literal=name=aarna-helm \
  --from-literal=url="https://gitlab.com/api/v4/projects/REPLACE_PROJECT_ID/packages/helm/devel" \
  --from-literal=type=helm \
  --from-literal=username="aarna.gitlab" \
  --from-literal=password="glpat-aVmCtzoIcsw-cQzSsLXhD286MQp1Ojk1NXd4Cw.01.120768kfr" \
  --dry-run=client -o yaml | \
  kubectl label --local -f - "argocd.argoproj.io/secret-type=repository" --dry-run=client -o yaml | \
  kubectl apply -f - 2>/dev/null || true

echo ""
echo "=== Step 3: PREREQUISITE — Create armada-registry imagePullSecret ==="
echo "Images at docker.io/amcop/* require authentication."
echo "Run the following with your Docker Hub credentials, then press Enter:"
echo ""
echo "  kubectl create secret docker-registry armada-registry \\"
echo "    --docker-server=https://index.docker.io/v1/ \\"
echo "    --docker-username=YOUR_DOCKER_USERNAME \\"
echo "    --docker-password=YOUR_DOCKER_PASSWORD \\"
echo "    --namespace=amcop-system"
echo ""
echo "Repeat for each namespace: longhorn-system metallb-system vault cert-manager"
echo "  prometheus observability seaweedfs cortex kamaji-system capi-operator-system"
echo ""
read -p "Press Enter once armada-registry secrets are created (or Ctrl+C to stop here)..."

echo ""
echo "=== Step 4: Bootstrap — apply root Application (one time only) ==="
kubectl apply -f "$(dirname "$0")/root.yaml"

echo ""
echo "=== Done! ArgoCD is now managing all deployments from Git ==="
echo "ArgoCD UI:  http://10.20.28.60:30080"
echo "Watch:      kubectl get applications -n argocd -w"
echo ""
echo "ArgoCD will now:"
echo "  1. Pull root.yaml → create infrastructure-root + platform-root Applications"
echo "  2. Pull infrastructure/ → deploy wave 0 (longhorn) first, then waves 1-3"
echo "  3. Pull platform/ → deploy waves 1-4 once infrastructure is Healthy"
echo ""
echo "=== Post-install steps (triggered by Git push, not local kubectl) ==="
echo "1. After seaweedfs is Healthy — get its S3 credentials and push updated"
echo "   infrastructure/09-loki.yaml to Git. ArgoCD auto-syncs."
echo ""
echo "2. After vault is Running — initialize Vault:"
echo "   kubectl exec -n vault vault-0 -- vault operator init -key-shares=1 -key-threshold=1"
echo "   kubectl exec -n vault vault-0 -- vault operator unseal <key>"
echo "   # Store keys as K8s Secret vault-init-keys for the auto-unseal sidecar"
echo ""
echo "3. Platform charts use the private GitLab Helm repo — set REPLACE_PROJECT_ID"
echo "   in the gitlab-helm-repo secret (Step 2 above) before platform apps sync."
