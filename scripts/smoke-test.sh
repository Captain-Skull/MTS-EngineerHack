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
bad()  {
  printf '  \033[31m✘\033[0m %s\n' "$*"
  [[ -n "${GITHUB_ACTIONS:-}" ]] && printf '::error title=smoke-test::%s\n' "$*"
  fail=$((fail + 1))
}
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

step "2.5 Трейсинг (Envoy, nginx → OpenTelemetry Collector → Tempo)"
TRACE_ID="$(python3 -c 'import secrets;print(secrets.token_hex(16))')"
c -H "traceparent: 00-${TRACE_ID}-$(python3 -c 'import secrets;print(secrets.token_hex(8))')-01" -o /dev/null "https://${H}/"
echo "     отправлен запрос с traceparent, trace_id: ${TRACE_ID}"
trace_services() {
  svc_get tracing tempo:3200 "/api/v2/traces/${TRACE_ID}" 2>/dev/null | python3 -c '
import sys, json
d = json.load(sys.stdin)
names = set()
for b in d.get("trace", d).get("resourceSpans", d.get("batches", [])):
    for a in b.get("resource", {}).get("attributes", []):
        if a["key"] == "service.name":
            names.add(a["value"].get("stringValue", ""))
print(" ".join(sorted(names)))'
}
has_full_trace() { local s; s="$(trace_services)"; [[ "${s}" == *hello-v* && "${s}" != "${s/envoy/}" ]]; }
check "трейс запроса найден в Tempo и содержит спаны Envoy и nginx" eventually 90 has_full_trace
echo "     сервисы в трейсе: $(trace_services)"

step "3. Мониторинг (Prometheus)"
no_down_targets() { test "$(prom_n 'up == 0')" = 0; }
has_series() { test "$(prom_n "$1")" -gt 0 2>/dev/null; }
for q in \
  'up{job=~"hello-v.*"}' \
  'nginx_http_requests_total' \
  'envoy_cluster_upstream_rq_total' \
  'fluentd_output_status_emit_records' \
  'node_cpu_seconds_total' \
  'kube_pod_status_ready' \
  'hubble_flows_processed_total' \
  'traces_spanmetrics_calls_total'; do
  if eventually 180 has_series "${q}"; then
    ok "PromQL ${q} → $(prom_n "${q}") рядов"
  else
    bad "PromQL ${q} → 0 рядов за 3 минуты"
  fi
done
check "все targets Prometheus в состоянии up" eventually 120 no_down_targets
rules_ok() {
  svc_get monitoring kube-prometheus-stack-prometheus:9090 "/api/v1/rules" | python3 -c '
import sys, json
groups = json.load(sys.stdin)["data"]["groups"]
names = {r["name"] for g in groups for r in g["rules"]}
bad = [r["name"] for g in groups for r in g["rules"] if r.get("health") == "err"]
sys.exit(1 if bad or "slo:hello_errors:ratio_rate5m" not in names else 0)'
}
check "правила Prometheus (включая SLO) загружены и вычисляются без ошибок" eventually 120 rules_ok
prom 'up == 0' | python3 -c 'import sys,json;[print("     down:",r["metric"].get("job"),r["metric"].get("instance")) for r in json.load(sys.stdin)["data"]["result"]]'
rps=$(prom_v 'sum(rate(nginx_http_requests_total[2m]))')
echo "     текущий RPS приложения: ${rps:-н/д}"

step "4. Резервное копирование etcd"
backup_job="etcd-backup-smoke-$(date +%s)"
kubectl -n kube-system create job "${backup_job}" --from=cronjob/etcd-backup >/dev/null 2>&1
if kubectl -n kube-system wait "job/${backup_job}" --for=condition=Complete --timeout=300s >/dev/null 2>&1; then
  ok "снапшот etcd снят и проверен: $(kubectl -n kube-system logs "job/${backup_job}" -c store 2>/dev/null | head -1)"
else
  bad "задание бэкапа etcd не завершилось успешно"
fi
kubectl -n kube-system delete job "${backup_job}" --wait=false >/dev/null 2>&1

step "5. Политики допуска (Kyverno)"
SIGNED_IMAGE="${SIGNED_IMAGE:-ghcr.io/captain-skull/fluentd-k8s-loki:1.19.3-1}"
policy_ready() { test "$(kubectl get "$1" "$2" -o jsonpath='{.status.conditionStatus.ready}' 2>/dev/null)" = true; }
check "ImageValidatingPolicy verify-image-signatures готова" eventually 120 policy_ready imagevalidatingpolicy verify-image-signatures
check "ValidatingPolicy require-image-digest готова" eventually 120 policy_ready validatingpolicy require-image-digest
dry_pod() { kubectl -n "$1" run "policy-smoke-${RANDOM}" --image="$2" --restart=Never --dry-run=server "${@:3}" 2>&1; }
admitted="$(dry_pod default "${SIGNED_IMAGE}" -o jsonpath='{.spec.containers[0].image}')"
check "подписанный CI образ допущен и закреплён по digest: ${admitted}" grep -q "^${SIGNED_IMAGE}@sha256:" <<<"${admitted}"
denied="$(dry_pod default "${SIGNED_IMAGE%:*}:unsigned-smoke")"
check "образ без подписи из ghcr.io/captain-skull отклонён" grep -q 'denied the request' <<<"${denied}"
kubectl create namespace policy-smoke --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl get imagevalidatingpolicy verify-image-signatures -o json | python3 -c '
import sys, json
p = json.load(sys.stdin)
spec = p["spec"]
spec["attestors"][0]["cosign"]["keyless"]["identities"][0]["subjectRegExp"] = "^https://github\\.com/untrusted/repo/.*$"
spec["matchConstraints"]["namespaceSelector"] = {"matchLabels": {"kubernetes.io/metadata.name": "policy-smoke"}}
print(json.dumps({"apiVersion": p["apiVersion"], "kind": p["kind"], "metadata": {"name": "policy-smoke-untrusted-signer"}, "spec": spec}))
' | kubectl apply -f - >/dev/null
untrusted_denied() { local out; out="$(dry_pod policy-smoke "${SIGNED_IMAGE}")"; grep -q 'policy-smoke-untrusted-signer failed' <<<"${out}"; }
check "тот же образ отклонён, если доверять другому подписанту (подпись реально проверяется)" eventually 60 untrusted_denied
kubectl delete imagevalidatingpolicy policy-smoke-untrusted-signer --wait=false >/dev/null 2>&1
kubectl delete namespace policy-smoke --wait=false >/dev/null 2>&1
restricted='{"spec":{"securityContext":{"runAsNonRoot":true,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"nginxinc/nginx-unprivileged:1.31.6-alpine","securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}'
denied="$(dry_pod demo nginxinc/nginx-unprivileged:1.31.6-alpine --overrides="${restricted}")"
check "под без digest в namespace demo отклонён политикой require-image-digest" grep -q 'require-image-digest' <<<"${denied}"

printf '\n\033[1mИтог: %d пройдено, %d провалено\033[0m\n' "${pass}" "${fail}"
[[ "${fail}" -eq 0 ]]
