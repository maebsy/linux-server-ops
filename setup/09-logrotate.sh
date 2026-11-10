#!/usr/bin/env bash
# =============================================================================
#  09-logrotate.sh — monitor.log 용량 관리를 logrotate 로 전환 / 되돌리기 (선택)
#
#    sudo bash setup/09-logrotate.sh            # 전환: config/logrotate.d/agent-app 설치
#    sudo bash setup/09-logrotate.sh --disable  # 되돌리기: 설정 제거 → monitor.sh 내장 순환으로
#
#  두 방식은 동시에 쓰지 않는다. monitor.sh 는 /etc/logrotate.d/agent-app 이 있으면(LOG_ROTATION=auto)
#  내장 순환을 건너뛰므로, 이 스크립트가 설정 파일을 넣고 빼는 것만으로 한쪽만 동작한다.
#
#  순서 (전환)
#    1. logrotate 가 없으면 설치
#    2. 설정 설치 — install -m 0644 -o root (cp 로 복사해 0664 가 되면 logrotate 가 조용히 무시한다)
#    3. logrotate -d 로 문법·대상 파일 미리 보기 (실패하면 설정을 지우고 중단 → 내장 순환 유지)
#    4. 현재 어떤 방식이 동작하는지 출력
#
#  이 단계는 선택 사항이라 run-all.sh 에는 넣지 않는다. (DRY_RUN=1 로 명령만 미리 볼 수 있다)
#  logrotate 는 기본 하루 1회(logrotate.timer) 돈다. 10MB 를 빨리 넘는 서버면 docs/operations.md §4 의
#  'OnCalendar=hourly' 설정으로 더 자주 돌린다.
# =============================================================================
set -uo pipefail
export LC_ALL=C
source "$(dirname "$0")/lib.sh"

MODE=enable
case "${1:-}" in
    "") ;;
    --disable) MODE=disable ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^#  \{0,1\}//'; exit 0 ;;
    *) die "알 수 없는 옵션: $1 (--disable 또는 --help)" ;;
esac

require_root
CONF_SRC="$REPO_DIR/config/logrotate.d/agent-app"
CONF_DST="${LOGROTATE_CONF:-/etc/logrotate.d/agent-app}"

show_mode() {
    if [[ -f "$CONF_DST" ]]; then
        info "현재 순환 방식: logrotate ($CONF_DST 있음 → monitor.sh 내장 순환은 건너뜀)"
        stat -c '  %U:%G %a %n' "$CONF_DST"
    else
        info "현재 순환 방식: monitor.sh 내장 순환 (10MB × 10개, $CONF_DST 없음)"
    fi
}

# 백업(.bak.*)을 /etc/logrotate.d 에 남기지 않는다: logrotate 는 그 폴더의 파일을 모두 읽어서
# 같은 monitor.log 항목이 두 번 생기면 'duplicate log entry' 오류가 난다. 원본은 저장소의 config/ 에 있다.
if [[ "$MODE" == disable ]]; then
    run rm -f "$CONF_DST"
    echo
    [[ "$DRY_RUN" == 1 ]] || show_mode
    exit 0
fi

need_cmd logrotate logrotate

# 2) 설치
run install -o root -g root -m 0644 "$CONF_SRC" "$CONF_DST"

# 3) 미리 보기: 실패하면 설정을 지워 내장 순환이 계속 돌게 둔다 (둘 다 꺼진 상태를 만들지 않음)
if [[ "$DRY_RUN" != 1 ]]; then
    if ! out="$(logrotate -d "$CONF_DST" 2>&1)" || grep -qiE '^error' <<< "$out"; then
        printf '%s\n' "$out" | tail -n 8
        rm -f "$CONF_DST"
        die "logrotate -d 검사 실패 — 설정을 되돌렸습니다 (내장 순환 유지)"
    fi
    printf '%s\n' "$out" | grep -E 'rotating pattern|considering log|log does not need|log needs' | head -n 4
    ok "logrotate -d 검사 통과"
fi

echo
info "확인"
[[ "$DRY_RUN" == 1 ]] || show_mode
info "강제 순환 시험: sudo logrotate -f $CONF_DST   (monitor.log → monitor.log.1)"
info "되돌리기: sudo bash setup/09-logrotate.sh --disable"
