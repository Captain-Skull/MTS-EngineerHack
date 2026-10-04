#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

if [[ -n "${HTTPS_PROXY:-${https_proxy:-}}" ]]; then
  export https_proxy="${https_proxy:-${HTTPS_PROXY}}"
  export HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy}}"
  export http_proxy="${http_proxy:-${HTTP_PROXY:-${https_proxy}}}"
  export HTTP_PROXY="${HTTP_PROXY:-${http_proxy}}"
fi

missing=()
for cmd in make git curl python3; do
  command -v "${cmd}" >/dev/null 2>&1 || missing+=("${cmd}")
done

if ((${#missing[@]})); then
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "Не найдены: ${missing[*]}. Установите их и запустите снова." >&2
    exit 1
  fi
  echo "Установка недостающих пакетов: ${missing[*]}"
  sudo --preserve-env=http_proxy,https_proxy apt-get update -qq
  sudo --preserve-env=http_proxy,https_proxy DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
fi

exec make "${@:-deploy}"
