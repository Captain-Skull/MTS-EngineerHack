#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${ROOT}/.state"
export PATH="${ROOT}/.bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${STATE}/kubeconfig}"
DOMAIN="${DOMAIN:-demo.test}"

GW_IP="$(kubectl -n envoy-gateway-system get gateway public -o jsonpath='{.status.addresses[0].value}')"
kubectl -n cert-manager get secret mts-hack-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "${STATE}/ca.crt"
HOSTS="hello rollout grafana prometheus alertmanager hubble"

printf '\n\033[1mАдрес Gateway:\033[0m %s\n' "${GW_IP}"
printf '\n\033[1mСтрока для /etc/hosts:\033[0m\n'
printf '%s' "${GW_IP}"
for h in ${HOSTS}; do printf ' %s.%s' "${h}" "${DOMAIN}"; done
printf '\n\n\033[1mUI (логин admin, пароль в %s):\033[0m\n' "${STATE}/credentials"
for h in ${HOSTS}; do printf '  https://%s.%s\n' "${h}" "${DOMAIN}"; done
printf '\n\033[1mCA стенда:\033[0m %s\n' "${STATE}/ca.crt"
printf '\n\033[1mПроверка без правки /etc/hosts:\033[0m\n'
printf '  curl --cacert %s --resolve hello.%s:443:%s https://hello.%s/\n\n' "${STATE}/ca.crt" "${DOMAIN}" "${GW_IP}" "${DOMAIN}"
