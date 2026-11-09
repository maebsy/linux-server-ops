#!/usr/bin/env bash
# =============================================================================
#  08-fail2ban.sh — SSH(20022) 무차별 대입 자동 차단 (fail2ban) 선택 설치
#
#  순서
#    1. fail2ban-client 가 없으면 fail2ban 패키지 설치
#    2. config/fail2ban/jail.d/agent-sshd.local 을 백업 후 설치 (권한 0644)
#       → fail2ban-client -t 로 설정 검사, 실패하면 재시작하지 않고 중단
#    3. systemctl enable + restart fail2ban
#    4. 데몬이 jail 을 올릴 때까지 최대 10초 대기 후 'fail2ban-client status sshd' 확인
#    5. 차단 목록 확인·수동 해제 방법 안내
#
#  banaction=ufw 이므로 차단 결과가 `ufw status` 에 함께 보인다 (02-firewall.sh 와 한 곳에서 관리).
#  이 단계는 선택 사항이라 run-all.sh 에는 넣지 않는다. 필요할 때 직접 실행한다:
#    sudo bash setup/08-fail2ban.sh
#  (DRY_RUN=1 bash setup/08-fail2ban.sh 로 실행할 명령만 미리 볼 수 있다)
# =============================================================================
set -uo pipefail
export LC_ALL=C
source "$(dirname "$0")/lib.sh"
require_root
need_cmd fail2ban-client fail2ban

JAIL_SRC="$REPO_DIR/config/fail2ban/jail.d/agent-sshd.local"
JAIL_DST="/etc/fail2ban/jail.d/agent-sshd.local"

# 2) jail 설치 (기존 파일이 있으면 백업)
backup "$JAIL_DST"
run install -o root -g root -m 0644 "$JAIL_SRC" "$JAIL_DST"

# 설정 검사: 실패하면 재시작하지 않는다 (잘못된 설정으로 데몬이 죽으면 기존 차단까지 모두 풀린다)
if [[ "$DRY_RUN" != 1 ]] && ! fail2ban-client -t >/dev/null 2>&1; then
    fail2ban-client -t 2>&1 | tail -n 5
    die "fail2ban 설정 검사 실패 — $JAIL_DST 확인 (값 뒤에 '# 주석' 을 붙이면 주석까지 값으로 읽힌다)"
fi

# 3) 서비스 활성화·재시작
run systemctl enable fail2ban
run systemctl restart fail2ban

# 4) 데몬이 sshd jail 을 올릴 때까지 최대 10초 대기
echo
info "확인"
if [[ "$DRY_RUN" != 1 ]]; then
    i=0
    while (( i < 10 )); do
        if fail2ban-client status sshd >/dev/null 2>&1; then
            break
        fi
        sleep 1
        i=$((i + 1))
    done
    if fail2ban-client status sshd; then
        ok "fail2ban sshd jail 이 활성화되었습니다"
    else
        die "sshd jail 이 올라오지 않았습니다: systemctl status fail2ban; journalctl -u fail2ban -n 20"
    fi
fi

# 5) 확인·해제 방법 안내
echo
info "차단 목록 확인:  sudo fail2ban-client status sshd"
info "방화벽에서도 확인:  sudo ufw status"
info "오탐 수동 해제:  sudo fail2ban-client set sshd unbanip <IP>"
