#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="${ROOT}/.state"
PREFIX="${MP_PREFIX:-k8s}"
WORKERS="${MP_WORKERS:-2}"
IMAGE="${MP_IMAGE:-24.04}"
CP_CPUS="${MP_CP_CPUS:-2}"   CP_MEM="${MP_CP_MEM:-4G}"   CP_DISK="${MP_CP_DISK:-25G}"
W_CPUS="${MP_W_CPUS:-2}"     W_MEM="${MP_W_MEM:-5G}"     W_DISK="${MP_W_DISK:-30G}"

log() { printf '\033[1;34m[multipass]\033[0m %s\n' "$*"; }

nodes() {
  echo "${PREFIX}-cp"
  for i in $(seq 1 "${WORKERS}"); do echo "${PREFIX}-w${i}"; done
}

vm_state() { multipass info "$1" --format csv 2>/dev/null | awk -F, 'NR==2{print $2}'; }
vm_ip()    { multipass info "$1" --format csv | awk -F, 'NR==2{print $3}'; }

up() {
  command -v multipass >/dev/null || { echo "Установите Multipass: https://multipass.run" >&2; exit 1; }
  mkdir -p "${STATE}/ssh"
  [[ -f "${STATE}/ssh/id_ed25519" ]] || ssh-keygen -q -t ed25519 -N '' -C "mts-k8s-lab" -f "${STATE}/ssh/id_ed25519"

  cat > "${STATE}/cloud-init.yaml" <<CI
#cloud-config
ssh_authorized_keys:
  - $(cat "${STATE}/ssh/id_ed25519.pub")
package_update: false
CI

  for n in $(nodes); do
    case "$(vm_state "${n}")" in
      Running) log "${n}: уже запущена" ;;
      Stopped|Suspended) log "${n}: запуск"; multipass start "${n}" ;;
      "")
        if [[ "${n}" == *-cp ]]; then c=${CP_CPUS} m=${CP_MEM} d=${CP_DISK}; else c=${W_CPUS} m=${W_MEM} d=${W_DISK}; fi
        log "${n}: создание (Ubuntu ${IMAGE}, ${c} CPU, ${m} RAM, ${d} диск)"
        multipass launch "${IMAGE}" --name "${n}" --cpus "${c}" --memory "${m}" --disk "${d}" \
          --cloud-init "${STATE}/cloud-init.yaml" --timeout 900 >/dev/null
        ;;
      *) echo "${n}: неожиданное состояние $(vm_state "${n}")" >&2; exit 1 ;;
    esac
  done

  inv="${STATE}/inventory.ini"
  {
    echo "# сгенерировано scripts/multipass.sh — не редактировать"
    echo "[control_plane]"
    echo "${PREFIX}-cp ansible_host=$(vm_ip "${PREFIX}-cp")"
    echo
    echo "[workers]"
    for i in $(seq 1 "${WORKERS}"); do echo "${PREFIX}-w${i} ansible_host=$(vm_ip "${PREFIX}-w${i}")"; done
    echo
    echo "[k8s_cluster:children]"
    echo "control_plane"
    echo "workers"
    echo
    echo "[k8s_cluster:vars]"
    echo "ansible_user=ubuntu"
    echo "ansible_ssh_private_key_file=${STATE}/ssh/id_ed25519"
    echo "ansible_ssh_common_args='-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'"
  } > "${inv}"
  log "inventory: ${inv}"
  multipass list | grep -E "^(Name|${PREFIX}-)"
}

down() {
  for n in $(nodes); do
    [[ -n "$(vm_state "${n}")" ]] && { log "${n}: удаление"; multipass delete "${n}"; }
  done
  multipass purge
  rm -f "${STATE}/inventory.ini" "${STATE}/kubeconfig"
}

case "${1:-}" in
  up) up ;;
  down) down ;;
  *) echo "usage: $0 up|down" >&2; exit 2 ;;
esac
