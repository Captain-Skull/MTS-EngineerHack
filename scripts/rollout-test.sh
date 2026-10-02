#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${ROOT}/.state"
export PATH="${ROOT}/.bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${STATE}/kubeconfig}"
DOMAIN="${DOMAIN:-demo.test}"
NS=demo NAME=rollout
H="${NAME}.${DOMAIN}"
WORK="$(mktemp -d)"
LOAD_PIDS=()

pass=0 fail=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  {
  printf '  \033[31m✘\033[0m %s\n' "$*"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::error title=rollout-test::%s\n' "$*"
  fail=$((fail + 1))
}
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '     %s\n' "$*"; }

load_stop() {
  ((${#LOAD_PIDS[@]})) || return 0
  kill "${LOAD_PIDS[@]}" 2>/dev/null
  wait "${LOAD_PIDS[@]}" 2>/dev/null
  LOAD_PIDS=()
}
trap 'load_stop; rm -rf "${WORK}"' EXIT

GW_IP="$(kubectl -n envoy-gateway-system get gateway public -o jsonpath='{.status.addresses[0].value}')"
kubectl -n cert-manager get secret mts-hack-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "${STATE}/ca.crt"

load_start() {
  : > "${WORK}/responses"
  for _ in 1 2 3; do
    (
      trap 'exit 0' TERM
      while :; do
        out="$(curl -sS --max-time 5 --cacert "${STATE}/ca.crt" --resolve "${H}:443:${GW_IP}" -w '\n%{http_code}' "https://${H}/" 2>/dev/null)"
        code="${out##*$'\n'}"
        msg="$(grep -o '"message": "[^"]*"' <<<"${out}" | cut -d'"' -f4)"
        printf '%s\t%s\n' "${code:-000}" "${msg:--}" >>"${WORK}/responses"
        sleep 0.1
      done
    ) &
    LOAD_PIDS+=($!)
  done
}

summary() { sort "${WORK}/responses" | uniq -c | sort -rn | awk -F'\t' '{printf "     %s  %s\n", $1, $2}'; }
errors() { awk -F'\t' '$1 != "200"' "${WORK}/responses" | wc -l | tr -d ' '; }
total() { wc -l <"${WORK}/responses" | tr -d ' '; }
stable_message() {
  curl -sS --max-time 5 --cacert "${STATE}/ca.crt" --resolve "${H}:443:${GW_IP}" "https://${H}/" |
    python3 -c 'import sys,json;print(json.load(sys.stdin)["message"])'
}
phase() { kubectl -n "${NS}" get canary "${NAME}" -o jsonpath='{.status.phase}'; }

watch_canary() {
  local want="$1" timeout="$2"
  local end=$((SECONDS + timeout)) last="" now p
  until [[ "$(phase)" =~ ^(Progressing|Promoting|Finalising)$ ]]; do
    ((SECONDS >= end)) && return 1
    sleep 2
  done
  while ((SECONDS < end)); do
    p="$(phase)"
    now="${p} $(kubectl -n "${NS}" get canary "${NAME}" -o jsonpath='вес canary {.status.canaryWeight}%, неудачных проверок {.status.failedChecks}')"
    [[ "${now}" != "${last}" ]] && info "$(date +%H:%M:%S)  ${now}"
    last="${now}"
    [[ "${p}" == "${want}" ]] && return 0
    [[ "${p}" =~ ^(Succeeded|Failed)$ && "${p}" != "${want}" ]] && return 1
    sleep 3
  done
  return 1
}

set_version() {
  local message="$1" faulty="$2" args
  args="$(python3 -c '
import json, sys
args = json.loads(sys.argv[1])
args = [a for a in args if not a.startswith(("--ui-message=", "--random-error"))]
args.append("--ui-message=" + sys.argv[2])
if sys.argv[3] == "1":
    args.append("--random-error")
print(json.dumps([{"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": args}]))
' "${ORIGINAL_ARGS}" "${message}" "${faulty}")"
  kubectl -n "${NS}" patch deploy "${NAME}" --type=json -p "${args}" >/dev/null
}

kubectl -n "${NS}" wait canary/"${NAME}" --for=jsonpath='{.status.phase}'=Initialized --timeout=10s >/dev/null 2>&1 ||
  kubectl -n "${NS}" wait canary/"${NAME}" --for=jsonpath='{.status.phase}'=Succeeded --timeout=300s >/dev/null 2>&1 ||
  { echo "Canary ${NS}/${NAME} не в стабильном состоянии ($(phase)) — сначала make platform" >&2; exit 1; }
ORIGINAL_ARGS="$(kubectl -n "${NS}" get deploy "${NAME}" -o jsonpath='{.spec.template.spec.containers[0].args}')"
ORIGINAL_MESSAGE="$(stable_message)"
TS="$(date +%H%M%S)"

printf '\033[1mProgressive delivery (Flagger)\033[0m: https://%s, сейчас отвечает «%s»\n' "${H}" "${ORIGINAL_MESSAGE}"

step "1. Новая исправная версия: Flagger постепенно переводит трафик и продвигает её"
load_start
set_version "новая версия ${TS}" 0
if watch_canary Succeeded 600; then
  sleep 5
  load_stop
  summary
  now="$(stable_message)"
  check_msg="новая версия ${TS}"
  if [[ "${now}" == "${check_msg}" ]]; then ok "версия продвинута: весь трафик получает «${now}»"; else bad "после продвижения отвечает «${now}»"; fi
  if [[ "$(errors)" -eq 0 ]]; then ok "клиенты не получили ни одной ошибки ($(total) запросов)"; else bad "ошибок у клиентов: $(errors) из $(total)"; fi
else
  load_stop
  bad "продвижение не завершилось (состояние $(phase))"
fi

step "2. Неисправная версия (треть ответов — 500): Flagger должен откатить её"
GOOD="$(stable_message)"
load_start
set_version "неисправная версия ${TS}" 1
if watch_canary Failed 600; then
  sleep 10
  cp "${WORK}/responses" "${WORK}/during"
  load_stop
  summary
  now="$(stable_message)"
  if [[ "${now}" == "${GOOD}" ]]; then ok "откат выполнен: весь трафик снова получает «${now}»"; else bad "после отката отвечает «${now}»"; fi
  bad_share=$(awk -F'\t' -v t="$(total)" '$1 != "200" {n++} END {printf "%.1f", 100 * n / (t ? t : 1)}' "${WORK}/during")
  info "ошибок у клиентов за время анализа: $(errors) из $(total) (${bad_share}%) — только доля трафика canary до отката"
  load_start
  sleep 15
  load_stop
  if [[ "$(errors)" -eq 0 ]]; then ok "после отката ошибок нет ($(total) запросов за 15 с)"; else bad "после отката ошибки продолжаются: $(errors) из $(total)"; fi
else
  load_stop
  bad "откат не произошёл (состояние $(phase))"
fi

step "3. Возврат версии из Git"
load_start
kubectl -n "${NS}" patch deploy "${NAME}" --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":${ORIGINAL_ARGS}}]" >/dev/null
if watch_canary Succeeded 600; then
  load_stop
  if [[ "$(stable_message)" == "${ORIGINAL_MESSAGE}" ]]; then ok "кластер снова соответствует Git: «${ORIGINAL_MESSAGE}»"; else bad "отвечает «$(stable_message)»"; fi
else
  load_stop
  bad "возврат версии из Git не завершился (состояние $(phase))"
fi

printf '\n\033[1mИтог: %d пройдено, %d провалено\033[0m\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
