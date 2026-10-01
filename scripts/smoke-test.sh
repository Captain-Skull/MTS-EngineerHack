#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${ROOT}/.state"
export PATH="${ROOT}/.bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${STATE}/kubeconfig}"
DOMAIN="${DOMAIN:-demo.test}"
GW_NS=envoy-gateway-system GW_NAME=public

pass=0 fail=0
ok()   { printf '  \033[32m✔\033[0m %s\n' "$*"; pass=$((pass + 1)); }
bad()  { printf '  \033[31m✘\033[0m %s\n' "$*"; fail=$((fail + 1)); }
step() { printf '\n\033[1m%s\033[0m\n' "$*"; }
check() { local d="$1"; shift; if "$@"; then ok "${d}"; else bad "${d}"; fi; }
eventually() { local t="$1"; shift; local end=$((SECONDS + t)); until "$@"; do ((SECONDS >= end)) && return 1; sleep 3; done; }

svc_get() { kubectl get --raw "/api/v1/namespaces/$1/services/$2/proxy$3"; }
urlenc()  { python3 -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1],safe=""))' "$1"; }
prom()    { svc_get monitoring kube-prometheus-stack-prometheus:9090 "/api/v1/query?query=$(urlenc "$1")"; }
prom_n()  { prom "$1" | python3 -c 'import sys,json;print(len(json.load(sys.stdin)["data"]["result"]))'; }
prom_v()  { prom "$1" | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["value"][1] if r else "")'; }

step "0. Кластер"
check "API server доступен" kubectl version --request-timeout=10s
ready=$(kubectl get nodes --no-headers | awk '$2=="Ready"' | wc -l | tr -d ' ')
total=$(kubectl get nodes --no-headers | wc -l | tr -d ' ')
check "все узлы Ready (${ready}/${total})" test "${ready}" = "${total}"

step "1. Gateway API"
check "Gateway ${GW_NS}/${GW_NAME} Programmed" \
  kubectl -n "${GW_NS}" wait gateway/"${GW_NAME}" --for=condition=Programmed --timeout=180s
check "HTTPRoute demo/hello Accepted" \
  kubectl -n demo wait httproute/hello --for=jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}'=True --timeout=60s
GW_IP="$(kubectl -n "${GW_NS}" get gateway "${GW_NAME}" -o jsonpath='{.status.addresses[0].value}')"
echo "     адрес Gateway: ${GW_IP}"
kubectl -n cert-manager get secret mts-hack-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "${STATE}/ca.crt"

H="hello.${DOMAIN}"
c() { curl -sS --max-time 10 --cacert "${STATE}/ca.crt" --resolve "${H}:443:${GW_IP}" --resolve "${H}:80:${GW_IP}" "$@"; }

code=$(c -o /dev/null -w '%{http_code}' "http://${H}/")
check "HTTP → 301 редирект на HTTPS (получено ${code})" test "${code}" = 301
body=$(c "https://${H}/")
check "HTTPS (TLS проверен по CA стенда) → «Hello World!»: ${body}" grep -q '^Hello World!' <<<"${body}"
check "X-Canary: always → версия v2" grep -q 'version=v2' <<<"$(c -H 'X-Canary: always' "https://${H}/")"
check "/v1 → версия v1 (URLRewrite)" grep -q 'version=v1' <<<"$(c "https://${H}/v1")"
check "/v2 → версия v2 (URLRewrite)" grep -q 'version=v2' <<<"$(c "https://${H}/v2")"
v2=0; for _ in $(seq 1 40); do c "https://${H}/" | grep -q version=v2 && v2=$((v2 + 1)); done
check "canary: ${v2}/40 запросов на v2 (ожидается ~10%)" test "${v2}" -ge 1 -a "${v2}" -le 16

PASS_UI="$(awk '/^password:/{print $2}' "${STATE}/credentials" 2>/dev/null)"
P="prometheus.${DOMAIN}"
code=$(curl -sS --max-time 10 --cacert "${STATE}/ca.crt" --resolve "${P}:443:${GW_IP}" -o /dev/null -w '%{http_code}' "https://${P}/-/ready")
check "Prometheus UI без пароля → 401 (получено ${code})" test "${code}" = 401
code=$(curl -sS --max-time 10 --cacert "${STATE}/ca.crt" --resolve "${P}:443:${GW_IP}" -u "admin:${PASS_UI}" -o /dev/null -w '%{http_code}' "https://${P}/-/ready")
check "Prometheus UI с basic auth → 200 (получено ${code})" test "${code}" = 200
G="grafana.${DOMAIN}"
check "Grafana через Gateway /api/health" grep -q '"database": *"ok"' <<<"$(curl -sS --max-time 10 --cacert "${STATE}/ca.crt" --resolve "${G}:443:${GW_IP}" "https://${G}/api/health")"

step "2. Логирование (nginx → Fluentd → Loki)"
RID="smoke-$(date +%s)-${RANDOM}"
c -H "X-Request-Id: ${RID}" -o /dev/null "https://${H}/"
echo "     отправлен запрос с X-Request-Id: ${RID}"
start_ns="$(( $(date +%s) - 300 ))000000000"
loki_find() {
  svc_get logging loki:3100 "/loki/api/v1/query_range?query=$(urlenc "$1")&start=${start_ns}&limit=5" \
    | python3 -c 'import sys,json;r=json.load(sys.stdin)["data"]["result"];print(r[0]["values"][0][1] if r else "")' 2>/dev/null
}
has_log() { test -n "$(loki_find "$1")"; }
nginx_q="{namespace=\"demo\", container=\"nginx\"} |= \"${RID}\""
envoy_q="{namespace=\"envoy-gateway-system\", container=\"envoy\"} |= \"${RID}\""
check "access-лог запроса (nginx) найден в Loki: ${nginx_q}" eventually 90 has_log "${nginx_q}"
found="$(loki_find "${nginx_q}")"
[[ -n "${found}" ]] && echo "     ${found:0:200}…"
check "тот же запрос в access-логе Envoy Gateway (сквозной request_id)" eventually 60 has_log "${envoy_q}"

step "3. Мониторинг (Prometheus)"
no_down_targets() { test "$(prom_n 'up == 0')" = 0; }
check "все targets Prometheus в состоянии up" eventually 120 no_down_targets
prom 'up == 0' | python3 -c 'import sys,json;[print("     down:",r["metric"].get("job"),r["metric"].get("instance")) for r in json.load(sys.stdin)["data"]["result"]]'
for q in \
  'up{job=~"hello-v.*"}' \
  'nginx_http_requests_total' \
  'envoy_cluster_upstream_rq_total' \
  'fluentd_output_status_emit_records' \
  'node_cpu_seconds_total' \
  'kube_pod_status_ready' \
  'hubble_flows_processed_total'; do
  n=$(prom_n "${q}")
  check "PromQL ${q} → ${n} рядов" test "${n:-0}" -gt 0
done
rps=$(prom_v 'sum(rate(nginx_http_requests_total[2m]))')
echo "     текущий RPS приложения: ${rps:-н/д}"

printf '\n\033[1mИтог: %d пройдено, %d провалено\033[0m\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
