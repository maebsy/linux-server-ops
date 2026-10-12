#!/usr/bin/env bash
# SSH 포트를 20022 로 바꾸고 root 원격 로그인을 막는다.
#
# 순서 (원격 접속 중에 실행해도 잠기지 않도록)
#   1. 방화벽이 켜져 있다면 20022/tcp 가 열려 있는지 먼저 확인 (안 열려 있으면 중단)
#   2. sshd_config.d/00-agent-hardening.conf 설치, 본문의 다른 Port 줄 주석 처리 (백업 남김)
#   3. sshd -t 로 문법 검사 → 실패하면 원래대로 되돌리고 중단
#   4. 재시작: Ubuntu 22.10 이후의 소켓 활성화(ssh.socket)와 기존 서비스 방식 모두 지원
#   5. 확인: sshd -T 실제 적용 값, ss 로 20022 LISTEN
#
# ⚠ 원격으로 접속 중이라면 현재 세션을 닫지 말고, 새 터미널에서 ssh -p 20022 로 접속되는지 확인한 뒤 닫는다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root
need_cmd sshd openssh-server

DROPIN_DIR=/etc/ssh/sshd_config.d
MAIN=/etc/ssh/sshd_config
DROPIN="$DROPIN_DIR/00-agent-hardening.conf"

# 1) 잠김 방지: UFW 가 켜져 있는데 새 포트가 안 열려 있으면 진행하지 않는다
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ! ufw status | grep -Eq "^$SSH_PORT/tcp +ALLOW"; then
        die "방화벽이 켜져 있지만 $SSH_PORT/tcp 가 허용되지 않았습니다. 먼저 setup/02-firewall.sh 를 실행하세요."
    fi
fi

# 2) 설정 적용
run install -d -m 0755 "$DROPIN_DIR"
if ! grep -Eq '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' "$MAIN"; then
    warn "$MAIN 에 sshd_config.d Include 가 없어 맨 위에 추가합니다"
    backup "$MAIN"
    [[ "$DRY_RUN" == 1 ]] || sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$MAIN"
fi
backup "$MAIN"
# Port 는 여러 번 쓰면 모든 포트에서 listen 하므로, 다른 곳의 Port 지시어는 주석 처리한다
run sed -i -E 's/^([[:space:]]*Port[[:space:]]+)/# disabled by 01-ssh.sh: \1/' "$MAIN"
for f in "$DROPIN_DIR"/*.conf; do
    [[ -e "$f" && "$f" != "$DROPIN" ]] || continue
    if grep -Eq '^[[:space:]]*(Port|PermitRootLogin)[[:space:]]' "$f"; then
        warn "$f 에도 Port/PermitRootLogin 이 있습니다 (00- 파일이 먼저 읽혀 우선 적용됨). 주석 처리합니다."
        backup "$f"
        run sed -i -E 's/^([[:space:]]*(Port|PermitRootLogin)[[:space:]]+)/# disabled by 01-ssh.sh: \1/' "$f"
    fi
done
sed "s/^Port .*/Port $SSH_PORT/" "$REPO_DIR/config/sshd_config.d/00-agent-hardening.conf" > /tmp/00-agent-hardening.conf
run install -o root -g root -m 0644 /tmp/00-agent-hardening.conf "$DROPIN"
rm -f /tmp/00-agent-hardening.conf

# 3) 문법 검사 (실패 시 되돌림)
if [[ "$DRY_RUN" != 1 ]]; then
    mkdir -p /run/sshd
    if ! sshd -t; then
        rm -f "$DROPIN"
        latest="$(ls -t "$MAIN".bak.* 2>/dev/null | head -n 1)"
        [[ -n "$latest" ]] && cp -a "$latest" "$MAIN"
        die "sshd -t 문법 검사 실패: 변경을 되돌렸습니다"
    fi
    ok "sshd -t 문법 검사 통과"
fi

# 4) 재시작
if systemctl list-unit-files ssh.socket >/dev/null 2>&1 && systemctl is-enabled ssh.socket >/dev/null 2>&1; then
    # Ubuntu 22.10+ : 포트를 ssh.socket 이 연다. daemon-reload 시 sshd_config 의 Port 로 소켓 설정이 다시 만들어진다
    run systemctl daemon-reload
    run systemctl restart ssh.socket
    run systemctl restart ssh.service || true
elif systemctl list-unit-files ssh.service >/dev/null 2>&1; then
    run systemctl restart ssh          # Ubuntu 22.04
else
    run systemctl restart sshd         # RHEL 계열
fi

# 5) 확인
echo
info "확인"
if [[ "$DRY_RUN" != 1 ]]; then
    sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin) '
    ss -tlnp | grep -E "sshd|:$SSH_PORT\b" || warn "아직 $SSH_PORT 포트가 보이지 않습니다: systemctl status ssh 확인"
fi
warn "새 터미널에서 'ssh -p $SSH_PORT <계정>@<서버>' 접속을 확인한 뒤 기존 세션을 닫으세요."
