# Архитектурные решения (ADR)

Architecture Decision Records — короткие записи о значимых решениях: какая была ситуация, что выбрали, какие варианты отвергли и чем за это платим. Формат — [Michael Nygard](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

| № | Решение | Статус |
|---|---|---|
| [0001](0001-kubeadm.md) | Кластер создаётся kubeadm, узлы настраивает Ansible | принято |
| [0002](0002-kubernetes-1-36.md) | Kubernetes 1.36, а не последняя 1.37 | принято |
| [0003](0003-cilium.md) | Cilium без kube-proxy и Node IPAM вместо MetalLB | принято |
| [0004](0004-envoy-gateway.md) | Envoy Gateway как реализация Gateway API | принято |
| [0005](0005-fluentd-loki.md) | Fluentd с собственным образом и Loki вместо Elasticsearch | принято |
| [0006](0006-helmfile.md) | Helmfile + Make для платформы, без GitOps-контроллера | принято, дополнено 0014 |
| [0007](0007-own-ca.md) | Собственный CA в cert-manager вместо ACME | принято |
| [0008](0008-tracing.md) | Трейсинг OpenTelemetry → Tempo | принято |
| [0009](0009-kyverno-fail-closed.md) | Kyverno, проверка подписи в режиме fail-closed | принято |
| [0010](0010-single-control-plane.md) | Один control-plane узел и проверяемые бэкапы etcd | принято, с ограничениями |
| [0011](0011-chaos-testing.md) | Отказоустойчивость проверяется тестом под нагрузкой в CI | принято |
| [0012](0012-cis-exceptions.md) | CIS Benchmark как защита от регрессий, с явными отклонениями | принято |
| [0013](0013-flagger.md) | Progressive delivery: Flagger с провайдером Gateway API | принято |
| [0014](0014-gitops-argocd.md) | GitOps для приложений: Argo CD поверх платформы из helmfile | принято |
