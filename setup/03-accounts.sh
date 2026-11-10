#!/usr/bin/env bash
# 계정 3개와 그룹 2개를 만든다 (이미 있으면 그대로 두고 소속만 맞춘다 → 여러 번 실행해도 안전)
#
#   그룹 agent-common : agent-admin, agent-dev, agent-test   → 공유 디렉토리(upload_files)
#   그룹 agent-core   : agent-admin, agent-dev               → 보안 디렉토리(api_keys, 로그)
#
#   agent-admin : 운영/관리, 앱 실행·cron 실행자
#   agent-dev   : 개발/운영, monitor.sh 작성자(소유자)
#   agent-test  : QA/테스트 → 공유 디렉토리만 접근
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root

for group in agent-common agent-core; do
    if getent group "$group" >/dev/null; then ok "그룹 존재: $group"
    else run groupadd "$group"; ok "그룹 생성: $group"; fi
done

declare -A GROUPS_OF=(
    [agent-admin]="agent-common,agent-core"
    [agent-dev]="agent-common,agent-core"
    [agent-test]="agent-common"
)
for user in agent-admin agent-dev agent-test; do
    if id "$user" >/dev/null 2>&1; then ok "계정 존재: $user"
    else run useradd --create-home --shell /bin/bash "$user"; ok "계정 생성: $user"; fi
    # -aG: 기존 보조 그룹(sudo 등)은 지우지 않고 필요한 그룹만 추가
    run usermod -aG "${GROUPS_OF[$user]}" "$user"
done
# 최소 권한: agent-test 는 보안 그룹(agent-core)에 있으면 안 된다 (예전에 잘못 넣은 경우 제거)
if [[ "$DRY_RUN" != 1 ]] && id -nG agent-test | tr ' ' '\n' | grep -qx agent-core; then
    run gpasswd -d agent-test agent-core
fi

echo
info "확인"
for user in agent-admin agent-dev agent-test; do
    [[ "$DRY_RUN" == 1 ]] || id "$user"
done

# 계정별 권한 요약 — 그룹 소속에서 나오는 접근 권한을 표로 남겨 설치 로그만 보고도 검증할 수 있게 한다
#   agent-common → upload_files 읽기·쓰기 / agent-core → api_keys·/var/log/agent-app 읽기·쓰기, monitor.sh 실행
if [[ "$DRY_RUN" != 1 ]]; then
    echo
    info "계정별 권한 요약 (O 허용 / X 불가, password: L 잠김 · P 설정됨 · NP 없음)"
    printf '  %-12s %-5s %-12s %-10s %-14s %-11s %s\n' user uid agent-common agent-core api_keys·log monitor.sh password
    for user in agent-admin agent-dev agent-test; do
        g=" $(id -nG "$user") "
        common=X; core=X
        [[ "$g" == *" agent-common "* ]] && common=O
        [[ "$g" == *" agent-core "* ]] && core=O
        pw="$(passwd -S "$user" 2>/dev/null | awk '{print $2}')"
        printf '  %-12s %-5s %-12s %-10s %-14s %-11s %s\n' "$user" "$(id -u "$user")" "$common" "$core" "$core" "$core" "${pw:-?}"
    done
fi
warn "비밀번호는 설정하지 않았습니다(잠긴 계정). 필요하면 'sudo passwd <계정>', 전환은 'sudo -iu agent-admin'"
