#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${ROOT}/.state"
export PATH="${ROOT}/.bin:${PATH}"
export KUBECONFIG="${KUBECONFIG:-${STATE}/kubeconfig}"
NS=kube-bench
IMAGE="${KUBE_BENCH_IMAGE:-docker.io/aquasec/kube-bench:v0.16.0@sha256:75506f222d1eb6ce2a751a5533bdc0a3b54c898e2e49e7751d0ee22cfb862679}"
BENCHMARK="${CIS_BENCHMARK:-cis-1.12}"
OUT="${STATE}/cis"

log() { printf '\033[1;34m[cis]\033[0m %s\n' "$*"; }

job() {
  local node="$1" targets="$2"
  cat <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: kube-bench-${node}
  namespace: ${NS}
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 600
  template:
    spec:
      nodeName: ${node}
      hostPID: true
      restartPolicy: Never
      automountServiceAccountToken: false
      tolerations:
        - operator: Exists
      containers:
        - name: kube-bench
          image: ${IMAGE}
          command: [kube-bench, run, --benchmark, ${BENCHMARK}, --targets, "${targets}", --json]
          resources:
            requests: { cpu: 50m, memory: 64Mi }
            limits: { memory: 256Mi }
          volumeMounts:
$(for p in /var/lib/etcd /var/lib/kubelet /var/lib/cni /etc/systemd /lib/systemd /etc/kubernetes /etc/cni/net.d /opt/cni/bin; do
    printf '            - { name: %s, mountPath: %s, readOnly: true }\n' "$(tr -c 'a-z0-9\n' '-' <<<"${p#/}" | sed 's/-*$//')" "${p}"
  done)
            - { name: usr-bin, mountPath: /usr/local/mount-from-host/bin, readOnly: true }
            - { name: etc-passwd, mountPath: /etc/passwd, readOnly: true }
            - { name: etc-group, mountPath: /etc/group, readOnly: true }
      volumes:
$(for p in /var/lib/etcd /var/lib/kubelet /var/lib/cni /etc/systemd /lib/systemd /etc/kubernetes /etc/cni/net.d /opt/cni/bin; do
    printf '        - { name: %s, hostPath: { path: %s } }\n' "$(tr -c 'a-z0-9\n' '-' <<<"${p#/}" | sed 's/-*$//')" "${p}"
  done)
        - { name: usr-bin, hostPath: { path: /usr/bin } }
        - { name: etc-passwd, hostPath: { path: /etc/passwd, type: File } }
        - { name: etc-group, hostPath: { path: /etc/group, type: File } }
EOF
}

mkdir -p "${OUT}"
kubectl create namespace "${NS}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
kubectl label namespace "${NS}" pod-security.kubernetes.io/enforce=privileged --overwrite >/dev/null
trap 'kubectl delete namespace "${NS}" --wait=false >/dev/null 2>&1' EXIT

cp_nodes=" $(kubectl get nodes -l node-role.kubernetes.io/control-plane -o jsonpath='{.items[*].metadata.name}') "
read -r -a nodes <<<"$(kubectl get nodes -o jsonpath='{.items[*].metadata.name}')"
for node in "${nodes[@]}"; do
  if [[ "${cp_nodes}" == *" ${node} "* ]]; then targets=master,controlplane,etcd,node,policies; else targets=node; fi
  log "${node}: ${BENCHMARK}, проверки: ${targets}"
  kubectl -n "${NS}" delete job "kube-bench-${node}" --ignore-not-found >/dev/null
  job "${node}" "${targets}" | kubectl apply -f - >/dev/null
done

for node in "${nodes[@]}"; do
  kubectl -n "${NS}" wait "job/kube-bench-${node}" --for=condition=Complete --timeout=300s >/dev/null
  kubectl -n "${NS}" logs "job/kube-bench-${node}" > "${OUT}/${node}.json"
done

python3 - "${OUT}" "${nodes[@]}" <<'PY'
import json, sys
out, nodes = sys.argv[1], sys.argv[2:]
accepted = {
    "1.3.7": "controller-manager слушает IP узла, а не 127.0.0.1: Prometheus собирает его метрики (доступ через authn/authz)",
    "1.4.2": "scheduler слушает IP узла, а не 127.0.0.1: Prometheus собирает его метрики (доступ через authn/authz)",
    "4.3.1": "kube-proxy не установлен — его заменяет Cilium (eBPF), проверять нечего",
}
total = {"PASS": 0, "FAIL": 0, "WARN": 0, "INFO": 0}
fails = []
print()
print(f"{'узел':<14}{'PASS':>6}{'FAIL':>6}{'WARN':>6}{'INFO':>6}")
for node in nodes:
    raw = open(f"{out}/{node}.json").read()
    data = json.loads(raw[raw.index("{"):])
    t = data.get("Totals", {})
    row = {k: t.get(f"total_{k.lower()}", 0) for k in total}
    for k in total:
        total[k] += row[k]
    print(f"{node:<14}{row['PASS']:>6}{row['FAIL']:>6}{row['WARN']:>6}{row['INFO']:>6}")
    for control in data.get("Controls", []):
        for group in control.get("tests", []):
            for r in group.get("results", []):
                if r.get("status") == "FAIL":
                    fails.append((node, r["test_number"], r["test_desc"]))
print(f"{'итого':<14}{total['PASS']:>6}{total['FAIL']:>6}{total['WARN']:>6}{total['INFO']:>6}")
unexpected = [f for f in fails if f[1] not in accepted]
if fails:
    print("\nFAIL:")
    for node, num, desc in fails:
        mark = "принято" if num in accepted else "НОВОЕ"
        print(f"  {node:<12} {num:<8} [{mark}] {desc}")
    print("\nПринятые отклонения:")
    for num in sorted({f[1] for f in fails if f[1] in accepted}):
        print(f"  {num:<8} {accepted[num]}")
print(f"\nПолные отчёты: {out}/<узел>.json")
if unexpected:
    print(f"\n✘ {len(unexpected)} FAIL вне списка принятых отклонений")
    sys.exit(1)
print("\n✔ все FAIL — из списка принятых и обоснованных отклонений")
PY
