# 0004. Envoy Gateway как реализация Gateway API

Статус: принято.

## Контекст

Приложение нужно опубликовать через Gateway API. Кроме этого хотелось TLS, маршрутизацию по hostname, пути и заголовкам, взвешенный canary, rate limit, повторы и нормальные метрики.

## Решение

Envoy Gateway 1.9.2 (Gateway API v1.6.1). Из стандартных ресурсов используются `Gateway`, `HTTPRoute` и `ReferenceGrant`. Из расширений: `ClientTrafficPolicy`, `BackendTrafficPolicy` (rate limit, повторы, circuit breaker, health checks, таймауты), `SecurityPolicy` (basic auth для служебных интерфейсов) и `EnvoyProxy` (реплики, PDB, телеметрия, трейсинг).

## Альтернативы

- Ingress-NGINX работает с Ingress, а не с Gateway API, и проект сейчас только поддерживается.
- NGINX Gateway Fabric реализует Gateway API, но политик трафика из коробки у него меньше.
- Cilium Gateway API не требует отдельного компонента, но настраиваемых политик меньше (rate limit, retries, basic auth), и шлюз оказывается привязан к CNI.
- Istio даёт полноценный service mesh, для этой задачи это слишком много, и по ресурсам он тяжёлый.

## Последствия

- Всё поведение трафика описано ресурсами Kubernetes в [`charts/platform-config`](../../charts/platform-config).
- Envoy отдаёт подробные метрики, JSON access-логи с `X-Request-Id` и трейсы OpenTelemetry, и приложение для этого менять не пришлось.
- Контроллер Envoy Gateway играет роль control plane шлюза. Тест отказоустойчивости показал, что в одной реплике он становится единой точкой отказа при drain узла, поэтому теперь у него 2 реплики с PDB ([0011](0011-chaos-testing.md)).
