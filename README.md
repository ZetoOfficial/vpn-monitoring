# vpn-monitoring

Ansible + Docker Compose стек для мониторинга личного WireGuard-сервера. Поднимает Prometheus и Grafana на одном VPS, экспортеры на другом, разворачивается локально через `make`.

## Зачем это

VPN на `wg-easy` периодически тупит — то медленно открываются сайты, то совсем перестаёт работать. Чтобы найти причину, нужны метрики и графики.

Проект решает это:

- На отдельном хосте `vdsina.com` крутятся Prometheus + Grafana.
- На VPN-хосте `vdsina.2gb.com` — `node_exporter`, `cadvisor`, `wireguard_exporter`, `blackbox_exporter`. Они скрейпятся прометеем по публичному IP, доступ ограничен UFW по source-IP.
- В Grafana предзалиты три community-дашборда (Node Exporter Full, cAdvisor, WireGuard).
- Доступ к Grafana — через отдельный admin-WireGuard-туннель (`wg-admin`), не через общий VPN. Если общий VPN лёг — мониторинг всё равно открывается.
- Базовые алерты (CPU >90%, диск >85%, blackbox-фейлы, рестарт-петли контейнеров) считаются прометеем; смотреть на них руками, без Alertmanager.

## Что внутри

```
ansible/        Ansible playbooks и роли (common, docker, firewall, admin_wireguard, monitoring_stack, vpn_exporters)
monitoring/     Статические артефакты: alerts.yml, blackbox.yml, Grafana provisioning + JSON дашборды
scripts/        Хелпер-скрипт для генерации wg-admin ключей и client.conf
docs/runbook.md Полный runbook: prerequisites, deploy, доступ, rollback, известные ограничения
Makefile        Обёртки над ansible: setup / ping / check / deploy-monitoring / deploy-exporters / status
```

Подробности и обоснования архитектуры — в `docs/superpowers/specs/2026-05-08-vpn-monitoring-design.md`.

## Как использовать

### Один раз на локальной машине

```bash
brew install ansible wireguard-tools
make setup                                      # ставит community.general collection
cp ansible/inventory.example.yml ansible/inventory.yml
$EDITOR ansible/inventory.yml                   # IP-шники, пароль Grafana, порты wg-easy и т.д.
make wg-admin-init                              # сгенерит admin-WG ключи и client.conf
ssh-keyscan -H <host1-ip> <host2-ip> >> ~/.ssh/known_hosts
```

### Деплой

```bash
make ping                                       # проверка SSH/Ansible
cd ansible && ansible-playbook -i inventory.yml playbooks/site.yml --check --diff   # dry-run
make deploy-monitoring                          # сначала только мониторинг-хост
make deploy-exporters                           # потом VPN-хост
```

Импортируй `.secrets/wg-admin/client.conf` в WireGuard-клиент, активируй туннель, открой `http://10.88.0.1:3000`.

### Проверка

В Grafana → Explore → Prometheus → запрос `up` — все 8 таргетов должны вернуть `1`. Алерты — `http://127.0.0.1:9090/alerts` через SSH-туннель `ssh -L 9090:127.0.0.1:9090 root@<monitoring host>`.

### Откат

```bash
ssh root@<host> 'cd /opt/monitoring && docker compose down'   # на мониторинг-хосте
ssh root@<host> 'cd /opt/vpn-exporters && docker compose down' # на VPN-хосте
```

UFW-правила снимаются вручную через `ufw status numbered` + `ufw delete <num>`. Полный rollback — restore из снапшота VPS.

## Известные ограничения

- WireGuard-дашборд пустой если wg-easy <v15: используемый mindflavor-экспортер не видит wg-интерфейс внутри контейнера. Решается апгрейдом wg-easy на v15+ и переключением Prometheus на нативный `/metrics/prometheus` endpoint. См. `docs/runbook.md` → Known limitation.
- Алерты не маршрутизируются — только видны в Prometheus UI и через панель Alert List в Grafana. Telegram через Alertmanager — Phase 2.
