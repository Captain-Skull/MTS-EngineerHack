# 0004. Envoy Gateway как реализация Gateway API

**Статус:** принято

## Контекст

Кейс требует публиковать приложение через Gateway API. Нужны TLS, маршрутизация по hostname, пути и заголовкам, взвешенный canary, а также rate limit, повторы и метрики.

## Решение

**Envoy Gateway 1.9.2** (Gateway API v1.6.1). Стандартные ресурсы — `Gateway`, `HTTPRoute`, `ReferenceGrant`; расширения — `ClientTrafficPolicy`, `BackendTrafficPolicy` (rate limit, повторы, circuit breaker, health checks, таймауты), `SecurityPolicy` (basic auth для служебных интерфейсов), `EnvoyProxy` (реплики, PDB, телеметрия, трейсинг).

## Альтернативы

- **Ingress-NGINX** — это Ingress, а не Gateway API; проект в режиме сопровождения.
- **NGINX Gateway Fabric** — реализует Gateway API, но меньше политик трафика из коробки.
- **Cilium Gateway API** — не нужен отдельный компонент, но меньше настраиваемых политик (rate limit, retries, basic auth) и связь шлюза с CNI.
- **Istio** — полноценная service mesh, избыточная для задачи и тяжёлая по ресурсам.

## Последствия

- Все возможности трафика описаны декларативно ресурсами Kubernetes в [`charts/platform-config`](../../charts/platform-config).
- Envoy даёт детальные метрики, JSON access-логи с `X-Request-Id` и трейсы OpenTelemetry без изменения приложения.
- Контроллер Envoy Gateway — control plane шлюза. Тест отказоустойчивости показал, что одна его реплика — единая точка отказа при drain узла. Поэтому у контроллера 2 реплики с PDB ([0011](0011-chaos-testing.md)).
