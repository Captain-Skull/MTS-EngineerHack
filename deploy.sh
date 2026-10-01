#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

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
  sudo apt-get update -qq
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}"
fi

exec make "${@:-deploy}"
