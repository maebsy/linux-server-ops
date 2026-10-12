#!/usr/bin/env bash
# (RHEL/Rocky 등) firewalld 로 20022/tcp, 15034/tcp 만 허용한다. UFW 를 쓴다면 02-firewall.sh 사용.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root
need_cmd firewall-cmd firewalld

run systemctl enable --now firewalld
ZONE="$(firewall-cmd --get-default-zone)"
# 기본 zone 에 열려 있던 서비스(ssh, dhcpv6-client, cockpit 등)를 모두 닫고 포트만 연다
for svc in $(firewall-cmd --permanent --zone="$ZONE" --list-services); do
    run firewall-cmd --permanent --zone="$ZONE" --remove-service="$svc"
done
for port in $(firewall-cmd --permanent --zone="$ZONE" --list-ports); do
    run firewall-cmd --permanent --zone="$ZONE" --remove-port="$port"
done
run firewall-cmd --permanent --zone="$ZONE" --add-port="$SSH_PORT/tcp"
run firewall-cmd --permanent --zone="$ZONE" --add-port="$AGENT_PORT/tcp"
run firewall-cmd --reload
# SELinux 가 켜져 있으면 sshd 가 20022 를 쓰도록 포트 라벨도 추가해야 한다
if command -v semanage >/dev/null 2>&1 && [[ "$(getenforce 2>/dev/null)" == Enforcing ]]; then
    run semanage port -a -t ssh_port_t -p tcp "$SSH_PORT" || run semanage port -m -t ssh_port_t -p tcp "$SSH_PORT"
fi
echo
info "확인"
[[ "$DRY_RUN" == 1 ]] || firewall-cmd --list-all
