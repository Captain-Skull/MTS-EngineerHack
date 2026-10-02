#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${ROOT}/.state"
export PATH="${ROOT}/.bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${STATE}/kubeconfig}"
DOMAIN="${DOMAIN:-demo.test}"
GW_NS=envoy-gateway-system GW_NAME=public
MAX_ERRORS="${CHAOS_MAX_ERRORS:-0}"
WORKERS="${CHAOS_WORKERS:-3}"
WORK="$(mktemp -d)"
LOAD_PIDS=()

pass=0 fail=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  {
  printf '  \033[31m✘\033[0m %s\n' "$*"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::error title=chaos-test::%s\n' "$*"
  fail=$((fail + 1))
}
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
info() { printf '     %s\n' "$*"; }
eventually() { local t="$1"; shift; local end=$((SECONDS + t)); until "$@"; do ((SECONDS >= end)) && return 1; sleep 3; done; }

load_stop() {
  ((${#LOAD_PIDS[@]})) || return 0
  kill "${LOAD_PIDS[@]}" 2>/dev/null
  wait "${LOAD_PIDS[@]}" 2>/dev/null
  LOAD_PIDS=()
}
cleanup() { load_stop; rm -rf "${WORK}"; }
trap cleanup EXIT

GW_IP="$(kubectl -n "${GW_NS}" get gateway "${GW_NAME}" -o jsonpath='{.status.addresses[0].value}')"
[[ -n "${GW_IP}" ]] || { echo "Gateway ${GW_NS}/${GW_NAME} не имеет адреса — сначала make deploy" >&2; exit 1; }
kubectl -n cert-manager get secret mts-hack-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "${STATE}/ca.crt"
H="hello.${DOMAIN}"
c() { curl -sS --max-time 5 --cacert "${STATE}/ca.crt" --resolve "${H}:443:${GW_IP}" "$@"; }

load_start() {
  : > "${WORK}/codes"
  for _ in $(seq 1 "${WORKERS}"); do
    (
      trap 'exit 0' TERM
      while :; do
        c -o /dev/null -w '%{http_code}\n' "https://${H}/" >>"${WORK}/codes" 2>/dev/null
        sleep 0.05
      done
    ) &
    LOAD_PIDS+=($!)
  done
  sleep 3
}

load_verdict() {
  local name="$1" total errors summary
  load_stop
  total=$(wc -l <"${WORK}/codes" | tr -d ' ')
  errors=$(grep -cv '^200$' "${WORK}/codes")
  summary=$(sort "${WORK}/codes" | uniq -c | awk '{printf "%s×%s ", $2, $1}')
  info "запросов: ${total}, коды: ${summary}"
  if [[ "${total}" -gt 0 && "${errors}" -le "${MAX_ERRORS}" ]]; then
    ok "${name}: ${errors} ошибок из ${total} запросов"
  else
    bad "${name}: ${errors} ошибок из ${total} запросов (допустимо ${MAX_ERRORS})"
  fi
}

rollout() { kubectl -n "$1" rollout status deploy/"$2" --timeout=300s >/dev/null; }
app_rolled_out() { rollout demo hello-v1 && rollout demo hello-v2; }
all_rolled_out() { app_rolled_out && rollout "${GW_NS}" "${ENVOY_DEPLOY}"; }

replaced() {
  local ns="$1" sel="$2" victim="$3" want ready
  want=$(kubectl -n "${ns}" get deploy -l "${sel}" -o jsonpath='{.items[0].spec.replicas}')
  ready=$(kubectl -n "${ns}" get pods -l "${sel}" -o jsonpath='{range .items[*]}{.metadata.name} {.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' |
    awk -v v="${victim}" '$1 != v && $2 == "True"' | wc -l | tr -d ' ')
  [[ "${ready}" -ge "${want}" ]]
}

timed() {
  local t0=${SECONDS} rc
  "$@"
  rc=$?
  info "${TIMED_LABEL:-восстановление} за $((SECONDS - t0)) с"
  return "${rc}"
}

ENVOY_DEPLOY="$(kubectl -n "${GW_NS}" get deploy -l gateway.envoyproxy.io/owning-gateway-name="${GW_NAME}" -o jsonpath='{.items[0].metadata.name}')"
printf '\033[1mТест отказоустойчивости\033[0m: Gateway %s, %s потока нагрузки на https://%s/, допустимо ошибок: %s\n' \
  "${GW_IP}" "${WORKERS}" "${H}" "${MAX_ERRORS}"

step "1. Плавный перезапуск приложения (rollout restart hello-v1 и hello-v2)"
load_start
kubectl -n demo rollout restart deploy/hello-v1 deploy/hello-v2 >/dev/null
timed app_rolled_out
sleep 5
load_verdict "rolling update без простоя"

step "2. Аварийная гибель пода приложения (delete --grace-period=0 --force)"
victim="$(kubectl -n demo get pods -l app.kubernetes.io/instance=hello-v1 -o jsonpath='{.items[0].metadata.name}')"
load_start
info "убиваем ${victim}"
kubectl -n demo delete pod "${victim}" --grace-period=0 --force >/dev/null 2>&1
timed eventually 180 replaced demo app.kubernetes.io/instance=hello-v1 "${victim}"
sleep 5
load_verdict "повторы Envoy скрывают падение пода"

step "3. Потеря пода Envoy (delete pod)"
victim="$(kubectl -n "${GW_NS}" get pods -l gateway.envoyproxy.io/owning-gateway-name="${GW_NAME}" -o jsonpath='{.items[0].metadata.name}')"
load_start
info "удаляем ${victim}"
kubectl -n "${GW_NS}" delete pod "${victim}" --wait=false >/dev/null
timed eventually 180 replaced "${GW_NS}" gateway.envoyproxy.io/owning-gateway-name="${GW_NAME}" "${victim}"
sleep 5
load_verdict "второй экземпляр Envoy принимает трафик, слив соединений"

step "4. Вывод узла на обслуживание (kubectl drain)"
node="$(kubectl get pods -n demo -l app.kubernetes.io/instance=hello-v1 -o jsonpath='{.items[0].spec.nodeName}')"
nodes=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
if [[ "${nodes}" -lt 2 ]]; then
  info "пропущено: в кластере один узел (${node}), выселять поды некуда"
else
  load_start
  info "drain ${node}: PodDisruptionBudget не даёт выселить последнюю реплику"
  drain_node() { kubectl drain "$1" --ignore-daemonsets --delete-emptydir-data --timeout=300s >"${WORK}/drain.log" 2>&1; }
  if TIMED_LABEL="drain выполнен" timed drain_node "${node}"; then
    all_rolled_out
    sleep 5
    load_verdict "drain ${node} без простоя"
  else
    load_stop
    bad "drain ${node} не завершился: $(tail -1 "${WORK}/drain.log")"
  fi
  kubectl uncordon "${node}" >/dev/null
  info "узел ${node} возвращён в работу (uncordon)"
fi

step "5. Недоступность Loki: логи буферизуются в Fluentd и не теряются"
RUN="chaos-$(date +%s)-${RANDOM}"
N=20
kubectl -n logging scale sts/loki --replicas=0 >/dev/null
kubectl -n logging wait pod/loki-0 --for=delete --timeout=180s >/dev/null 2>&1
info "Loki остановлен, отправляем ${N} запросов с X-Request-Id ${RUN}-<n>"
for i in $(seq 1 "${N}"); do c -o /dev/null -H "X-Request-Id: ${RUN}-${i}" "https://${H}/"; done
sleep 20
kubectl -n logging scale sts/loki --replicas=1 >/dev/null
t0=${SECONDS}
kubectl -n logging rollout status sts/loki --timeout=300s >/dev/null
info "Loki снова готов за $((SECONDS - t0)) с"
urlenc() { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
start_ns="$(( $(date +%s) - 900 ))000000000"
logql="{namespace=\"demo\", container=\"nginx\"} |= \"${RUN}-\""
loki_count() {
  kubectl get --raw "/api/v1/namespaces/logging/services/loki:3100/proxy/loki/api/v1/query_range?query=$(urlenc "${logql}")&start=${start_ns}&limit=1000" 2>/dev/null |
    python3 -c 'import sys,json;print(sum(len(r["values"]) for r in json.load(sys.stdin)["data"]["result"]))' 2>/dev/null || echo 0
}
all_logs() { local n; n="$(loki_count)"; echo "${n}" >"${WORK}/loki"; test "${n}" -ge "${N}"; }
if eventually 240 all_logs; then
  ok "все ${N}/${N} строк лога, записанных во время простоя Loki, доставлены"
else
  bad "в Loki $(cat "${WORK}/loki")/${N} строк лога, записанных во время простоя Loki"
fi

printf '\n\033[1mИтог: %d пройдено, %d провалено\033[0m\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
