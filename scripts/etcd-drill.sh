#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PATH="${ROOT}/.bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${ROOT}/.state/kubeconfig}"
NS=default
BEFORE="etcd-drill-before-$(date +%s)"
AFTER="etcd-drill-after-$(date +%s)"

log() { printf '\033[1;34m[etcd-drill]\033[0m %s\n' "$*"; }
die() { printf '\033[1;31m[etcd-drill]\033[0m %s\n' "$*" >&2; exit 1; }

log "1/4 метка ${BEFORE} и снапшот etcd"
kubectl -n "${NS}" create configmap "${BEFORE}" --from-literal=state=before >/dev/null
backup_log="$(make -s -C "${ROOT}" etcd-backup)"
echo "${backup_log}"
snapshot="$(grep -o 'etcd-snapshot-[0-9TZ]*\.db' <<<"${backup_log}" | head -1)"
[[ -n "${snapshot}" ]] || die "не удалось определить имя снапшота"

log "2/4 изменения после снапшота: удаляем ${BEFORE}, создаём ${AFTER}"
kubectl -n "${NS}" delete configmap "${BEFORE}" >/dev/null
kubectl -n "${NS}" create configmap "${AFTER}" --from-literal=state=after >/dev/null

log "3/4 восстановление из /var/backups/etcd/${snapshot}"
make -s -C "${ROOT}" etcd-restore SNAPSHOT="/var/backups/etcd/${snapshot}"

log "4/4 проверка состояния"
kubectl -n "${NS}" get configmap "${BEFORE}" >/dev/null 2>&1 || die "${BEFORE} не восстановлена"
if kubectl -n "${NS}" get configmap "${AFTER}" >/dev/null 2>&1; then
  die "${AFTER} осталась — кластер не вернулся к состоянию снапшота"
fi
kubectl wait nodes --all --for=condition=Ready --timeout=300s >/dev/null
kubectl -n "${NS}" delete configmap "${BEFORE}" >/dev/null
log "успех: состояние кластера восстановлено из снапшота ${snapshot}"
