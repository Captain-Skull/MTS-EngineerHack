#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${ROOT}/.bin"
# shellcheck source=../versions.env
source "${ROOT}/versions.env"

mkdir -p "${BIN}"
export PATH="${BIN}:${PATH}"

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  x86_64 | amd64) ARCH=amd64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *) echo "Неподдерживаемая архитектура: $(uname -m)" >&2; exit 1 ;;
esac

log() { printf '\033[1;34m[tools]\033[0m %s\n' "$*"; }

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

download() {
  curl -fsSL --retry 3 -o "$2" "$1"
  if [[ -n "${3:-}" ]]; then
    local want
    want="$(curl -fsSL --retry 3 "$3" | awk '{print $1}')"
    echo "${want}  $2" | shasum -a 256 -c - >/dev/null
  fi
}

installed_version() { [[ -x "${BIN}/$1" ]] && "${BIN}/$1" "${@:2}" 2>/dev/null || true; }

if ! installed_version kubectl version --client | grep -q "${KUBECTL_VERSION}"; then
  log "kubectl ${KUBECTL_VERSION}"
  url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/${OS}/${ARCH}/kubectl"
  download "${url}" "${tmp}/kubectl" "${url}.sha256"
  install -m 0755 "${tmp}/kubectl" "${BIN}/kubectl"
fi

if ! installed_version helm version --short | grep -q "${HELM_VERSION}"; then
  log "helm ${HELM_VERSION}"
  f="helm-${HELM_VERSION}-${OS}-${ARCH}.tar.gz"
  download "https://get.helm.sh/${f}" "${tmp}/${f}" "https://get.helm.sh/${f}.sha256sum"
  tar -xzf "${tmp}/${f}" -C "${tmp}"
  install -m 0755 "${tmp}/${OS}-${ARCH}/helm" "${BIN}/helm"
fi

export HELM_DATA_HOME="${ROOT}/.helm/data" HELM_CACHE_HOME="${ROOT}/.helm/cache" HELM_CONFIG_HOME="${ROOT}/.helm/config"
if ! helm plugin list 2>/dev/null | grep -q "diff.*${HELM_DIFF_VERSION#v}"; then
  log "helm-diff ${HELM_DIFF_VERSION}"
  helm plugin uninstall diff >/dev/null 2>&1 || true
  pos="${OS/darwin/macos}"
  f="diff-${HELM_DIFF_VERSION#v}-${pos}-${ARCH}.tgz"
  base="https://github.com/databus23/helm-diff/releases/download/${HELM_DIFF_VERSION}"
  download "${base}/${f}" "${tmp}/${f}"
  grep " ${f}\$" <(curl -fsSL "${base}/helm-diff_${HELM_DIFF_VERSION#v}_checksums.txt") \
    | sed "s#${f}#${tmp}/${f}#" | shasum -a 256 -c - >/dev/null
  helm plugin install "${tmp}/${f}" --verify=false >/dev/null
fi

if ! installed_version helmfile --version | grep -q "${HELMFILE_VERSION#v}"; then
  log "helmfile ${HELMFILE_VERSION}"
  f="helmfile_${HELMFILE_VERSION#v}_${OS}_${ARCH}.tar.gz"
  base="https://github.com/helmfile/helmfile/releases/download/${HELMFILE_VERSION}"
  download "${base}/${f}" "${tmp}/${f}"
  grep " ${f}\$" <(curl -fsSL "${base}/helmfile_${HELMFILE_VERSION#v}_checksums.txt") \
    | sed "s#${f}#${tmp}/${f}#" | shasum -a 256 -c - >/dev/null
  tar -xzf "${tmp}/${f}" -C "${tmp}" helmfile
  install -m 0755 "${tmp}/helmfile" "${BIN}/helmfile"
fi

if ! installed_version uv --version | grep -q "${UV_VERSION}"; then
  log "uv ${UV_VERSION}"
  case "${OS}-${ARCH}" in
    linux-amd64) t=x86_64-unknown-linux-gnu ;;
    linux-arm64) t=aarch64-unknown-linux-gnu ;;
    darwin-amd64) t=x86_64-apple-darwin ;;
    darwin-arm64) t=aarch64-apple-darwin ;;
  esac
  f="uv-${t}.tar.gz"
  base="https://github.com/astral-sh/uv/releases/download/${UV_VERSION}"
  download "${base}/${f}" "${tmp}/${f}" "${base}/${f}.sha256"
  tar -xzf "${tmp}/${f}" -C "${tmp}"
  install -m 0755 "${tmp}/uv-${t}/uv" "${BIN}/uv"
fi

VENV="${ROOT}/.venv"
if ! installed_version ansible-playbook --version | grep -q "core ${ANSIBLE_CORE_VERSION}"; then
  log "ansible-core ${ANSIBLE_CORE_VERSION}"
  UV_PYTHON_INSTALL_DIR="${ROOT}/.uv/python" uv venv --quiet --allow-existing --python 3.12 "${VENV}"
  VIRTUAL_ENV="${VENV}" uv pip install --quiet "ansible-core==${ANSIBLE_CORE_VERSION}"
  for b in ansible ansible-playbook ansible-galaxy; do ln -sf "${VENV}/bin/${b}" "${BIN}/${b}"; done
fi
ansible-galaxy collection install -r "${ROOT}/ansible/requirements.yml" -p "${ROOT}/.ansible/collections" \
  >"${tmp}/galaxy.log" 2>&1 || { cat "${tmp}/galaxy.log" >&2; exit 1; }

log "готово: $(ls "${BIN}" | tr '\n' ' ')"
