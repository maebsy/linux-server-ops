#!/usr/bin/env bash
# =============================================================================
#  alert.sh — agent-app 경고·장애 알림 훅
#
#  설치 위치 : $AGENT_HOME/bin/alert.sh   (소유 agent-dev : 그룹 agent-core, 권한 750)
#  호출 방법 : monitor.sh 가 "alert.sh LEVEL MESSAGE" 형태로 실행한다.
#              LEVEL = WARNING | CRITICAL,  MESSAGE = 사람이 읽는 한 줄 설명
#
#  활성화 방법
#    /etc/agent-app/agent-app.env 에 아래 한 줄을 추가하면 monitor.sh 가 자동으로 부른다.
#        ALERT_CMD=/home/agent-admin/agent-app/bin/alert.sh
#    (ALERT_CMD 가 실행 가능한 파일일 때만 동작하며, monitor.sh 의 종료 코드·로그는 바뀌지 않는다.)
#
#  동작
#    1. 쿨다운: 같은 종류의 경고가 짧은 간격으로 반복되면 한 번만 보낸다.
#       - 중복 판정 키 = LEVEL + MESSAGE 에서 숫자와 '.' 을 모두 제거한 문자열의 해시.
#         (예: "CPU threshold exceeded (32.3% > 20%)" 와 "(40.1% > 20%)" 는 같은 키)
#       - 키별 상태 파일의 수정 시각(mtime)이 마지막 전송 시각. ALERT_COOLDOWN_SEC 이내면 조용히 종료.
#    2. 전송 경로(설정된 것만, 실패는 무시):
#       - logger  : ALERT_LOGGER=1 이고 logger 가 있으면 syslog 에 남긴다 (CRITICAL=crit, 그 외 warning)
#       - 파일     : ALERT_LOG_FILE 이 있으면 해당 파일에 한 줄 덧붙인다
#       - 웹훅     : ALERT_WEBHOOK_URL 이 있으면 {"text":"..."} JSON 을 POST 한다
#
#  종료 코드 : 0 (항상) / 2 (사용법 오류)
#  모든 값은 환경변수로 바꿀 수 있다 (cron 은 로그인 셸이 아니므로 기본값을 스크립트에 둔다).
# =============================================================================
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# ---------------------------------------------------------------- 설정 (환경변수)
# monitor.sh 는 env 파일을 source 만 하고 export 하지 않으므로, 자식인 이 스크립트에는
# ALERT_WEBHOOK_URL 같은 값이 전달되지 않는다. 그래서 같은 env 파일을 직접 읽는다.
# (실제 서버에서 웹훅이 가지 않던 문제를 증빙 수집 중 발견해 고침 — docs/evidence/25-alert.txt)
AGENT_ENV_FILE="${AGENT_ENV_FILE:-/etc/agent-app/agent-app.env}"
if [[ -r "$AGENT_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$AGENT_ENV_FILE"
fi
ALERT_COOLDOWN_SEC="${ALERT_COOLDOWN_SEC:-600}"                          # 같은 키 재전송 최소 간격(초)
ALERT_STATE_DIR="${ALERT_STATE_DIR:-${AGENT_LOG_DIR:-/var/log/agent-app}/.alert-state}"
ALERT_LOGGER="${ALERT_LOGGER:-1}"                                        # 1: syslog(logger) 로 전송
ALERT_LOG_FILE="${ALERT_LOG_FILE:-}"                                     # 지정 시 이 파일에 한 줄 덧붙임
ALERT_WEBHOOK_URL="${ALERT_WEBHOOK_URL:-}"                               # 지정 시 JSON POST

usage() {
    cat <<EOF
사용법: $SCRIPT_NAME LEVEL MESSAGE

monitor.sh 의 경고·장애 알림 훅. LEVEL(WARNING|CRITICAL)과 MESSAGE 를 받아
쿨다운(중복 억제) 후 syslog·파일·웹훅으로 알린다.

환경변수 (기본값)
  ALERT_COOLDOWN_SEC=$ALERT_COOLDOWN_SEC   같은 종류 경고 재전송 최소 간격(초)
  ALERT_STATE_DIR=$ALERT_STATE_DIR
  ALERT_LOGGER=$ALERT_LOGGER               1 이면 logger 로 syslog 전송
  ALERT_LOG_FILE=${ALERT_LOG_FILE:-(미설정)}  지정 시 해당 파일에 덧붙임
  ALERT_WEBHOOK_URL=${ALERT_WEBHOOK_URL:+(설정됨)}  지정 시 JSON POST

활성화: /etc/agent-app/agent-app.env 에
  ALERT_CMD=/home/agent-admin/agent-app/bin/alert.sh

종료 코드: 0 (항상) / 2 (사용법 오류)
EOF
}

case "${1:-}" in
    -h|--help) usage; exit 0 ;;
esac

if [[ $# -ne 2 ]]; then
    printf '[ERROR] 인자는 LEVEL MESSAGE 두 개여야 합니다 (--help 참고)\n' >&2
    exit 2
fi

LEVEL="$1"
MESSAGE="$2"

# ---------------------------------------------------------------- 중복 판정 키
# 숫자와 '.' 을 지워 "값만 다른 같은 종류" 의 경고가 하나의 키로 묶이게 한다.
key_src="${LEVEL} ${MESSAGE}"
key_src="${key_src//[0-9]/}"
key_src="${key_src//./}"
KEY="$(printf '%s' "$key_src" | cksum | awk '{ print $1 "_" $2 }')"
STATE_FILE="$ALERT_STATE_DIR/$KEY"

mkdir -p "$ALERT_STATE_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- 쿨다운 확인
# 상태 파일 mtime(마지막 전송 시각)과 지금의 차이가 쿨다운보다 작으면 조용히 종료.
if [[ -f "$STATE_FILE" ]]; then
    last="$(stat -c %Y "$STATE_FILE" 2>/dev/null || echo 0)"
    now="$(date +%s)"
    age=$(( now - last ))
    if (( age < ALERT_COOLDOWN_SEC )); then
        exit 0
    fi
fi

# ---------------------------------------------------------------- 알림 한 줄 구성
line="[$(date '+%Y-%m-%d %H:%M:%S')] [$LEVEL] host=$(hostname) $MESSAGE"

# 1) syslog
if [[ "$ALERT_LOGGER" == 1 ]] && command -v logger >/dev/null 2>&1; then
    if [[ "$LEVEL" == CRITICAL ]]; then prio=user.crit; else prio=user.warning; fi
    logger -t agent-monitor -p "$prio" -- "$line" 2>/dev/null || true
fi

# 2) 파일
if [[ -n "$ALERT_LOG_FILE" ]]; then
    printf '%s\n' "$line" >> "$ALERT_LOG_FILE" 2>/dev/null || true
fi

# 3) 웹훅 (JSON 문자열에 들어갈 \ 와 " 를 이스케이프)
if [[ -n "$ALERT_WEBHOOK_URL" ]] && command -v curl >/dev/null 2>&1; then
    esc="${line//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    curl -fsS -m 5 -H 'Content-Type: application/json' \
        -d "{\"text\":\"$esc\"}" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 || true
fi

# ---------------------------------------------------------------- 상태 갱신
# 전송 시각을 mtime 에 남긴다 (다음 쿨다운 판정 기준).
: > "$STATE_FILE" 2>/dev/null || true

exit 0
