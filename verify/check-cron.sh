#!/usr/bin/env bash
# =============================================================================
#  check-cron.sh — cron ↔ syslog ↔ monitor.log 연동이 실제로 도는지 점검
#
#    sudo bash verify/check-cron.sh [--user NAME] [--max-age MIN] [-h|--help]
#
#  "crontab 에 등록됐다" 만으로는 관제가 도는 줄 알 수 없다. 이 스크립트는 한 체인을 끝까지 따라간다:
#    crontab 등록 → cron 서비스 실행 → 실행 계정 권한 → syslog 의 CRON 실행 기록
#      → monitor.log 갱신 → cron.log 오류 → cron 과 같은 최소 환경(env -i)에서 env 파일 로드
#  각 단계는 [OK|WARN|FAIL|SKIP] 과 필요하면 '→ 복구:' 명령을 함께 보여 준다.
#
#  monitor.sh 와 같은 방식으로 AGENT_ENV_FILE 을 먼저 읽어 cron 과 같은 값으로 점검한다.
#  모든 경로·사용자·임계값은 환경변수로 바꿀 수 있어 테스트에서 임시 폴더를 가리킬 수 있다.
#  주기 점검: root crontab 에 한 줄 (실패하면 syslog 에 남김, 운영 매뉴얼 §5)
#    17 * * * * bash /srv/linux-server-ops/verify/check-cron.sh >/dev/null 2>&1 || logger -t agent-monitor "check-cron FAIL"
#
#  종료 코드: 0 정상 / 1 FAIL 항목 있음 / 2 잘못된 사용법
# =============================================================================
set -uo pipefail
export LC_ALL=C           # 날짜·월 이름을 로케일과 무관하게 고정 (date -d 로 syslog 시각 파싱)

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# ---------------------------------------------------------------- 설정 (환경변수)
AGENT_ENV_FILE="${AGENT_ENV_FILE:-/etc/agent-app/agent-app.env}"
if [[ -r "$AGENT_ENV_FILE" ]] && bash -n "$AGENT_ENV_FILE" 2>/dev/null; then   # 문법 오류 파일은 7단계에서 보고
    # shellcheck disable=SC1090
    source "$AGENT_ENV_FILE"
fi

CRON_USER="${CRON_USER:-agent-admin}"
CRONTAB_FILE="${CRONTAB_FILE:-}"                       # 설정 시 crontab -u 대신 이 파일을 읽는다 (테스트용)
ROOT_CRONTAB_FILE="${ROOT_CRONTAB_FILE:-}"             # 설정 시 root crontab 대신 이 파일을 읽는다 (테스트용)
SYSTEM_CRON_FILES="${SYSTEM_CRON_FILES:-/etc/crontab /etc/cron.d/*}"   # 사용자 칸이 있는 시스템 cron 파일
AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
MONITOR_SCRIPT="${MONITOR_SCRIPT:-$AGENT_HOME/bin/monitor.sh}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
MONITOR_LOG="${MONITOR_LOG:-$AGENT_LOG_DIR/monitor.log}"
CRON_LOG="${CRON_LOG:-$AGENT_LOG_DIR/cron.log}"
SYSLOG_FILE="${SYSLOG_FILE:-/var/log/syslog}"
MAX_AGE_MIN="${MAX_AGE_MIN:-3}"
SKIP_SERVICE="${SKIP_SERVICE:-0}"                      # 1: cron 서비스 점검 건너뜀 (테스트·컨테이너용)
SKIP_SUDO="${SKIP_SUDO:-0}"                            # 1: sudo -u 권한 점검 건너뜀

usage() {
    cat <<EOF
사용법: sudo bash $SCRIPT_NAME [--user NAME] [--max-age MIN] [-h|--help]

cron 이 monitor.sh 를 매분 실행해 monitor.log 가 갱신되는 체인을 끝까지 점검합니다.

옵션
  --user NAME      점검할 crontab 소유 계정 (기본 $CRON_USER)
  --max-age MIN    'cron 이 최근 실행했다' 로 볼 최대 경과 시간(분, 기본 $MAX_AGE_MIN)
  -h, --help       도움말

종료 코드: 0 정상 / 1 FAIL 항목 있음 / 2 잘못된 사용법
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)
            [[ -n "${2:-}" ]] || { echo "[ERROR] --user 에 사용자 이름이 필요합니다" >&2; exit 2; }
            CRON_USER="$2"; shift 2 ;;
        --max-age)
            [[ -n "${2:-}" ]] || { echo "[ERROR] --max-age 에 분(정수)이 필요합니다" >&2; exit 2; }
            MAX_AGE_MIN="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1 (--help 참고)" >&2; exit 2 ;;
    esac
