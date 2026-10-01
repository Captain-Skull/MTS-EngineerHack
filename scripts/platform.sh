#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${ROOT}/.state"
export PATH="${ROOT}/.bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${STATE}/kubeconfig}"
export HELM_DATA_HOME="${ROOT}/.helm/data" HELM_CACHE_HOME="${ROOT}/.helm/cache" HELM_CONFIG_HOME="${ROOT}/.helm/config"
export HELMFILE_CACHE_HOME="${ROOT}/.helm/helmfile"

log() { printf '\033[1;34m[platform]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[platform]\033[0m %s\n' "$*" >&2; exit 1; }

[[ -f "${KUBECONFIG}" ]] || die "нет kubeconfig (${KUBECONFIG}) — сначала выполните: make cluster"
kubectl version --request-timeout=10s >/dev/null 2>&1 || die "API server недоступен (${KUBECONFIG})"

K8S_API_HOST="$(kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' | sed -E 's#https?://([^:/]+).*#\1#')"
export K8S_API_HOST

ensure_secrets() {
  kubectl apply --server-side --field-manager=platform -f "${ROOT}/helmfile/namespaces.yaml" >/dev/null

  if ! kubectl -n monitoring get secret grafana-admin >/dev/null 2>&1; then
    log "генерация пароля администратора"
    local pass
    pass="$(openssl rand -hex 16)"
    kubectl -n monitoring create secret generic grafana-admin \
      --from-literal=admin-user=admin --from-literal=admin-password="${pass}" >/dev/null
  fi
  local pass htpasswd
  pass="$(kubectl -n monitoring get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d)"
  htpasswd="admin:{SHA}$(printf '%s' "${pass}" | openssl dgst -binary -sha1 | openssl base64)"
  for ns in monitoring kube-system; do
    kubectl -n "${ns}" create secret generic basic-auth --from-literal=.htpasswd="${htpasswd}" \
      --dry-run=client -o yaml | kubectl apply --server-side --field-manager=platform -f - >/dev/null
  done
  umask 077
  printf 'user: admin\npassword: %s\n' "${pass}" > "${STATE}/credentials"
}

case "${1:-apply}" in
  apply)
    ensure_secrets
    log "helmfile apply (API server ${K8S_API_HOST})"
    helmfile --file "${ROOT}/helmfile/helmfile.yaml.gotmpl" apply \
      --skip-diff-on-install --suppress-secrets --concurrency 4
    log "готово. Учётные данные UI: ${STATE}/credentials"
    ;;
  diff)
    helmfile --file "${ROOT}/helmfile/helmfile.yaml.gotmpl" diff --suppress-secrets --context 3
    ;;
  *) die "usage: $0 apply|diff" ;;
esac
