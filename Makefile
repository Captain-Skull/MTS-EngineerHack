SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ROOT := $(abspath .)
export PATH := $(ROOT)/.bin:$(PATH)
export KUBECONFIG := $(ROOT)/.state/kubeconfig
export HELM_DATA_HOME := $(ROOT)/.helm/data
export HELM_CACHE_HOME := $(ROOT)/.helm/cache
export HELM_CONFIG_HOME := $(ROOT)/.helm/config
export ANSIBLE_CONFIG := $(ROOT)/ansible/ansible.cfg

comma := ,
HTTPS_PROXY ?= $(https_proxy)
HTTP_PROXY ?= $(or $(http_proxy),$(HTTPS_PROXY))
ifneq ($(strip $(HTTPS_PROXY)$(HTTP_PROXY)),)
USER_NO_PROXY := $(strip $(or $(NO_PROXY),$(no_proxy)))
HOST_IPS := $(shell hostname -I 2>/dev/null | xargs | tr ' ' ',')
override NO_PROXY := localhost,127.0.0.1,::1,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16,.svc,.cluster.local,.demo.test$(if $(HOST_IPS),$(comma)$(HOST_IPS))$(if $(USER_NO_PROXY),$(comma)$(USER_NO_PROXY))
export HTTP_PROXY HTTPS_PROXY NO_PROXY
export http_proxy := $(HTTP_PROXY)
export https_proxy := $(HTTPS_PROXY)
export no_proxy := $(NO_PROXY)
endif

INVENTORY ?= $(if $(wildcard .state/inventory.ini),.state/inventory.ini,ansible/inventory/local.ini)
BECOME_FLAG := $(shell sudo -n true 2>/dev/null || grep -q ansible_user $(INVENTORY) 2>/dev/null || echo --ask-become-pass)
ENV ?= default

.PHONY: help
help: ## Показать список команд
	@awk 'BEGIN{FS=":.*## "} /^[a-z-]+:.*## /{printf "  \033[36m%-14s\033[0m %s\n",$$1,$$2}' $(MAKEFILE_LIST)

.PHONY: tools
tools: ## Установить kubectl/helm/helmfile/ansible в ./.bin (зафиксированные версии)
	@./scripts/install-tools.sh

.PHONY: vms
vms: ## Создать VM Ubuntu 24.04 в Multipass (1 control-plane + 2 worker)
	@./scripts/multipass.sh up

.PHONY: cluster
cluster: tools ## Развернуть Kubernetes (kubeadm) на узлах из INVENTORY
	@mkdir -p .state
	ansible-playbook -i $(INVENTORY) ansible/site.yml $(BECOME_FLAG)

.PHONY: platform
platform: tools ## Установить платформу и приложение (helmfile apply)
	@./scripts/platform.sh apply

.PHONY: deploy
deploy: cluster platform test ## Полное развертывание: кластер + платформа + проверки

.PHONY: lab
lab: vms deploy ## Multipass-стенд + полное развертывание

.PHONY: test
test: ## Smoke-тесты (Gateway API, Prometheus, логирование)
	@./scripts/smoke-test.sh

.PHONY: chaos
chaos: ## Тест отказоустойчивости: сбои под нагрузкой (поды, Envoy, drain узла, Loki)
	@./scripts/chaos-test.sh

.PHONY: rollout
rollout: ## Progressive delivery (Flagger): исправная версия продвигается, неисправная откатывается (~7 мин)
	@./scripts/rollout-test.sh

.PHONY: load
load: ## Нагрузочный тест k6 через Gateway и проверка автомасштабирования HPA (~6 мин)
	@./scripts/load-test.sh

.PHONY: cis
cis: ## Проверка узлов по CIS Kubernetes Benchmark (kube-bench), отчёты в .state/cis
	@./scripts/cis-bench.sh

.PHONY: info
info: ## Адрес Gateway, строка для /etc/hosts, URL интерфейсов и пример curl
	@./scripts/info.sh

.PHONY: status
status: ## Состояние кластера и точки входа
	@kubectl get nodes -o wide
	@kubectl get gateway,httproute -A
	@kubectl get pods -A

.PHONY: diff
diff: tools ## Показать, что изменит helmfile apply
	@./scripts/platform.sh diff

.PHONY: reset
reset: tools ## Удалить кластер с узлов (kubeadm reset)
	ansible-playbook -i $(INVENTORY) ansible/reset.yml $(BECOME_FLAG)
	@rm -f .state/kubeconfig

.PHONY: etcd-backup
etcd-backup: ## Снапшот etcd сейчас (вне расписания CronJob)
	@job=etcd-backup-manual-$$(date +%s); \
	kubectl -n kube-system create job "$$job" --from=cronjob/etcd-backup >/dev/null; \
	kubectl -n kube-system wait job/"$$job" --for=condition=Complete --timeout=300s; \
	kubectl -n kube-system logs job/"$$job" -c store

.PHONY: etcd-restore
etcd-restore: tools ## Восстановить etcd: make etcd-restore SNAPSHOT=/var/backups/etcd/etcd-snapshot-<время>.db
	ansible-playbook -i $(INVENTORY) ansible/etcd-restore.yml -e etcd_snapshot=$(SNAPSHOT) $(BECOME_FLAG)

.PHONY: etcd-drill
etcd-drill: ## Учебное восстановление: метка → снапшот → изменения → restore → проверка
	@./scripts/etcd-drill.sh

.PHONY: vms-down
vms-down: ## Удалить VM Multipass
	@./scripts/multipass.sh down