done

if ! [[ "$MAX_AGE_MIN" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] --max-age 는 1 이상의 정수여야 합니다: $MAX_AGE_MIN" >&2
    exit 2
fi
MAX_AGE_SEC=$((MAX_AGE_MIN * 60))

# ---------------------------------------------------------------- 출력 도우미
STEP=0
TOTAL=7
FAILS=0
step() {   # 제목 상태 상세
    STEP=$((STEP + 1))
    printf '[%d/%d] %s ... [%s] %s\n' "$STEP" "$TOTAL" "$1" "$2" "$3"
    [[ "$2" == FAIL ]] && FAILS=$((FAILS + 1))
    return 0
}
recover() { printf '      → 복구: %s\n' "$*"; }
hint()    { printf '      → %s\n' "$*"; }

printf '====== CRON CHECK (user %s) ======\n' "$CRON_USER"

NOW="$(date +%s)"

# ================================================================= 1. crontab 등록
# 매분 실행(* * * * *)하면서 monitor.sh 를 부르는, 주석이 아닌 줄이 있어야 한다.
cron_text=""
cron_readable=1
if [[ -n "$CRONTAB_FILE" ]]; then
    if [[ -r "$CRONTAB_FILE" ]]; then
        cron_text="$(cat -- "$CRONTAB_FILE")"
    else
        cron_readable=0
    fi
else
    cron_text="$(crontab -u "$CRON_USER" -l 2>/dev/null)" || cron_readable=0
fi

cron_matched=""
if [[ $cron_readable -eq 1 ]]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue    # 주석 줄 제외
        [[ "$line" == *monitor.sh* ]] || continue
        read -r f1 f2 f3 f4 f5 _ <<< "$line"
        if [[ "$f1" == '*' && "$f2" == '*' && "$f3" == '*' && "$f4" == '*' && "$f5" == '*' ]]; then
            cron_matched="$line"; break
        fi
    done <<< "$cron_text"
fi

# 교차 확인: monitor.sh 는 일반 계정(agent-admin)으로만 돌아야 한다. root 로도 돌면 매분 두 번 실행되고,
# root 가 순환하며 만든 monitor.log 가 root 소유가 되어 다음 분부터 agent-admin 이 쓰지 못한다(exit 2).
root_hits=""
if [[ -n "$ROOT_CRONTAB_FILE" ]]; then
    root_text="$(cat -- "$ROOT_CRONTAB_FILE" 2>/dev/null)"
elif [[ "$(id -u)" -eq 0 && "$CRON_USER" != root ]]; then
    root_text="$(crontab -u root -l 2>/dev/null)"
else
    root_text=""
fi
root_hits="$(printf '%s\n' "$root_text" | grep -v '^[[:space:]]*#' | grep -F 'monitor.sh' | head -n 1)"
# shellcheck disable=SC2086  # 공백 구분 목록과 glob 을 그대로 펼친다
for f in $SYSTEM_CRON_FILES; do
    [[ -f "$f" && -r "$f" ]] || continue
    hit="$(awk '!/^[[:space:]]*#/ && /monitor\.sh/ && $6 == "root" { print FILENAME ": " $0; exit }' "$f")"
    [[ -n "$hit" && -z "$root_hits" ]] && root_hits="$hit"
done

if [[ $cron_readable -eq 0 ]]; then
    step "crontab 등록" SKIP "crontab 을 읽을 수 없습니다 (root 로 실행하세요)"
elif [[ "$CRON_USER" == root && -n "$cron_matched" ]]; then
    step "crontab 등록" FAIL "root 의 crontab 에 등록됨 — root 가 만든 로그 파일은 agent-admin 이 쓰지 못합니다"
    recover "sudo crontab -u root -e 에서 monitor.sh 줄 삭제 후 sudo bash setup/07-cron.sh (agent-admin 으로 등록)"
elif [[ -n "$cron_matched" && -n "$root_hits" ]]; then
    step "crontab 등록" WARN "$CRON_USER 에 등록됐지만 root 에서도 monitor.sh 실행: $root_hits"
    hint "중복 실행 · root 소유 로그 위험 — root 쪽 줄을 지우세요 (sudo crontab -u root -e)"
elif [[ -n "$cron_matched" ]]; then
    step "crontab 등록" OK "$cron_matched"
else
    step "crontab 등록" FAIL "매분(* * * * *) monitor.sh 를 실행하는 항목이 없습니다"
    recover "sudo bash setup/07-cron.sh"
fi

# ================================================================= 2. cron 서비스
if [[ "$SKIP_SERVICE" == 1 ]]; then
    step "cron 서비스" SKIP "SKIP_SERVICE=1 (점검 건너뜀)"
elif [[ "$(systemctl is-active cron 2>/dev/null)" == active ]] || pgrep -x cron >/dev/null 2>&1; then
    step "cron 서비스" OK "cron 데몬이 실행 중입니다"
else
    step "cron 서비스" FAIL "cron 데몬이 실행 중이 아닙니다"
    recover "sudo systemctl enable --now cron"
fi

# ================================================================= 3. 실행 권한
# cron 실행자(CRON_USER)가 monitor.sh 를 실행하고 로그 디렉토리에 쓸 수 있어야 한다.
# 남의 권한을 흉내 내려면 root 가 sudo -u 로 직접 시도해야 정확하다.
if [[ "$SKIP_SUDO" == 1 || "$(id -u)" -ne 0 ]]; then
    step "실행 권한" SKIP "root 가 아니거나 SKIP_SUDO=1 (sudo -u 점검 건너뜀)"
else
    can_exec=0; can_write=0
    sudo -u "$CRON_USER" test -x "$MONITOR_SCRIPT" && can_exec=1
    sudo -u "$CRON_USER" test -w "$AGENT_LOG_DIR" && can_write=1
    if [[ $can_exec -eq 1 && $can_write -eq 1 ]]; then
        step "실행 권한" OK "$CRON_USER: monitor.sh 실행 가능, $AGENT_LOG_DIR 쓰기 가능"
    else
        detail=""
        [[ $can_exec -eq 0 ]] && detail+="monitor.sh 실행(x) 불가 "
        [[ $can_write -eq 0 ]] && detail+="$AGENT_LOG_DIR 쓰기(w) 불가"
        step "실행 권한" FAIL "$CRON_USER: $detail"
        [[ $can_exec -eq 0 ]] && recover "sudo bash setup/06-install-monitor.sh"
        [[ $can_write -eq 0 ]] && recover "sudo bash setup/04-directories.sh"
        hint "agent-core 그룹 확인: $(id "$CRON_USER" 2>&1)"
    fi
fi

# ================================================================= 4. syslog 의 CRON 실행 기록
# syslog(또는 journalctl)에서 '(USER) CMD (... monitor.sh ...)' 마지막 줄을 찾아 경과 시간을 본다.
syslog_src=""
syslog_content=""
if [[ -r "$SYSLOG_FILE" ]]; then
    syslog_src="$SYSLOG_FILE"
    syslog_content="$(cat -- "$SYSLOG_FILE")"
elif command -v journalctl >/dev/null 2>&1; then
    syslog_src="journalctl -u cron"
    syslog_content="$(journalctl -u cron --no-pager -o short-iso -n 500 2>/dev/null || true)"
fi

if [[ -z "$syslog_src" ]]; then
    step "syslog 의 CRON 실행 기록" SKIP "syslog 도 journalctl 도 읽을 수 없습니다"
else
    cron_log_line="$(printf '%s\n' "$syslog_content" \
        | grep -F 'CRON[' | grep -F "($CRON_USER) CMD (" | grep -F 'monitor.sh' | tail -n 1)"
    if [[ -z "$cron_log_line" ]]; then
        step "syslog 의 CRON 실행 기록" FAIL "$syslog_src 에 monitor.sh 실행 기록이 없습니다"
        recover "cron 서비스·crontab 등록(1·2번)을 먼저 확인하세요"
    else
        read -r w1 w2 w3 _ <<< "$cron_log_line"
        if [[ "$w1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T ]]; then
            ts="$w1"                                   # RFC3339: 2026-10-21T00:57:01.123456+09:00
        else
            ts="$w1 $w2 $w3"                           # classic: Mon DD HH:MM:SS
        fi
        epoch="$(date -d "$ts" +%s 2>/dev/null || true)"
        if [[ -z "$epoch" ]]; then
            step "syslog 의 CRON 실행 기록" FAIL "시각을 해석할 수 없습니다: $ts"
        else
            age=$((NOW - epoch))
            if (( age > MAX_AGE_SEC )); then
                step "syslog 의 CRON 실행 기록" FAIL "cron 이 최근 ${MAX_AGE_MIN}분 동안 실행하지 않음 (마지막 ${age}초 전)"
                recover "sudo systemctl status cron; journalctl -u cron -n 20"
            else
                step "syslog 의 CRON 실행 기록" OK "마지막 실행 ${age}초 전 ($syslog_src)"
            fi
        fi
    fi
fi

# ================================================================= 5. monitor.log 갱신
# cron 이 돌아도 Health Check 실패(exit 1)나 권한 오류면 기록이 안 남는다 → 시각으로 확인.
if [[ ! -s "$MONITOR_LOG" ]]; then
    step "monitor.log 갱신" FAIL "monitor.log 이 없거나 비어 있습니다: $MONITOR_LOG"
    hint "cron 은 실행되는데 기록이 없으면 Health Check 실패(exit 1) 또는 권한 오류 — cron.log 확인"
else
    last_log="$(tail -n 1 -- "$MONITOR_LOG")"
    if [[ "$last_log" =~ ^\[([0-9]{4}-[0-9]{2}-[0-9]{2}\ [0-9]{2}:[0-9]{2}:[0-9]{2})\] ]]; then
        log_epoch="$(date -d "${BASH_REMATCH[1]}" +%s 2>/dev/null || true)"
        if [[ -z "$log_epoch" ]]; then
            step "monitor.log 갱신" FAIL "마지막 줄 시각을 해석할 수 없습니다: ${BASH_REMATCH[1]}"
        else
            log_age=$((NOW - log_epoch))
            if (( log_age > MAX_AGE_SEC )); then
                step "monitor.log 갱신" FAIL "최근 ${MAX_AGE_MIN}분간 기록이 없습니다 (마지막 ${log_age}초 전)"
                hint "cron 은 실행되는데 기록이 없으면 Health Check 실패(exit 1) 또는 권한 오류 — cron.log 확인"
            else
                step "monitor.log 갱신" OK "마지막 기록 ${log_age}초 전"
            fi
        fi
    else
        step "monitor.log 갱신" FAIL "마지막 줄에서 [YYYY-MM-DD HH:MM:SS] 시각을 찾지 못했습니다"
    fi
fi

# ================================================================= 6. cron.log 오류
# cron 실행 시 stderr 는 cron.log 로 모인다. 마지막 줄의 오류가 가장 최근 실패를 가리킨다.
is_err() {
    [[ "$1" == *'[ERROR]'* || "$1" == *'Permission denied'* \
        || "$1" == *'No such file'* || "$1" == *'command not found'* ]]
}
if [[ ! -e "$CRON_LOG" ]]; then
    step "cron.log 오류" WARN "cron.log 이 아직 없습니다: $CRON_LOG (cron 이 한 번도 쓰지 않았을 수 있음)"
else
    last20="$(tail -n 20 -- "$CRON_LOG" | grep -v '^\[HINT\]')"   # monitor.sh 의 복구 안내 줄은 제외
    last_err_line="$(printf '%s\n' "$last20" | tail -n 1)"
    if is_err "$last_err_line"; then
        step "cron.log 오류" FAIL "$last_err_line"
        if [[ "$last_err_line" == *'Permission denied'* ]]; then
            hint "권한 문제입니다 — 3번 실행 권한 복구를 참고하세요"
        elif [[ "$last_err_line" == *'command not found'* || "$last_err_line" == *'No such file'* ]]; then
            hint "경로 문제입니다 — crontab 의 PATH·스크립트 경로를 확인하세요"
        else
            recover "sudo -iu $CRON_USER $AGENT_HOME/bin/run-agent.sh --background"
        fi
    else
        err_count="$(printf '%s\n' "$last20" | grep -Ec '\[ERROR\]|Permission denied|No such file|command not found')"
        if (( err_count > 0 )); then
            step "cron.log 오류" WARN "최근 20줄에 과거 오류 ${err_count}건 (마지막 줄은 정상)"
        else
            step "cron.log 오류" OK "최근 오류 없음"
        fi
    fi
fi

# ================================================================= 7. cron 환경의 env 로드
# cron 은 로그인 셸이 아니어서 /etc/profile.d 를 읽지 않고 PATH·HOME 정도만 넘긴다. 그래서 monitor.sh 는
# AGENT_ENV_FILE 을 스스로 source 한다. 같은 조건(env -i 로 비운 환경, 실행 계정)에서 그 파일이 실제로
# 읽히는지 확인한다. 읽지 못하면 monitor.sh 는 오류 없이 스크립트 기본값으로 돌아가 값이 조용히 어긋난다.
env_probe='[ -r "$1" ] || { echo "UNREADABLE"; exit 0; }
bash -n "$1" 2>/dev/null || { echo "SOURCE_FAIL"; exit 0; }
. "$1" >/dev/null 2>&1 || { echo "SOURCE_FAIL"; exit 0; }
printf "OK %s %s\n" "${AGENT_PORT:-}" "${AGENT_LOG_DIR:-}"'
env_cmd=(env -i HOME=/ PATH=/usr/bin:/bin bash -c "$env_probe" _ "$AGENT_ENV_FILE")
if [[ "$SKIP_SUDO" != 1 && "$(id -u)" -eq 0 ]]; then
    env_who="$CRON_USER"
    env_out="$(sudo -u "$CRON_USER" "${env_cmd[@]}" 2>/dev/null)"
else
    env_who="$(id -un)"
    env_out="$("${env_cmd[@]}" 2>/dev/null)"
fi
read -r env_state env_port env_logdir <<< "$env_out"
if [[ ! -e "$AGENT_ENV_FILE" ]]; then
    step "cron 환경의 env 로드" WARN "$AGENT_ENV_FILE 없음 — monitor.sh 는 스크립트 기본값(포트 15034)으로 실행"
    recover "sudo bash setup/05-environment.sh"
elif [[ "$env_state" == UNREADABLE ]]; then
    step "cron 환경의 env 로드" FAIL "$env_who 가 $AGENT_ENV_FILE 을 읽을 수 없습니다 (기본값으로 조용히 실행됨)"
    recover "sudo bash setup/05-environment.sh   # root:root 0644 로 다시 설치"
elif [[ "$env_state" != OK ]]; then
    step "cron 환경의 env 로드" FAIL "$AGENT_ENV_FILE 을 source 하지 못했습니다 (문법 오류)"
    recover "bash -n $AGENT_ENV_FILE"
elif [[ -z "$env_port" ]]; then
    step "cron 환경의 env 로드" WARN "$AGENT_ENV_FILE 에 AGENT_PORT 가 없습니다 (기본값 15034 사용)"
elif [[ "$env_port" != "${AGENT_PORT:-}" ]]; then
    step "cron 환경의 env 로드" FAIL "cron 환경 AGENT_PORT=$env_port, 점검 환경 AGENT_PORT=${AGENT_PORT:-} 로 다릅니다"
    hint "AGENT_PORT 를 export 한 셸에서 점검했는지, env 파일이 덮어쓰는 값인지 확인"
else
    step "cron 환경의 env 로드" OK "$env_who(env -i): AGENT_PORT=$env_port AGENT_LOG_DIR=${env_logdir:-기본값} ← $AGENT_ENV_FILE"
fi

# ================================================================= 결론
echo
if (( FAILS == 0 )); then
    echo "결론: 정상"
    exit 0
else
    echo "결론: ${FAILS}개 항목 실패"
    exit 1
fi
