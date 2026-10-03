# MTS EngineerHack — Kubernetes, Gateway API, мониторинг и логирование одной командой

[![ci](https://github.com/Captain-Skull/MTS-EngineerHack/actions/workflows/ci.yml/badge.svg)](https://github.com/Captain-Skull/MTS-EngineerHack/actions/workflows/ci.yml)
[![image](https://github.com/Captain-Skull/MTS-EngineerHack/actions/workflows/image.yml/badge.svg)](https://github.com/Captain-Skull/MTS-EngineerHack/actions/workflows/image.yml)

Решение кейса DevOps хакатона MTS EngineerHack: с нуля разворачивает кластер Kubernetes через **kubeadm** на Ubuntu 24.04, публикует веб-приложение через **Kubernetes Gateway API**, собирает метрики в **Prometheus** и логи через **Fluentd**. Всё развертывание — `make deploy`; повторный запуск безопасен. Работоспособность на чистой Ubuntu 24.04 проверяется в CI на каждый коммит.

## Содержание

- [Быстрый старт](#быстрый-старт)
- [Как это выглядит](#как-это-выглядит)
- [Архитектура](#архитектура)
- [Технологии и версии](#технологии-и-версии)
- [Требования к среде](#требования-к-среде)
- [Развертывание по шагам](#развертывание-по-шагам)
- [Проверка приложения и Gateway API](#проверка-приложения-и-gateway-api)
- [Проверка мониторинга](#проверка-мониторинга)
- [Проверка логирования](#проверка-логирования)
- [Проверка трейсинга](#проверка-трейсинга)
- [Резервное копирование etcd](#резервное-копирование-etcd)
- [Политики допуска и подпись образов](#политики-допуска-и-подпись-образов)
- [Progressive delivery (Flagger)](#progressive-delivery-flagger)
- [Нагрузочный тест и автомасштабирование](#нагрузочный-тест-и-автомасштабирование)
- [Соответствие CIS Kubernetes Benchmark](#соответствие-cis-kubernetes-benchmark)
- [Тест отказоустойчивости](#тест-отказоустойчивости)
- [Дополнительные возможности](#дополнительные-возможности)
- [CI/CD](#cicd)
- [Структура репозитория](#структура-репозитория)
- [Известные ограничения](#известные-ограничения)
- [Удаление](#удаление)

## Быстрый старт

На машине с **Ubuntu 24.04** (физической или виртуальной), пользователь с `sudo`:

```bash
git clone https://github.com/Captain-Skull/MTS-EngineerHack.git
cd MTS-EngineerHack
./deploy.sh
```

`./deploy.sh` доустанавливает через apt отсутствующие базовые утилиты (`make`, `git`, `curl`, `python3` — на минимальных образах Ubuntu `make` нет) и запускает `make deploy`. Если `make` уже установлен, можно сразу выполнять `make deploy`. За ~15–20 минут выполняется:

1. `make tools` — скачивает в `./.bin` зафиксированные версии kubectl, helm, helmfile и ansible-core (со сверкой sha256, систему не меняет);
2. `make cluster` — Ansible готовит ОС и создаёт кластер kubeadm на этой машине;
3. `make platform` — helmfile устанавливает сеть, Gateway API, мониторинг, логирование и приложение;
4. `make test` — 35 автоматических проверок: приложение через Gateway API, progressive delivery (Flagger), метрики в Prometheus, логи в Loki, трейсы в Tempo, бэкап etcd, политики допуска Kyverno.

Если `sudo` требует пароль, Ansible спросит его один раз. Затем:

```bash
make info
```

покажет адрес Gateway, строку для `/etc/hosts`, адреса интерфейсов и готовую команду `curl`. Пароль администратора интерфейсов генерируется при развертывании и сохраняется в `.state/credentials`.

## Как это выглядит

Снимки с работающего стенда (одна машина Ubuntu 24.04, `./deploy.sh`) под фоновой нагрузкой.

**Дашборд Grafana «Hello service»: SLO и бюджет ошибок, RED-метрики через Gateway, canary v1/v2**

![SLO, RED-метрики и canary в Grafana](docs/images/grafana-slo-red-canary.png)

**Конвейер логов: Fluentd → Loki, живая лента access-логов nginx с request_id**

![Логирование в Grafana](docs/images/grafana-logging.png)

**Hubble: сетевые потоки namespace `demo` — к приложению ходят только Envoy (8080) и Prometheus (9113), как разрешает NetworkPolicy**

![Карта потоков Hubble](docs/images/hubble-demo.png)

<details>
<summary><b>Вывод <code>make test</code></b></summary>

```text

0. Кластер
  ✔ API server доступен
  ✔ все узлы Ready (1/1)

1. Gateway API
  ✔ Gateway envoy-gateway-system/public Programmed
  ✔ HTTPRoute demo/hello Accepted
     адрес Gateway: 192.168.252.7
  ✔ HTTP → 301 редирект на HTTPS (получено 301)
  ✔ HTTPS (TLS проверен по CA стенда) → «Hello World!»: Hello World! version=v1 pod=hello-v1-d4849fdd-pjqbd
  ✔ X-Canary: always → версия v2
  ✔ /v1 → версия v1 (URLRewrite)
  ✔ /v2 → версия v2 (URLRewrite)
  ✔ canary: 4/40 запросов на v2 (ожидается ~10%)
  ✔ Prometheus UI без пароля → 401 (получено 401)
  ✔ Prometheus UI с basic auth → 200 (получено 200)
  ✔ Grafana через Gateway /api/health

2. Логирование (nginx → Fluentd → Loki)
     отправлен запрос с X-Request-Id: smoke-1790950226-9116
  ✔ access-лог запроса (nginx) найден в Loki: {namespace="demo", container="nginx"} |= "smoke-1790950226-9116"
     {"time":"2026-10-02T17:10:26.834180852+03:00","kubernetes":{"pod_name":"hello-v1-d4849fdd-fzm69","pod_id":"59795575-d11b-48fc-b1c5-a47aaf93be0…
  ✔ тот же запрос в access-логе Envoy Gateway (сквозной request_id)

3. Мониторинг (Prometheus)
  ✔ PromQL up{job=~"hello-v.*"} → 4 рядов
  ✔ PromQL nginx_http_requests_total → 4 рядов
  ✔ PromQL envoy_cluster_upstream_rq_total → 16 рядов
  ✔ PromQL fluentd_output_status_emit_records → 4 рядов
  ✔ PromQL node_cpu_seconds_total → 32 рядов
  ✔ PromQL kube_pod_status_ready → 102 рядов
  ✔ PromQL hubble_flows_processed_total → 11 рядов
  ✔ все targets Prometheus в состоянии up
  ✔ правила Prometheus (включая SLO) загружены и вычисляются без ошибок
     текущий RPS приложения: 2.76175094979364

4. Резервное копирование etcd
  ✔ снапшот etcd снят и проверен: snapshot saved: /backups/etcd-snapshot-20261002T141043Z.db (37629984 bytes)

Итог: 25 пройдено, 0 провалено
```

</details>

## Архитектура

```mermaid
flowchart LR
    U[Пользователь<br/>curl / браузер] -->|HTTPS :443<br/>HTTP :80 → 301| LB

    subgraph K8S[Kubernetes 1.36.5 · kubeadm · Cilium без kube-proxy]
        LB[Service LoadBalancer<br/>Cilium Node IPAM:<br/>IP узлов] --> GW

        subgraph EGS[envoy-gateway-system]
            EG[Envoy Gateway<br/>controller] -.xDS.-> GW[Envoy proxy x2<br/>Gateway public<br/>TLS cert-manager]
        end

        subgraph DEMO[demo · PSA restricted]
            GW -->|HTTPRoute hello<br/>90%| V1[nginx v1]
            GW -->|10% / X-Canary / /v2| V2[nginx v2]
        end

        subgraph MON[monitoring]
            P[(Prometheus)] --> G[Grafana]
            P --> AM[Alertmanager]
        end

        subgraph LOG[logging]
            F[Fluentd<br/>DaemonSet] --> L[(Loki)]
        end

        subgraph TR[tracing]
            OC[OpenTelemetry<br/>Collector] --> T[(Tempo)]
        end

        V1 -. "/metrics (exporter)" .-> P
        GW -. "/stats/prometheus" .-> P
        V1 -. "JSON access-лог → /var/log/containers" .-> F
        GW -. "JSON access-лог" .-> F
        L --> G
        GW -. "спаны OTLP" .-> OC
        V1 -. "спаны OTLP" .-> OC
        T --> G
        T -. "граф сервисов, span-метрики" .-> P
    end
```

**Путь запроса.** Запрос на IP узла:443 перехватывает eBPF-программа Cilium (сервис Envoy имеет тип LoadBalancer, адреса — IP узлов) и направляет в под Envoy. Envoy терминирует TLS (wildcard-сертификат `*.demo.test` от cert-manager), по `HTTPRoute` выбирает версию приложения (canary 90/10, заголовок `X-Canary`, путь `/v1` `/v2`) и проксирует в Service. NetworkPolicy разрешает приложению входящий трафик только от Envoy и Prometheus.

**Путь лога.** nginx и Envoy пишут JSON access-логи в stdout → containerd сохраняет их в файлы на узле → Fluentd (по поду на узел) читает файлы, добавляет метаданные Kubernetes, разбирает JSON и отправляет в Loki → просмотр в Grafana. Envoy генерирует `X-Request-Id`, nginx пишет его в свой лог: один запрос находится в логах обоих компонентов.

**Путь трейса.** Envoy начинает (или продолжает, если клиент прислал W3C `traceparent`) трейс и передаёт контекст в nginx; оба отправляют спаны по OTLP в OpenTelemetry Collector, который добавляет атрибуты Kubernetes и пересылает их в Tempo. Tempo строит из трейсов граф сервисов и метрики спанов и записывает их в Prometheus. `trace_id` есть в access-логах Envoy и nginx: в Grafana можно перейти от строки лога к трейсу и обратно.

**Путь метрики.** Prometheus по ServiceMonitor/PodMonitor собирает метрики nginx (sidecar-экспортер), Envoy, Cilium/Hubble, узлов, Kubernetes, control plane, Fluentd, Loki и cert-manager.

**Слои развертывания:**

| Слой | Инструмент | Что делает |
|---|---|---|
| Машины | Multipass (опционально) | VM Ubuntu 24.04 для локального стенда на macOS/Linux |
| ОС и кластер | Ansible + kubeadm | пакеты, ядро, containerd, kubelet, `kubeadm init/join` |
| Платформа | Helmfile (20 Helm-релизов) | Cilium, Envoy Gateway, cert-manager, мониторинг, логирование, трейсинг, бэкапы etcd, Kyverno, Flagger |
| Приложение и связи | собственные Helm-чарты | `charts/hello`, `charts/platform-config` |
| Точка входа | Make | `make deploy`, `make test`, `make info` |

Почему выбраны именно эти компоненты, какие альтернативы рассматривались и чем за выбор приходится платить — в [архитектурных решениях (ADR)](docs/adr/README.md).

## Технологии и версии

| Компонент | Версия | Назначение |
|---|---|---|
| **Kubernetes** | **1.36.5** | оркестратор; создаётся **kubeadm** |
| ОС | **Ubuntu 24.04 LTS** | протестировано: Ubuntu 24.04.5 (arm64, Multipass) и GitHub runner `ubuntu-24.04` (amd64) |
| containerd / runc | 2.4.1 / 1.5.2 | container runtime |
| Cilium | 1.20.2 | CNI на eBPF, замена kube-proxy, Node IPAM, NetworkPolicy, Hubble |
| **Envoy Gateway** | **1.9.2** (Envoy 1.39.1) | реализация **Gateway API v1.6.1** |
| cert-manager | 1.21.2 | выпуск и продление TLS-сертификатов |
| kube-prometheus-stack | 91.8.2 | Prometheus 3.15.0, Alertmanager 0.34.1, Grafana 13.2.3, node-exporter 1.12.1, kube-state-metrics 2.20.0 |
| **Fluentd** | **1.19.3** | сбор логов (собственный multi-arch образ с плагином Loki) |
| Loki | 3.7.8 (чарт grafana-community 18.13.7) | хранилище логов |
| Tempo | 3.1.0 | хранилище трейсов, metrics-generator (граф сервисов, span-метрики) |
| OpenTelemetry Collector | 0.161.0 (чарт 0.175.0) | приём спанов OTLP, атрибуты Kubernetes, отправка в Tempo |
| nginx (unprivileged, `-otel`) | 1.31.6 | демо-приложение с модулем OpenTelemetry + nginx-prometheus-exporter 1.5.3 |
| Flagger | 1.45.0 | progressive delivery: canary через Gateway API с анализом метрик Prometheus и автоматическим откатом |
| podinfo | 6.15.0 | демо-приложение для progressive delivery |
| Kyverno | 1.19.1 (чарт 3.9.1) | политики допуска: проверка подписи образов cosign, образы только по digest |
| metrics-server | 0.9.0 | метрики ресурсов для HPA |
| kubelet-csr-approver | 1.2.15 | одобрение serving-сертификатов kubelet |
| local-path-provisioner | 0.0.37 | PersistentVolume на дисках узлов |
| Ansible (ansible-core) | 2.21.4 | настройка узлов |
| Helm / Helmfile | 4.3.0 / 1.8.1 | установка платформы |

Все версии зафиксированы: CLI — в [`versions.env`](versions.env), компоненты узлов — в [`ansible/group_vars/all.yml`](ansible/group_vars/all.yml), чарты — в [`helmfile/helmfile.yaml.gotmpl`](helmfile/helmfile.yaml.gotmpl), образы приложения — по digest.

> **Почему Kubernetes 1.36, а не 1.37.** Cilium 1.20 и Envoy Gateway 1.9 официально протестированы на Kubernetes 1.33–1.36. Выбрана последняя версия, поддерживаемая всеми компонентами.

### Ресурсы Gateway API

| Ресурс | Имя | Назначение |
|---|---|---|
| `GatewayClass` | `eg` | контроллер Envoy Gateway + параметры прокси (`EnvoyProxy eg-proxy`) |
| `Gateway` | `envoy-gateway-system/public` | слушатели HTTP:80 и HTTPS:443 (`*.demo.test`, TLS terminate), маршруты принимаются только из namespace с меткой `mts-hack/gateway-access=true` |
| `HTTPRoute` | `demo/hello` | `hello.demo.test`: заголовок `X-Canary: always` → v2; `/v1`, `/v2` → конкретная версия (URLRewrite); остальное → 90% v1 / 10% v2 |
| `HTTPRoute` | `demo/rollout` | `rollout.demo.test`: **создаётся и управляется Flagger** — веса стабильной версии и canary меняются по шагам анализа |
| `HTTPRoute` | `envoy-gateway-system/http-to-https` | редирект HTTP → HTTPS (301) |
| `HTTPRoute` | `grafana`, `prometheus`, `alertmanager`, `hubble` | служебные интерфейсы по hostname |
| `ClientTrafficPolicy` | `public-client` | TLS ≥ 1.2, HTTP/2, генерация `X-Request-Id` |
| `BackendTrafficPolicy` | `demo/hello` | rate limit 100 rps на реплику Envoy, retries, таймауты, circuit breaker, outlier detection |
| `SecurityPolicy` | `*-basic-auth` | basic auth для Prometheus, Alertmanager, Hubble |

## Требования к среде

| | Минимум | Рекомендуется |
|---|---|---|
| ОС | Ubuntu 24.04 LTS (amd64 или arm64) | чистая установка |
| CPU | 4 vCPU | 4+ vCPU |
| RAM | 8 ГБ | 16 ГБ |
| Диск | 30 ГБ свободно | 40 ГБ |
| Сеть | доступ в интернет (пакеты, образы, чарты) | |
| Права | пользователь с `sudo` | |

Порты 80, 443 и 6443 на машине должны быть свободны. Предустановка Docker, kubectl или helm не требуется; если Docker уже установлен, он продолжит работать (kubeadm использует containerd).

## Развертывание по шагам

### Вариант 1. Одна машина Ubuntu 24.04 (основной)

```bash
git clone https://github.com/Captain-Skull/MTS-EngineerHack.git
cd MTS-EngineerHack
sudo apt-get install -y make   # если make отсутствует
make tools      # инструменты в ./.bin
make cluster    # Kubernetes через kubeadm (кластер из одного узла)
make platform   # платформа и приложение
make test       # проверки
make info       # адреса и доступы
```

`make deploy` (или `./deploy.sh`) выполняет `cluster`, `platform` и `test` подряд. Повторный запуск любой команды не меняет работающую систему: Ansible сообщает `changed=0`, helmfile применяет только отличия.

Для работы с кластером напрямую:

```bash
export KUBECONFIG=$PWD/.state/kubeconfig PATH=$PWD/.bin:$PATH
kubectl get nodes
```

(`kubectl` также настроен для пользователя, запустившего `make cluster`, через `~/.kube/config`.)

### Вариант 2. Несколько серверов

Заполните inventory по образцу [`ansible/inventory/example-multinode.ini`](ansible/inventory/example-multinode.ini) (1 control-plane, N worker, доступ по SSH с sudo) и выполните:

```bash
make deploy INVENTORY=ansible/inventory/my-cluster.ini
```

### Вариант 3. Локальный стенд на macOS/Linux (Multipass)

```bash
make lab        # 3 VM Ubuntu 24.04 (1 control-plane + 2 worker) + make deploy
make vms-down   # удалить VM
```

Размер стенда настраивается переменными: `MP_WORKERS=0 make lab` — одна VM.

## Проверка приложения и Gateway API

```bash
make info
```

Пусть `GW` — адрес Gateway из вывода (`kubectl -n envoy-gateway-system get gateway public`). Проверки без правки `/etc/hosts` (`.state/ca.crt` — CA стенда, TLS проверяется полностью):

```bash
curl --cacert .state/ca.crt --resolve hello.demo.test:443:$GW https://hello.demo.test/
# Hello World! version=v1 pod=hello-v1-...

curl -I --resolve hello.demo.test:80:$GW http://hello.demo.test/
# HTTP/1.1 301 Moved Permanently → https://

curl --cacert .state/ca.crt --resolve hello.demo.test:443:$GW -H 'X-Canary: always' https://hello.demo.test/
# version=v2

curl --cacert .state/ca.crt --resolve hello.demo.test:443:$GW https://hello.demo.test/v1
# version=v1

for i in $(seq 100); do curl -s --cacert .state/ca.crt --resolve hello.demo.test:443:$GW https://hello.demo.test/; done | grep -o 'version=v.' | sort | uniq -c
# ~90 v1 / ~10 v2
```

Состояние ресурсов Gateway API:

```bash
kubectl get gatewayclass,gateway,httproute -A
kubectl -n envoy-gateway-system describe gateway public     # Accepted, Programmed, адрес
kubectl -n demo describe httproute hello                    # Accepted, ResolvedRefs
```

После добавления строки из `make info` в `/etc/hosts` приложение доступно в браузере: `https://hello.demo.test` (браузер предупредит о сертификате — он выпущен собственным CA стенда, файл `.state/ca.crt`).

## Проверка мониторинга

**Что собирается:**

| Источник | Метрики |
|---|---|
| nginx (sidecar nginx-prometheus-exporter, ServiceMonitor) | запросы, активные соединения; метка `version` (v1/v2) |
| Envoy Gateway (PodMonitor) | RPS, коды ответа по классам, гистограммы задержек, retries, rate limit |
| node-exporter | CPU, память, диски, сеть узлов |
| kube-state-metrics, kubelet/cAdvisor | состояние объектов, реплики, рестарты, CPU/RAM контейнеров |
| control plane | kube-apiserver, etcd, scheduler, controller-manager, CoreDNS |
| Cilium / Hubble | агент, оператор, сетевые потоки, дропы, DNS |
| Fluentd, Loki, cert-manager | конвейер логов, хранилище, сроки сертификатов |

**Проверка в интерфейсе.** `https://prometheus.demo.test` (логин `admin`, пароль из `.state/credentials`) → *Status → Target health*: все цели в состоянии UP. Примеры запросов:

```promql
up{namespace="demo"}
sum by (version) (rate(nginx_http_requests_total[5m]))
sum by (envoy_response_code_class) (rate(envoy_cluster_upstream_rq_xx{envoy_cluster_name=~"httproute/demo/hello/.*"}[5m]))
histogram_quantile(0.99, sum by (le) (rate(envoy_cluster_upstream_rq_time_bucket{envoy_cluster_name=~"httproute/demo/hello/.*"}[5m])))
```

**Проверка из командной строки** (через API server, без port-forward):

```bash
kubectl get --raw '/api/v1/namespaces/monitoring/services/kube-prometheus-stack-prometheus:9090/proxy/api/v1/query?query=nginx_http_requests_total'
```

**Grafana** — `https://grafana.demo.test` → *Dashboards → MTS Hack → «Hello service — SLO, RED, canary, логи»*: SLO и остаток бюджета ошибок, burn rate, RPS, доля 5xx, перцентили задержки, распределение трафика v1/v2, коды ответов по версиям из логов, ресурсы, HPA, состояние конвейера логов, лента access-логов. Также доступны стандартные дашборды kube-prometheus-stack (узлы, поды, API server, etcd).

**SLO и бюджет ошибок** (`charts/platform-config/templates/slo.yaml`, цели — в `charts/platform-config/values.yaml`, окно 7 дней по сроку хранения Prometheus):

| SLO | SLI | Цель |
|---|---|---|
| Доступность | доля ответов backend-а hello без 5xx (метрики Envoy) | 99.9% |
| Задержка | доля запросов, обслуженных быстрее 250 мс (гистограмма Envoy) | 99% |

Алерты по **burn rate** (скорости расходования бюджета ошибок) по методике Google SRE с парами окон: `HelloAvailabilityBudgetBurnFast` / `HelloLatencyBudgetBurnFast` — critical, 14.4× за 1 ч и 5 мин или 6× за 6 ч и 30 мин; `...BudgetBurnSlow` — warning, 3× за 1 день и 2 ч или 1× за 3 дня и 6 ч. Короткое окно гасит алерт сразу после устранения проблемы. Проверка: в течение нескольких минут отправлять часть запросов на `https://hello.demo.test/error` → в Prometheus *Alerts* алерт `HelloAvailabilityBudgetBurnFast` переходит в `firing`; на дашборде растёт burn rate и падает остаток бюджета.

**Остальные алерты** (`charts/platform-config/templates/alerts.yaml`): нет готовых реплик, target приложения недоступен, недоступен Gateway, срабатывает rate limit, Fluentd не отправляет логи, получает ошибки или копит буфер, Loki недоступен, сертификат истекает или не выпущен.

## Проверка логирования

**Что собирается:** stdout/stderr всех контейнеров кластера (access-логи nginx и Envoy в JSON, error-лог nginx), а также аудит-журнал API server. **Куда:** Fluentd (DaemonSet, по экземпляру на узел) → Loki (namespace `logging`) → Grafana. Метки потоков: `namespace`, `container`, `app`, `node`, `stream`, `cluster`; поля JSON (status, uri, request_id, app_version, pod …) доступны парсером LogQL.

**Сценарий проверки:** отправить запрос с уникальным идентификатором и найти его в логах.

```bash
curl --cacert .state/ca.crt --resolve hello.demo.test:443:$GW -H 'X-Request-Id: check-001' https://hello.demo.test/
```

В Grafana → *Explore* → источник *Loki*:

```logql
{namespace=~"demo|envoy-gateway-system"} |= "check-001"
```

Появятся две записи: от Envoy (маршрут, upstream-под, длительность) и от nginx (версия, под, статус). Другие запросы:

```logql
{namespace="demo", container="nginx"} | json | status >= 400
sum by (app_version, status) (count_over_time({namespace="demo", container="nginx"} | json [5m]))
{container="kube-apiserver-audit"} | json | verb="delete"
```

Из командной строки:

```bash
kubectl get --raw '/api/v1/namespaces/logging/services/loki:3100/proxy/loki/api/v1/query_range?query=%7Bnamespace%3D%22demo%22%7D%20%7C%3D%20%22check-001%22'
```

Этот же сценарий автоматически выполняет `make test`.

## Проверка трейсинга

**Что собирается:** спаны Envoy Gateway (входящий запрос и вызов backend-а с именем правила HTTPRoute) и nginx (модуль `ngx_otel_module`) с контекстом W3C Trace Context; семплирование 100% (настраивается в `charts/platform-config/values.yaml`). **Куда:** OpenTelemetry Collector (namespace `tracing`) → Tempo (хранение 72 ч) → Grafana. Tempo metrics-generator строит граф сервисов (`traces_service_graph_request_total`) и метрики спанов (`traces_spanmetrics_*`) и отправляет их в Prometheus по remote write.

**Сценарий проверки:** отправить запрос с собственным trace_id и найти трейс.

```bash
TID=$(openssl rand -hex 16)
curl --cacert .state/ca.crt --resolve hello.demo.test:443:$GW \
  -H "traceparent: 00-$TID-$(openssl rand -hex 8)-01" https://hello.demo.test/
kubectl get --raw "/api/v1/namespaces/tracing/services/tempo:3200/proxy/api/v2/traces/$TID"
```

Трейс содержит спаны сервисов `public.envoy-gateway-system` и `hello-v1`/`hello-v2`. В Grafana → *Explore* → *Tempo* можно найти трейс по ID или TraceQL (`{ resource.service.name =~ "hello-.*" }`), открыть **Service Graph** (user → Envoy → hello-v1/v2 с числом запросов — видно canary) и перейти к логам этого запроса в Loki; из строки лога в Loki ссылка «Открыть трейс» ведёт в Tempo. На дашборде «Hello service» — раздел «Трейсинг»: граф сервисов и последние трейсы. `make test` выполняет эту проверку автоматически.

## Резервное копирование etcd

etcd хранит всё состояние кластера; его потеря без резервной копии означает потерю кластера.

- **Автоматически:** CronJob `kube-system/etcd-backup` (чарт [`charts/etcd-backup`](charts/etcd-backup)) каждые 6 часов на control-plane узле снимает снапшот (`etcdctl snapshot save`), **проверяет его целостность** (`etcdutl snapshot status`) и сохраняет в `/var/backups/etcd/etcd-snapshot-<время>.db`, храня 14 последних копий (3,5 дня).
- **Вручную:** `make etcd-backup` — снапшот сейчас.
- **Восстановление:** `make etcd-restore SNAPSHOT=/var/backups/etcd/etcd-snapshot-<время>.db` — Ansible-плейбук [`ansible/etcd-restore.yml`](ansible/etcd-restore.yml) останавливает static pods etcd и kube-apiserver, восстанавливает данные `etcdutl snapshot restore` образом etcd самого кластера, подменяет `/var/lib/etcd` (прежние данные сохраняются рядом), дожидается готовности API и, как рекомендует документация Kubernetes, перезапускает компоненты с закэшированным состоянием: kube-controller-manager, kube-scheduler, kubelet, а также Cilium (иначе eBPF-таблица сервиса `kubernetes` остаётся без бэкендов).
- **Учебное восстановление:** `make etcd-drill` — создаёт объект-метку, снимает снапшот, удаляет метку и создаёт другую, восстанавливает кластер и проверяет, что вернулось ровно состояние на момент снапшота. Выполняется в CI на каждом коммите вместе с повторным прогоном `make test`.
- **Мониторинг:** алерты `EtcdBackupMissing` (нет успешного бэкапа больше 13 часов) и `EtcdBackupJobFailed`; smoke-тест запускает задание бэкапа и проверяет его успешное завершение.

## Политики допуска и подпись образов

Образ Fluentd собирается в CI и подписывается **cosign keyless** (подпись через OIDC-токен GitHub Actions, запись в прозрачный журнал Rekor). Kyverno ([`charts/policies`](charts/policies)) проверяет эту подпись **при каждом создании пода** — так цепочка поставок замкнута: «собрано CI этого репозитория → подписано → в кластере запускается только подписанное».

| Политика | Тип | Что делает |
|---|---|---|
| `verify-image-signatures` | ImageValidatingPolicy, `Deny` | Образы `ghcr.io/captain-skull/*` допускаются, только если подписаны workflow `image.yml` этого репозитория из ветки `main` (проверяются издатель OIDC, identity и запись в Rekor). Проверенный образ закрепляется по digest — тег нельзя подменить между проверкой и запуском |
| `require-image-digest` | ValidatingPolicy (CEL), `Deny` | В namespace приложения `demo` контейнеры обязаны ссылаться на образ по `@sha256:…`. Проверка срабатывает уже на Deployment, а не только на поде |

- **Надёжность:** webhook работает в режиме `failurePolicy: Fail` (без проверки под не создаётся), поэтому admission controller Kyverno запущен в 2 репликах с PodDisruptionBudget и распределением по узлам; `make chaos` подтверждает, что drain узла проходит без ошибок. Алерты: `KyvernoAdmissionUnavailable` (critical) и `KyvernoAdmissionDenials` (info).
- **Проверка (`make test`):** подписанный образ допускается и закрепляется по digest; образ без подписи отклоняется; **тот же подписанный образ отклоняется**, если временно доверять другому подписанту (доказывает, что подпись действительно проверяется, а не только наличие образа); под без digest в `demo` отклоняется.
- **В CI** образ Fluentd собирается из исходников pull request как `ci.local/fluentd-k8s-loki:ci`: он не публикуется и не подписывается, поэтому под политику подписи не попадает. Сама политика в CI работает в режиме `Deny` и проверяется smoke-тестом на опубликованном образе.

Попробовать вручную:

```bash
kubectl run test --image=ghcr.io/captain-skull/fluentd-k8s-loki:1.19.3-1 --dry-run=server -o jsonpath='{.spec.containers[0].image}'
# ghcr.io/captain-skull/fluentd-k8s-loki:1.19.3-1@sha256:79a7…
kubectl run test --image=ghcr.io/captain-skull/fluentd-k8s-loki:unsigned --dry-run=server
# Error from server: admission webhook … denied the request
```

## Progressive delivery (Flagger)

Canary 90/10 у `hello` — ручной: вес задан в values. Для автоматической выкатки используется [Flagger](https://flagger.app) (провайдер Gateway API v1). Он управляет отдельным демо-сервисом `rollout.demo.test` ([`charts/rollout`](charts/rollout), приложение [podinfo](https://github.com/stefanprodan/podinfo)):

1. При изменении Deployment `demo/rollout` Flagger поднимает новую версию рядом со стабильной (`rollout-primary`) и **сам меняет веса в `HTTPRoute`**: 20% → 40% → 60%.
2. Каждые 20 секунд он запрашивает у Prometheus **долю ответов 5xx** и **p99 задержки** новой версии (собственные `MetricTemplate`, метрики приложения).
3. Если метрики в норме, новая версия становится стабильной. Если порог (1% ошибок или 0,5 с) нарушен 3 раза — **автоматический откат**: весь трафик возвращается на стабильную версию, срабатывает алерт `CanaryRolledBack`.

`make rollout` ([`scripts/rollout-test.sh`](scripts/rollout-test.sh)) проверяет это под нагрузкой через Gateway: выкатывает исправную версию (должна продвинуться без ошибок у клиентов), затем неисправную (podinfo с `--random-error` — треть ответов с ошибкой; должна откатиться), затем возвращает версию из Git. На дашборде «Hello service» — раздел Flagger: результат анализа, веса трафика по шагам и запросы/ошибки по версиям. Тест выполняется в CI на каждом коммите.

Ошибки при неудачной выкатке получает только доля трафика canary (20%) и только до отката — в примере ниже 4,4% запросов за время анализа и ни одной после.

```text
Progressive delivery (Flagger): https://rollout.demo.test, сейчас отвечает «стабильная версия из Git»

1. Новая исправная версия: Flagger постепенно переводит трафик и продвигает её
     01:29:23  Progressing вес canary 0%, неудачных проверок 0
     01:29:42  Progressing вес canary 20%, неудачных проверок 0
     01:30:04  Progressing вес canary 40%, неудачных проверок 0
     01:30:23  Progressing вес canary 60%, неудачных проверок 0
     01:30:44  Promoting вес canary 60%, неудачных проверок 0
     01:31:03  Finalising вес canary 0%, неудачных проверок 0
     01:31:25  Succeeded вес canary 0%, неудачных проверок 0
     1469 200  новая версия 012913
     1294 200  стабильная версия из Git
  ✔ версия продвинута: весь трафик получает «новая версия 012913»
  ✔ клиенты не получили ни одной ошибки (2763 запросов)

2. Неисправная версия (треть ответов — 500): Flagger должен откатить её
     01:31:43  Progressing вес canary 0%, неудачных проверок 0
     01:32:04  Progressing вес canary 20%, неудачных проверок 0
     01:32:23  Progressing вес canary 20%, неудачных проверок 1
     01:32:45  Progressing вес canary 20%, неудачных проверок 2
     01:33:03  Progressing вес canary 20%, неудачных проверок 3
     01:33:25  Failed вес canary 0%, неудачных проверок 0
     2347 200  новая версия 012913
      229 200  неисправная версия 012913
       49 400  -
       36 500  -
       33 409  -
  ✔ откат выполнен: весь трафик снова получает «новая версия 012913»
     ошибок у клиентов за время анализа: 118 из 2694 (4.4%) — только доля трафика canary до отката
  ✔ после отката ошибок нет (324 запросов за 15 с)

3. Возврат версии из Git
     01:34:03  Progressing вес canary 0%, неудачных проверок 0
     01:34:25  Progressing вес canary 20%, неудачных проверок 0
     01:34:43  Progressing вес canary 40%, неудачных проверок 0
     01:35:02  Progressing вес canary 60%, неудачных проверок 0
     01:35:24  Promoting вес canary 60%, неудачных проверок 0
     01:35:44  Finalising вес canary 0%, неудачных проверок 0
     01:36:03  Succeeded вес canary 0%, неудачных проверок 0
  ✔ кластер снова соответствует Git: «стабильная версия из Git»

Итог: 5 пройдено, 0 провалено
```

## Нагрузочный тест и автомасштабирование

`make load` ([`scripts/load-test.sh`](scripts/load-test.sh), сценарий [`scripts/k6/hello.js`](scripts/k6/hello.js)) запускает [k6](https://k6.io) как Job внутри кластера: нагрузка идёт **через Gateway по HTTPS** с проверкой сертификата по CA стенда, как от настоящего клиента. Нагрузка растёт до 150 запросов/с за минуту и держится 4 минуты. Скрипт каждые 15 секунд показывает реплики и загрузку CPU по HPA и проверяет два результата:

- **пороги k6:** ошибок меньше 1%, p95 задержки меньше 300 мс (иначе k6 завершается с ошибкой);
- **HPA действительно масштабировал** hello-v1 выше минимума.

Метрики k6 отправляются в Prometheus (remote write) и видны на дашборде «Hello service» в разделе «Нагрузочный тест k6» вместе с репликами и загрузкой CPU. Параметры: `LOAD_RATE`, `LOAD_RAMP`, `LOAD_HOLD`.

Тест помог настроить параметры по данным, а не наугад:
- при 150 запросах/с nginx на статике потребляет около 12m CPU на под, в покое — около 3m. Запрос CPU контейнера nginx снижен с 20m до **10m**, чтобы requests отражали реальное потребление и HPA (цель 70%) реагировал на рабочую нагрузку;
- rate limit 50 запросов/с на реплику Envoy оказался ниже рабочей нагрузки — поднят до **100** (200 на кластер при 2 репликах).

Вывод на трёхузловом стенде:

```text
[load] load-20261002-222635: до 150 запросов/с на https://hello.demo.test/ (разгон 1m, удержание 4m), метрики k6 → Prometheus
  время v1         v2         CPU v1       статус k6
  0s       2          2          8%           running
  15s      2          2          ?%           running
  31s      2          2          60%          running
  46s      2          2          46%          running
  61s      2          2          76%          running
  76s      2          2          80%          running
  92s      3          2          106%         running
  107s     3          2          96%          running
  122s     3          2          75%          running
  138s     3          2          73%          running
  153s     3          2          71%          running
  168s     3          2          77%          running
  184s     3          2          66%          running
  199s     3          2          66%          running
  214s     3          2          66%          running
  229s     3          2          66%          running
  245s     3          2          68%          running
  260s     3          2          73%          running
  275s     3          2          68%          running
  290s     3          2          71%          running
  306s     3          2          64%          running
  321s     3          2          64%          running
  336s     3          2          55%          SuccessCriteriaMet Complete
  █ THRESHOLDS
    checks
    ✓ 'rate>0.99' rate=100.00%
    http_req_duration{expected_response:true}
    ✓ 'p(95)<300' p(95)=6.69ms
    http_req_failed
    ✓ 'rate<0.01' rate=0.00%
  █ TOTAL RESULTS
    checks_total.......: 42891   129.972364/s
    checks_succeeded...: 100.00% 42891 out of 42891
    checks_failed......: 0.00%   0 out of 42891
    ✓ status 200
    HTTP
    http_req_duration..............: avg=2.77ms min=450.21µs med=1.73ms max=221.05ms p(90)=3.75ms p(95)=6.69ms
    http_req_failed................: 0.00%  0 out of 42891
    http_reqs......................: 42891  129.972364/s
  ✔ пороги k6 выполнены: ошибок < 1%, p95 < 300 мс
  ✔ HPA масштабировал hello-v1, реплики: 2 → 3
```

## Соответствие CIS Kubernetes Benchmark

`make cis` ([`scripts/cis-bench.sh`](scripts/cis-bench.sh)) запускает [kube-bench](https://github.com/aquasecurity/kube-bench) на каждом узле (Job с `nodeName`, только чтение файлов узла) и проверяет кластер по **CIS Kubernetes Benchmark 1.12** — последней версии бенчмарка для kubeadm в kube-bench 0.16 (явной версии для Kubernetes 1.36 пока нет). Отчёты в JSON сохраняются в `.state/cis/`.

Первый прогон на трёхузловом стенде: **96 PASS, 19 FAIL**. После исправлений — **110 PASS, 5 FAIL**, и все 5 — осознанные отклонения:

| Исправлено | Где |
|---|---|
| `--profiling=false` у API server, controller-manager и scheduler (1.2.15, 1.3.2, 1.4.1) | конфигурация kubeadm |
| ротация аудит-лога: `maxage 30`, `maxbackup 10`, `maxsize 100` (1.2.17–1.2.19) | конфигурация kubeadm |
| API server проверяет сертификат kubelet по CA кластера (`--kubelet-certificate-authority`, 1.2.5) — возможно, потому что у kubelet настоящие serving-сертификаты | конфигурация kubeadm |
| `--service-account-extend-token-expiration=false` (1.2.30) | конфигурация kubeadm |
| права `600` на `kubelet.service` и `/var/lib/kubelet/config.yaml` на всех узлах (4.1.1, 4.1.9) | роль [`cis`](ansible/roles/cis) |
| каталог данных etcd принадлежит пользователю `etcd:etcd` (1.1.12), в том числе после восстановления из снапшота | роль `cis`, `etcd-restore.yml` |

| Отклонение | Причина |
|---|---|
| 1.3.7, 1.4.2 — controller-manager и scheduler слушают IP узла, а не `127.0.0.1` | Prometheus собирает их метрики; доступ к `/metrics` закрыт аутентификацией и авторизацией Kubernetes |
| 4.3.1 — метрики kube-proxy на localhost | kube-proxy не установлен: его заменяет Cilium (eBPF), проверять нечего |

Скрипт падает при любом FAIL вне этого списка, поэтому `make cis` в CI работает как защита от регрессий безопасности. WARN — в основном ручные проверки (организационные политики, RBAC), их kube-bench автоматически не оценивает.

Изменение конфигурации kubeadm применяется и к уже работающему кластеру: роль `control_plane` перегенерирует манифесты static pods (`kubeadm init phase control-plane all`) и дожидается готовности API server; повторный запуск — `changed=0`.

```text
узел            PASS  FAIL  WARN  INFO
k8s-cp            74     3    54     0
k8s-w1            18     1     6     0
k8s-w2            18     1     6     0
итого            110     5    66     0

FAIL:
  k8s-cp       1.3.7    [принято] Ensure that the --bind-address argument is set to 127.0.0.1 (Automated)
  k8s-cp       1.4.2    [принято] Ensure that the --bind-address argument is set to 127.0.0.1 (Automated)
  k8s-cp       4.3.1    [принято] Ensure that the kube-proxy metrics service is bound to localhost (Automated)
  k8s-w1       4.3.1    [принято] Ensure that the kube-proxy metrics service is bound to localhost (Automated)
  k8s-w2       4.3.1    [принято] Ensure that the kube-proxy metrics service is bound to localhost (Automated)

Принятые отклонения:
  1.3.7    controller-manager слушает IP узла, а не 127.0.0.1: Prometheus собирает его метрики (доступ через authn/authz)
  1.4.2    scheduler слушает IP узла, а не 127.0.0.1: Prometheus собирает его метрики (доступ через authn/authz)
  4.3.1    kube-proxy не установлен — его заменяет Cilium (eBPF), проверять нечего
```

## Тест отказоустойчивости

`make chaos` ([`scripts/chaos-test.sh`](scripts/chaos-test.sh)) проверяет, что меры надёжности действительно работают: под постоянной нагрузкой (3 потока HTTPS-запросов через Gateway) последовательно устраиваются сбои, и **каждый ответ клиенту** должен быть `200`. Допустимое число ошибок задаётся `CHAOS_MAX_ERRORS` (по умолчанию 0).

| # | Сбой | Что должно сработать | Критерий |
|---|---|---|---|
| 1 | `rollout restart` обеих версий приложения | `maxUnavailable: 0`, readiness probe, `preStop`-пауза | 0 ошибок |
| 2 | Аварийная гибель пода (`delete --grace-period=0 --force`) | повторы Envoy (`connect-failure`, `reset`, 502/503) на другую реплику, ReplicaSet создаёт замену | 0 ошибок |
| 3 | Удаление пода Envoy | вторая реплика Envoy, слив соединений при остановке | 0 ошибок |
| 4 | `kubectl drain` узла с приложением (если узлов больше одного) | PodDisruptionBudget, переезд реплик на другие узлы | 0 ошибок, затем `uncordon` |
| 5 | Остановка Loki на ~1,5 минуты | файловый буфер Fluentd и повторы с экспоненциальной задержкой | все строки лога, записанные во время простоя, доставлены в Loki |

Тест выполняется в CI после `make test` на каждом коммите (на одноузловом runner сценарий drain пропускается).

Тест уже нашёл реальную проблему: при drain узла клиенты получали 5 ошибок из ~1300 запросов. Причина — контроллер Envoy Gateway работал в одной реплике на том же узле; пока он переезжал, прокси не получали обновлённый список эндпоинтов и слали запросы на выселенный под. Исправлено: 2 реплики контроллера с PodDisruptionBudget и распределением по узлам, PDB для подов Envoy, `connectTimeout: 1s` к бэкенду для быстрого перехода к повтору.

Вывод на трёхузловом стенде:

```text
Тест отказоустойчивости: Gateway 192.168.252.4, 3 потока нагрузки на https://hello.demo.test/, допустимо ошибок: 0

1. Плавный перезапуск приложения (rollout restart hello-v1 и hello-v2)
     восстановление за 6 с
     запросов: 494, коды: 200×494
  ✔ rolling update без простоя: 0 ошибок из 494 запросов

2. Аварийная гибель пода приложения (delete --grace-period=0 --force)
     убиваем hello-v1-6fc79465c4-2jks9
     восстановление за 0 с
     запросов: 299, коды: 200×299
  ✔ повторы Envoy скрывают падение пода: 0 ошибок из 299 запросов

3. Потеря пода Envoy (delete pod)
     удаляем envoy-envoy-gateway-system-public-5ea56ca9-58f496fd7d-86vs2
     восстановление за 12 с
     запросов: 784, коды: 200×784
  ✔ второй экземпляр Envoy принимает трафик, слив соединений: 0 ошибок из 784 запросов

4. Вывод узла на обслуживание (kubectl drain)
     drain k8s-w1: PodDisruptionBudget не даёт выселить последнюю реплику
     drain выполнен за 32 с
     запросов: 1498, коды: 200×1498
  ✔ drain k8s-w1 без простоя: 0 ошибок из 1498 запросов
     узел k8s-w1 возвращён в работу (uncordon)

5. Недоступность Loki: логи буферизуются в Fluentd и не теряются
     Loki остановлен, отправляем 20 запросов с X-Request-Id chaos-1790966271-18154-<n>
     Loki снова готов за 61 с
  ✔ все 20/20 строк лога, записанных во время простоя Loki, доставлены

Итог: 5 пройдено, 0 провалено
```

## Дополнительные возможности

**Gateway API:** HTTP→HTTPS, TLS с автоматическим выпуском и продлением (cert-manager, собственный CA), маршрутизация по hostname, пути и заголовку, URL rewrite, несколько backend, canary 90/10 (вес — `canaryWeight` в values), **автоматический canary с анализом метрик и откатом (Flagger)**, rate limit, retries с backoff, таймауты, circuit breaker, пассивные health checks, basic auth для служебных интерфейсов, сквозной `X-Request-Id`.

**Мониторинг и логирование:** RED-метрики через Envoy, метрики по версиям, метрики из логов (LogQL), SLO доступности и задержки с алертами по burn rate бюджета ошибок (методика Google SRE), собственный дашборд Grafana как код, 19 алертов и 24 recording rules, метрики control plane и etcd, сетевая наблюдаемость Hubble, аудит API server в Loki, мониторинг самого конвейера логов, **распределённый трейсинг** OpenTelemetry → Tempo с графом сервисов, span-метриками и связью «лог ↔ трейс» по `trace_id` (все три сигнала наблюдаемости связаны).

**Надёжность:** бэкапы etcd каждые 6 часов с проверкой целостности, ротацией, алертами и автоматически проверяемым восстановлением, 2+ реплики приложения, Envoy и контроллера Envoy Gateway с PodDisruptionBudget, HPA (2–6 реплик по CPU, проверяется нагрузочным тестом `make load`), PodDisruptionBudget, rolling update без простоя (`maxUnavailable: 0`, readiness, `preStop`), распределение реплик по узлам, файловый буфер Fluentd с повторами; всё это проверяется тестом отказоустойчивости `make chaos` под нагрузкой.

**Безопасность:** Pod Security Admission `restricted` для приложения (non-root, read-only FS, без capabilities, seccomp), NetworkPolicy, шифрование Secret в etcd (ключ генерируется на узле), аудит API server, настоящие serving-сертификаты kubelet (без `insecure-skip-verify`), TLS ≥ 1.2, отсутствие секретов в Git (пароли генерируются при развертывании), образы по digest (обязательно для `demo` — политика Kyverno), проверка подписи cosign собственных образов при допуске в кластер (Kyverno), проверка sha256 всех загружаемых бинарников, соответствие CIS Kubernetes Benchmark с проверкой в CI (`make cis`).

**Автоматизация:** одна команда, идемпотентность (подтверждается в CI), зафиксированные версии всех зависимостей, инструменты устанавливаются в каталог проекта без изменения системы, три режима развертывания (одна машина, несколько серверов, Multipass).

## CI/CD

GitHub Actions ([`.github/workflows`](.github/workflows)):

- **ci.yml → lint:** gitleaks (секреты в истории), shellcheck, yamllint, ansible-lint (профиль production), hadolint, `helm lint`, рендеринг всей платформы и валидация 300+ манифестов по схемам Kubernetes 1.36 и CRD (kubeconform), Trivy misconfiguration.
- **ci.yml → e2e:** на чистом runner `ubuntu-24.04` выполняется `make cluster` и `make platform` (настоящий kubeadm-кластер), затем проверка идемпотентности (повторный Ansible — `changed=0`, `helmfile diff` пуст), `make test`, проверка CIS Benchmark (`make cis`), тест отказоустойчивости (`make chaos`), progressive delivery (`make rollout`) и учебное восстановление etcd из снапшота (`make etcd-drill`) с повторным `make test`. При ошибке сохраняется диагностика.
- **image.yml:** сборка образа Fluentd для linux/amd64 и linux/arm64, публикация в GHCR (`ghcr.io/captain-skull/fluentd-k8s-loki`), SBOM и provenance, сканирование Trivy, keyless-подпись cosign. На pull request образ только собирается.

- **Renovate** ([`renovate.json`](renovate.json)): еженедельно проверяет все зафиксированные версии — Helm-чарты, образы (тег и digest вместе), GitHub Actions, гемы Fluentd, коллекции Ansible, а также версии в `versions.env`, `group_vars` и CI — и создаёт pull request с обновлением, который проверяет CI (включая e2e). Kubernetes обновляется только в пределах патч-версий: минорное обновление требует проверки совместимости и `kubeadm upgrade`. Сводка — issue «Dependency Dashboard».

Проверка подписи образа (cosign v3+; подпись хранится в формате OCI referrers):

```bash
cosign verify ghcr.io/captain-skull/fluentd-k8s-loki:1.19.3-1 \
  --certificate-identity-regexp 'https://github.com/Captain-Skull/MTS-EngineerHack/.*' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com
```

## Структура репозитория

```
deploy.sh                   развертывание одной командой (доустанавливает make)
Makefile                    точка входа (make help — список команд)
versions.env                версии CLI-инструментов
renovate.json               правила автоматического обновления зависимостей
scripts/                    install-tools, multipass, platform, smoke-test, chaos-test, rollout-test, load-test (+ k6/), cis-bench, etcd-drill, info
ansible/                    роли common, containerd, kubernetes, control_plane, worker, cis; etcd-restore
helmfile/                   описание платформы, values сторонних чартов, namespaces
charts/hello/               демо-приложение
charts/platform-config/     Gateway API, TLS, политики трафика, мониторы, алерты, SLO, дашборд
charts/etcd-backup/         CronJob снапшотов etcd с проверкой и алертами
charts/policies/            политики допуска Kyverno (подпись образов, digest)
charts/rollout/             podinfo под управлением Flagger: Canary, MetricTemplate, алерт отката
images/fluentd/             Dockerfile и Gemfile образа Fluentd
.github/workflows/          CI/CD
docs/adr/                   архитектурные решения (ADR): что выбрано, альтернативы, последствия
```

## Известные ограничения

- **Снапшоты etcd хранятся на диске control-plane узла.** От ошибок и случайного удаления защищают, от потери самого узла — нет; в production снапшоты дополнительно копируются во внешнее хранилище (S3, restic) или используется Velero.
- **Один control-plane узел.** Нет отказоустойчивости API server и etcd; для production нужны 3 узла control plane и балансировщик перед API.
- **Хранилище local-path.** Тома Prometheus и Loki привязаны к диску конкретного узла и не переживают его потерю; в production — сетевое или объектное хранилище (Ceph, S3).
- **Loki в монолитном режиме**, одна реплика, хранение 72 часа; Prometheus — одна реплика, 7 дней.
- **Собственный CA.** Сертификаты не доверены браузерами; для публичного домена ClusterIssuer заменяется на ACME (Let's Encrypt) без изменения Gateway.
- **Node IPAM вместо выделенного балансировщика.** Gateway доступен по IP узлов; в production — BGP/L2-анонс выделенного адреса (Cilium LB-IPAM).
- **Демо-домен `demo.test`** требует записи в `/etc/hosts` или `curl --resolve`.
- **Rate limit локальный** — предел на каждую реплику Envoy, а не общий на кластер.
- **Привилегированные namespace** `monitoring`, `logging`, `local-path-storage`: node-exporter, Fluentd и local-path требуют доступа к узлу.
- **Kyverno 1.19 официально протестирован на Kubernetes 1.33–1.35**, кластер — 1.36 (выбран по совместимости Cilium и Envoy Gateway). Работа политик на 1.36 подтверждается e2e в CI и smoke-тестами на каждом коммите.
- **Проверка подписи требует доступа к GHCR и Rekor** в момент создания пода: при недоступности интернета поды с собственными образами не создаются (fail-closed — осознанный выбор в пользу безопасности).
- Для установки нужен доступ в интернет (пакеты Ubuntu, pkgs.k8s.io, GitHub, реестры образов и чартов).

## Удаление

```bash
make reset      # kubeadm reset на узлах (пакеты остаются), удаляет локальный kubeconfig
make vms-down   # для стенда Multipass — удалить VM
```
