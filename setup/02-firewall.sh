#!/usr/bin/env bash
# UFW 로 인바운드는 20022/tcp(SSH), 15034/tcp(APP) 만 허용한다. (firewalld 는 02-firewall-firewalld.sh)
#
#   기본 정책: 인바운드 deny, 아웃바운드 allow → 허용 목록(allowlist)에 있는 포트만 열린다
#   기존 규칙은 reset 으로 지운다. "필요한 포트만" 이라는 요구사항을 확실히 만족시키기 위해서다.
#
# ⚠ 원격 접속 중이면: 지금 접속한 포트가 22 이고 sshd 가 아직 20022 를 열지 않았다면
#   방화벽을 켜는 순간 22 가 막혀 끊긴다. 이 경우 --keep-22 로 실행해 22 를 임시로 열어 두고,
#   01-ssh.sh 로 포트를 바꾼 뒤 'sudo bash setup/02-firewall.sh' 를 한 번 더 실행해 22 를 닫는다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root
need_cmd ufw

KEEP22=0
[[ "${1:-}" == "--keep-22" ]] && KEEP22=1

current_port="$(awk '{print $4}' <<< "${SSH_CONNECTION:-}")"
if [[ "$current_port" == 22 && $KEEP22 -eq 0 ]] && ! ss -tln | grep -q ":$SSH_PORT\b"; then
    die "SSH 포트 22 로 접속 중인데 sshd 가 아직 $SSH_PORT 를 열지 않았습니다. --keep-22 로 실행하세요 (위 주석 참고)."
fi

run ufw --force reset
run ufw default deny incoming
run ufw default allow outgoing
run ufw allow "$SSH_PORT/tcp" comment 'SSH (sshd Port)'
run ufw allow "$AGENT_PORT/tcp" comment 'agent-app'
if [[ $KEEP22 -eq 1 ]]; then
    run ufw allow 22/tcp comment 'TEMPORARY - remove after SSH port change'
    warn "22/tcp 를 임시로 열었습니다. 01-ssh.sh 후 이 스크립트를 옵션 없이 다시 실행해 닫으세요."
fi
run ufw --force enable
run systemctl enable ufw

echo
info "확인"
[[ "$DRY_RUN" == 1 ]] || ufw status verbose
# reset 하면 /etc/ufw 에 *.rules.<날짜> 백업이 남는다 (되돌릴 때 사용)
