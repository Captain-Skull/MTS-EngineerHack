#!/usr/bin/env bash
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${ROOT}/.state"
export PATH="${ROOT}/.bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${STATE}/kubeconfig}"
DOMAIN="${DOMAIN:-demo.test}"
GW_NS=envoy-gateway-system GW_NAME=public
NS=load-test
IMAGE="${K6_IMAGE:-grafana/k6:2.3.0@sha256:9c2dee7f8ed74d317e4027c06a10f169b625638189de8d4555d0b3486a5aeb34}"
RATE="${LOAD_RATE:-150}"
RAMP="${LOAD_RAMP:-1m}"
HOLD="${LOAD_HOLD:-4m}"
TEST_ID="load-$(date +%Y%m%d-%H%M%S)"

log() { printf '\033[1;34m[load]\033[0m %s\n' "$*"; }

kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "${NS}" pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
trap 'kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1' EXIT
kubectl -n "${NS}" create configmap k6-script --from-file=hello.js="${ROOT}/scripts/k6/hello.js" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl -n cert-manager get secret mts-hack-ca -o jsonpath='{.data.ca\.crt}' | base64 -d |
  kubectl -n "${NS}" create configmap gateway-ca --from-file=ca.crt=/dev/stdin --dry-run=client -o yaml | kubectl apply -f - >/dev/null
GW_SVC_IP="$(kubectl -n "${GW_NS}" get svc -l gateway.envoyproxy.io/owning-gateway-name="${GW_NAME}" -o jsonpath='{.items[0].spec.clusterIP}')"

min_v1="$(kubectl -n demo get hpa hello-v1 -o jsonpath='{.spec.minReplicas}')"
log "${TEST_ID}: до ${RATE} запросов/с на https://hello.${DOMAIN}/ (разгон ${RAMP}, удержание ${HOLD}), метрики k6 → Prometheus"
kubectl -n "${NS}" delete job k6 --ignore-not-found >/dev/null
kubectl apply -f - >/dev/null <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: k6
  namespace: ${NS}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 12345
        seccompProfile: { type: RuntimeDefault }
      containers:
        - name: k6
          image: ${IMAGE}
          args: [run, --quiet, -o, experimental-prometheus-rw, /scripts/hello.js]
          env:
            - { name: TARGET_HOST, value: "hello.${DOMAIN}" }
            - { name: GATEWAY_IP, value: "${GW_SVC_IP}" }
            - { name: RATE, value: "${RATE}" }
            - { name: RAMP, value: "${RAMP}" }
            - { name: HOLD, value: "${HOLD}" }
            - { name: TEST_ID, value: "${TEST_ID}" }
            - { name: SSL_CERT_FILE, value: /ca/ca.crt }
            - { name: K6_PROMETHEUS_RW_SERVER_URL, value: "http://kube-prometheus-stack-prometheus.monitoring.svc:9090/api/v1/write" }
            - { name: K6_PROMETHEUS_RW_TREND_STATS, value: "p(95),p(99)" }
          resources:
            requests: { cpu: 200m, memory: 128Mi }
            limits: { memory: 512Mi }
          securityContext:
            allowPrivilegeEscalation: false
            readOnlyRootFilesystem: true
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: script, mountPath: /scripts, readOnly: true }
            - { name: ca, mountPath: /ca, readOnly: true }
            - { name: tmp, mountPath: /tmp }
      volumes:
        - { name: script, configMap: { name: k6-script } }
        - { name: ca, configMap: { name: gateway-ca } }
        - { name: tmp, emptyDir: {} }
EOF

printf '\n  %-8s %-10s %-10s %-12s %s\n' время v1 v2 "CPU v1" "статус k6"
max_v1="${min_v1}" start=${SECONDS}
while :; do
  read -r cur_v1 cpu_v1 < <(kubectl -n demo get hpa hello-v1 -o jsonpath='{.status.currentReplicas} {.status.currentMetrics[0].resource.current.averageUtilization}')
  cur_v2="$(kubectl -n demo get hpa hello-v2 -o jsonpath='{.status.currentReplicas}')"
  state="$(kubectl -n "${NS}" get job k6 -o jsonpath='{.status.conditions[?(@.status=="True")].type}')"
  ((cur_v1 > max_v1)) && max_v1=${cur_v1}
  printf '  %-8s %-10s %-10s %-12s %s\n' "$((SECONDS - start))s" "${cur_v1}" "${cur_v2}" "${cpu_v1:-?}%" "${state:-running}"
  [[ -n "${state}" ]] && break
  sleep 15
done

echo
kubectl -n "${NS}" logs job/k6 | sed -n '/THRESHOLDS/,$p'
echo
fail=0
if [[ "${state}" == *Complete* ]]; then
  printf '  \033[32m✔\033[0m пороги k6 выполнены: ошибок < 1%%, p95 < 300 мс\n'
else
  printf '  \033[31m✘\033[0m пороги k6 нарушены\n'; fail=1
fi
if ((max_v1 > min_v1)); then
  printf '  \033[32m✔\033[0m HPA масштабировал hello-v1, реплики: %s → %s\n' "${min_v1}" "${max_v1}"
else
  printf '  \033[31m✘\033[0m HPA не масштабировал hello-v1, реплик: %s\n' "${max_v1}"; fail=1
fi
log "Grafana → дашборд «Hello service»: RPS, задержки и реплики HPA; метрики k6: k6_http_reqs_total{testid=\"${TEST_ID}\"}"
exit "${fail}"
