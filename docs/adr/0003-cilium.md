# 0003. Cilium без kube-proxy и Node IPAM вместо MetalLB

**Статус:** принято

## Контекст

Нужна сеть подов, NetworkPolicy и способ доставить внешний трафик к Gateway на «голом железе» без облачного балансировщика.

## Решение

**Cilium** в режиме полной замены kube-proxy: Service реализуются eBPF-программами вместо iptables. Внешний адрес для Service типа LoadBalancer выдаёт **Cilium Node IPAM**: адресами сервиса Envoy становятся IP узлов. Сетевая наблюдаемость — **Hubble** (UI и метрики).

## Альтернативы

- **Flannel** — нет NetworkPolicy.
- **Calico** — зрелый вариант с NetworkPolicy, но без встроенной наблюдаемости уровня Hubble и с отдельным решением для LoadBalancer.
- **MetalLB / Cilium LB-IPAM с L2/BGP** — выделенный плавающий адрес. Требует свободного диапазона в сети и отличается на одной машине, в Multipass и на GitHub runner. Node IPAM работает одинаково во всех трёх средах.

## Последствия

- Один компонент закрывает CNI, Service, NetworkPolicy, LoadBalancer и сетевую наблюдаемость.
- Gateway доступен по IP любого узла (адресов несколько), но при потере узла клиент должен сам переключиться на другой адрес. В production — Cilium LB-IPAM с BGP/L2-анонсом выделенного адреса.
- После восстановления etcd Cilium нужно перезапускать: его eBPF-таблицы хранят состояние сервисов (учтено в `ansible/etcd-restore.yml`).
