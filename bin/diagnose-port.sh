#!/usr/bin/env bash
# =============================================================================
#  diagnose-port.sh — "프로세스는 떠 있는데 포트가 안 열린다" 진단 도구
#
#  설치 위치 : $AGENT_HOME/bin/diagnose-port.sh
#  실행 계정 : agent-admin / 운영자 (일부 단계는 root 가 아니면 SKIP 된다)
#
#  monitor.sh 가 "포트 FAIL" 을 알렸을 때, 왜 안 열렸는지를 한 눈에 보여준다.
#  앱 프로세스 → LISTEN 여부 → 바인딩 주소 → 포트 충돌 → 환경변수 → 권한 →
#  프로세스 상태 → 방화벽 허용 규칙을 8단계로 점검한다.
#
#  종료 코드
#    0 FAIL 없음 (WARN 은 있어도 0) / 1 FAIL 1개 이상 / 2 실행 오류(잘못된 포트·옵션)
#
#  참고: 방화벽은 로컬 LISTEN 자체를 막지 않으므로 8단계는 FAIL 이 아니라 WARN 이다.
# =============================================================================
set -uo pipefail
export LC_ALL=C

SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME

# ---------------------------------------------------------------- 설정 (환경변수)
AGENT_ENV_FILE="${AGENT_ENV_FILE:-/etc/agent-app/agent-app.env}"
if [[ -r "$AGENT_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$AGENT_ENV_FILE"
fi

AGENT_PORT="${AGENT_PORT:-15034}"
APP_PROCESS_REGEX="${APP_PROCESS_REGEX:-^agent[_-]app([._-].*)?$}"
FIREWALL="${FIREWALL:-auto}"                 # auto | ufw | firewalld | none
UFW_CONF="${UFW_CONF:-/etc/ufw/ufw.conf}"
UFW_USER_RULES="${UFW_USER_RULES:-/etc/ufw/user.rules}"
UFW_USE_STATUS="${UFW_USE_STATUS:-1}"

usage() {
    cat <<EOF
사용법: $SCRIPT_NAME [PORT] [--process REGEX] [-h|--help]

앱 프로세스는 떠 있는데 포트가 안 열릴 때 원인을 8단계로 진단합니다.

인자
  PORT             진단할 포트 (생략 시 AGENT_PORT=$AGENT_PORT)
  --process REGEX  앱 실행 파일 이름 정규식 (기본: $APP_PROCESS_REGEX)
  -h, --help       도움말

종료 코드: 0 FAIL 없음 / 1 FAIL 있음 / 2 실행 오류(잘못된 포트·옵션)
EOF
}

# ---------------------------------------------------------------- 인자 파싱
PORT_ARG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --process)
            shift
            [[ $# -gt 0 ]] || { echo "[ERROR] --process 뒤에 정규식이 필요합니다" >&2; exit 2; }
            APP_PROCESS_REGEX="$1" ;;
        --process=*) APP_PROCESS_REGEX="${1#*=}" ;;
        --) ;;
        -*) echo "[ERROR] 알 수 없는 옵션: $1 (--help 참고)" >&2; exit 2 ;;
        *)
            if [[ -n "$PORT_ARG" ]]; then
                echo "[ERROR] 포트를 두 개 이상 지정했습니다: $1" >&2; exit 2
            fi
            if ! [[ "$1" =~ ^[0-9]+$ ]]; then
                echo "[ERROR] 포트는 숫자여야 합니다: $1" >&2; exit 2
            fi
            PORT_ARG="$1" ;;
    esac
    shift
done

PORT="${PORT_ARG:-$AGENT_PORT}"
if ! [[ "$PORT" =~ ^[1-9][0-9]*$ ]]; then
    echo "[ERROR] 포트 값이 올바르지 않습니다: $PORT" >&2; exit 2
fi

# ---------------------------------------------------------------- 공용 도우미
# monitor.sh 의 find_app_pids 와 같은 규칙(복사: monitor.sh 를 source 하지 않는다)
find_app_pids() {
    local dir pid args exe script
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        [[ -r "$dir/cmdline" ]] || continue
        mapfile -d '' -t args < "$dir/cmdline" 2>/dev/null || continue
        [[ ${#args[@]} -gt 0 ]] || continue
        exe="$(basename -- "${args[0]}")"
        script="$(basename -- "${args[1]:-x}")"
        [[ "$exe" == *.sh || "$script" == *.sh ]] && continue
        if [[ "$exe" =~ $APP_PROCESS_REGEX ]] || { [[ "$exe" == python* ]] && [[ "$script" =~ $APP_PROCESS_REGEX ]]; }; then
            if [[ -n "${APP_USER:-}" && "$(stat -c %U "$dir" 2>/dev/null)" != "$APP_USER" ]]; then
                continue
            fi
            echo "$pid"
        fi
    done
}

is_wildcard() { case "$1" in 0.0.0.0|'[::]'|'::'|'*') return 0 ;; *) return 1 ;; esac; }
is_loopback() { case "$1" in 127.*|'[::1]'|'::1') return 0 ;; *) return 1 ;; esac; }

# PORT 를 LISTEN 중인 로컬 주소(호스트 부분)들을 LISTEN_ADDRS 에 담는다.
LISTEN_ADDRS=()
collect_listen_addrs() {
    local port="$1" line laddr hex files=() f
    LISTEN_ADDRS=()
    if command -v ss >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            laddr="$(awk '{ print $4 }' <<< "$line")"
            LISTEN_ADDRS+=("${laddr%:*}")
        done < <(ss -Hltn "sport = :$port" 2>/dev/null)
        return
    fi
    # 최소 설치 환경: /proc/net/tcp 를 직접 읽어 와일드카드/루프백만 구분
    hex="$(printf '%04X' "$port")"
    for f in /proc/net/tcp /proc/net/tcp6; do [[ -r "$f" ]] && files+=("$f"); done
    [[ ${#files[@]} -gt 0 ]] || return 0
    while IFS= read -r laddr; do
        LISTEN_ADDRS+=("$laddr")
    done < <(awk -v p=":$hex" 'FNR > 1 && substr($2, length($2) - 4) == p && $4 == "0A" {
        a = substr($2, 1, length($2) - 5)
        if (a ~ /^0+$/) print "0.0.0.0"
        else if (a == "0100007F" || a ~ /0+1$/) print "127.0.0.1"
        else print "other"
    }' "${files[@]}")
}

# ss -Hltnp 를 한 번만 수집해 여러 단계에서 재사용
SS_P="$(ss -Hltnp 2>/dev/null || true)"

# ---------------------------------------------------------------- 출력 상태 기계
STEP=0
HAS_FAIL=0
FIRST_FAIL=""
# step <STATUS> <제목> <detail> [hint]
step() {
    local status="$1" title="$2" detail="$3" hint="${4:-}"
    STEP=$((STEP + 1))
    printf '[%d/8] %s ... [%s] %s\n' "$STEP" "$title" "$status" "$detail"
    if [[ "$status" != OK ]]; then
        printf '      → %s\n' "$hint"
    fi
    if [[ "$status" == FAIL ]]; then
        HAS_FAIL=1
        [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="$detail"
    elif [[ "$status" == WARN ]]; then
        WARN_COUNT=$((WARN_COUNT + 1))
        [[ -z "$FIRST_WARN" ]] && FIRST_WARN="[$STEP/8] $detail"
    fi
}
WARN_COUNT=0
FIRST_WARN=""

printf '====== PORT DIAGNOSIS (port %s) ======\n' "$PORT"

# ===================================================== 1. 앱 프로세스
mapfile -t PIDS < <(find_app_pids)
app_running=0
rep_pid=""
if [[ ${#PIDS[@]} -gt 0 ]]; then
    app_running=1
    rep_pid="${PIDS[0]}"
    step OK "앱 프로세스" "실행 중 (PID: ${PIDS[*]})"
else
    step FAIL "앱 프로세스" "앱 프로세스가 없음 (패턴: $APP_PROCESS_REGEX)" \
        "run-agent.sh --background 로 앱을 기동하세요"
fi

# ===================================================== 2. 포트 LISTEN
collect_listen_addrs "$PORT"
port_listening=0
if [[ ${#LISTEN_ADDRS[@]} -eq 0 ]]; then
    step FAIL "포트 LISTEN" "$PORT 포트가 LISTEN 상태가 아님" \
        "앱이 해당 포트를 bind/listen 하는지, 기동이 끝났는지 확인하세요"
else
    port_listening=1
    addrs_str="${LISTEN_ADDRS[*]}"
    any_nonloop=0
    for a in "${LISTEN_ADDRS[@]}"; do
        is_loopback "$a" || any_nonloop=1
    done
    if [[ $any_nonloop -eq 1 ]]; then
        step OK "포트 LISTEN" "LISTEN 중 ($addrs_str)"
    else
        step WARN "포트 LISTEN" "루프백에만 바인딩 ($addrs_str)" \
            "루프백에만 바인딩 — 외부에서 접속 불가, 앱의 bind 주소 확인"
    fi
fi

# ===================================================== 3. 앱이 실제로 연 포트
if [[ $app_running -eq 0 ]]; then
    step SKIP "앱이 연 포트" "앱 프로세스가 없어 건너뜀" "먼저 앱을 기동하세요"
elif ! grep -q 'pid=' <<< "$SS_P"; then
    step SKIP "앱이 연 포트" "프로세스 소유 정보를 볼 수 없음" \
        "sudo 로 다시 실행하면 어떤 PID 가 어떤 포트를 열었는지 보입니다"
else
    app_ports=()
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        laddr="$(awk '{ print $4 }' <<< "$line")"
        pport="${laddr##*:}"
        for p in "${PIDS[@]}"; do
            if [[ "$line" == *"pid=$p,"* ]]; then
                app_ports+=("$pport"); break
            fi
        done
    done <<< "$SS_P"
    mapfile -t app_ports < <(printf '%s\n' "${app_ports[@]}" | grep -v '^$' | sort -un)
    if printf '%s\n' "${app_ports[@]}" | grep -qx "$PORT"; then
        step OK "앱이 연 포트" "앱이 $PORT 포트를 열고 있음"
    elif [[ ${#app_ports[@]} -gt 0 ]]; then
        step FAIL "앱이 연 포트" "앱은 ${app_ports[*]} 포트로 열려 있음" \
            "앱은 ${app_ports[*]} 포트를 사용 중 — AGENT_PORT 설정/오타 확인"
    else
        step WARN "앱이 연 포트" "앱이 아직 어떤 포트도 열지 않음" \
            "아직 기동 중이거나 멈춤 — 앱 로그 마지막 줄 확인, 몇 초 뒤 재확인"
    fi
fi

# ===================================================== 4. 포트 충돌
owner_pid=""
if [[ $port_listening -eq 1 ]]; then
    owner_pid="$(grep -o 'pid=[0-9]*' <<< "$(ss -Hltnp "sport = :$PORT" 2>/dev/null)" | head -n1 | cut -d= -f2)"
fi
if [[ $port_listening -eq 0 ]]; then
    step OK "포트 충돌" "$PORT 포트를 쓰는 프로세스 없음"
elif [[ -z "$owner_pid" ]]; then
    step SKIP "포트 충돌" "포트 소유 PID 를 확인할 수 없음" \
        "sudo 로 다시 실행하면 포트를 점유한 프로세스를 확인할 수 있습니다"
elif [[ $app_running -eq 1 ]] && printf '%s\n' "${PIDS[@]}" | grep -qx "$owner_pid"; then
    step OK "포트 충돌" "포트 주인이 앱 자신 (PID $owner_pid)"
else
    owner_comm="$(cat "/proc/$owner_pid/comm" 2>/dev/null || echo '?')"
    step FAIL "포트 충돌" "다른 프로세스(PID $owner_pid, $owner_comm)가 포트 사용 중" \
        "AGENT_PORT 를 바꾸거나 PID $owner_pid 를 정리하세요"
fi

# ===================================================== 5. 환경변수
if [[ $app_running -eq 0 ]]; then
    step SKIP "환경변수" "앱 프로세스가 없어 건너뜀" "먼저 앱을 기동하세요"
elif [[ ! -r "/proc/$rep_pid/environ" ]]; then
    step SKIP "환경변수" "앱의 환경변수를 읽을 권한이 없음" "sudo 로 다시 실행하세요"
else
    env_port="$(tr '\0' '\n' < "/proc/$rep_pid/environ" 2>/dev/null | grep '^AGENT_PORT=' | tail -n1 | cut -d= -f2)"
    if [[ -z "$env_port" ]]; then
        step WARN "환경변수" "앱 환경에 AGENT_PORT 가 없음" \
            "앱이 기본 포트로 떴을 수 있음 — AGENT_PORT 를 설정했는지 확인"
    elif [[ "$env_port" != "$PORT" ]]; then
        step FAIL "환경변수" "앱 AGENT_PORT=$env_port 가 진단 포트 $PORT 와 다름" \
            "진단 포트와 AGENT_PORT 를 일치시키세요"
    else
        step OK "환경변수" "AGENT_PORT=$env_port (진단 포트와 일치)"
    fi
fi

# ===================================================== 6. 포트 권한
if [[ $app_running -eq 0 ]]; then
    step SKIP "포트 권한" "앱 프로세스가 없어 건너뜀" "먼저 앱을 기동하세요"
else
    app_uid="$(awk '/^Uid:/ { print $2 }' "/proc/$rep_pid/status" 2>/dev/null)"
    if (( PORT < 1024 )) && [[ "${app_uid:-0}" != 0 ]]; then
        step WARN "포트 권한" "$PORT 는 1024 미만, 앱 uid=$app_uid" \
            "1024 미만 포트는 root 또는 CAP_NET_BIND_SERVICE 가 필요합니다"
    elif (( PORT < 1024 )); then
        step OK "포트 권한" "$PORT 는 1024 미만이지만 root(uid 0) 프로세스(PID $rep_pid)가 bind"
    else
        step OK "포트 권한" "포트 $PORT 는 1024 이상이라 권한 제약 없음"
    fi
fi

# ===================================================== 7. 프로세스 상태
if [[ $app_running -eq 0 ]]; then
    step SKIP "프로세스 상태" "앱 프로세스가 없어 건너뜀" "먼저 앱을 기동하세요"
else
    pstate="$(awk '/^State:/ { print $2 }' "/proc/$rep_pid/status" 2>/dev/null)"
    pthreads="$(awk '/^Threads:/ { print $2 }' "/proc/$rep_pid/status" 2>/dev/null)"
    case "$pstate" in
        R|S|I) step OK "프로세스 상태" "State=$pstate Threads=${pthreads:-?} (정상)" ;;
        D|T|t) step WARN "프로세스 상태" "State=$pstate Threads=${pthreads:-?} (멈춤/디스크 대기)" \
                "top -H -p $rep_pid / cat /proc/$rep_pid/wchan 로 대기 원인을 확인하세요" ;;
        Z) step FAIL "프로세스 상태" "State=Z (좀비) — 실제 앱은 이미 죽음" \
                "부모 프로세스를 재시작해 좀비를 정리하세요" ;;
        *) step WARN "프로세스 상태" "State=${pstate:-?} Threads=${pthreads:-?}" \
                "프로세스 상태를 확인할 수 없습니다" ;;
    esac
fi

# ===================================================== 8. 방화벽 허용 규칙
# 방화벽은 LISTEN 자체를 막지 않으므로 FAIL 이 아니라 WARN 으로 알린다.
fw_kind="$FIREWALL"
if [[ "$fw_kind" == auto ]]; then
    if command -v ufw >/dev/null 2>&1 || [[ -f "$UFW_CONF" ]]; then fw_kind=ufw
    elif command -v firewall-cmd >/dev/null 2>&1; then fw_kind=firewalld
    else fw_kind=none; fi
fi
case "$fw_kind" in
    ufw)
        if [[ "$UFW_USE_STATUS" == 1 ]] && { fw_out="$(ufw status 2>/dev/null)" || fw_out="$(sudo -n ufw status 2>/dev/null)"; }; then
            if [[ "$fw_out" != *"Status: active"* ]]; then
                step WARN "방화벽 허용 규칙" "ufw 가 비활성(inactive)" \
                    "ufw 가 꺼져 있어 포트는 열리지만 운영 시 방화벽을 켜세요"
            elif grep -Eq "^($PORT/tcp|$PORT )" <<< "$fw_out" && grep -E "^($PORT/tcp|$PORT )" <<< "$fw_out" | grep -q 'ALLOW'; then
                step OK "방화벽 허용 규칙" "ufw 가 $PORT 포트를 ALLOW"
            else
                step WARN "방화벽 허용 규칙" "ufw 에 $PORT 허용 규칙 없음" \
                    "로컬 LISTEN 이어도 외부에서 차단됨 — sudo ufw allow $PORT/tcp"
            fi
        elif [[ -r "$UFW_USER_RULES" ]]; then
            if grep -Eq -- "--dport $PORT .*-j ACCEPT" "$UFW_USER_RULES"; then
                step OK "방화벽 허용 규칙" "user.rules 에 $PORT ACCEPT 규칙 있음"
            else
                step WARN "방화벽 허용 규칙" "user.rules 에 $PORT 허용 규칙 없음" \
                    "로컬 LISTEN 이어도 외부에서 차단됨 — sudo ufw allow $PORT/tcp"
            fi
        elif [[ -r "$UFW_CONF" ]]; then
            if grep -Eq '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*yes' "$UFW_CONF"; then
                step WARN "방화벽 허용 규칙" "ufw 활성이지만 규칙을 확인할 권한이 없음" \
                    "sudo ufw status 로 $PORT 허용 여부를 확인하세요"
            else
                step WARN "방화벽 허용 규칙" "ufw 가 비활성(inactive)" \
                    "ufw 가 꺼져 있어 포트는 열리지만 운영 시 방화벽을 켜세요"
            fi
        else
            step WARN "방화벽 허용 규칙" "ufw 상태를 확인할 수 없음" \
                "sudo ufw status 로 $PORT 허용 여부를 확인하세요"
        fi ;;
    firewalld)
        if firewall-cmd --list-ports 2>/dev/null | grep -qw "$PORT/tcp"; then
            step OK "방화벽 허용 규칙" "firewalld 가 $PORT/tcp 를 허용"
        else
            step WARN "방화벽 허용 규칙" "firewalld 에 $PORT/tcp 허용 규칙 없음" \
                "로컬 LISTEN 이어도 외부에서 차단됨 — sudo firewall-cmd --add-port=$PORT/tcp"
        fi ;;
    *)
        step SKIP "방화벽 허용 규칙" "UFW/firewalld 를 찾지 못함" \
            "방화벽이 없으면 포트는 열리지만, 운영 환경에서는 방화벽 설정을 권장합니다" ;;
esac

# ===================================================== 결론
if [[ $HAS_FAIL -eq 1 ]]; then
    printf '결론: %s\n' "$FIRST_FAIL"
    exit 1
fi
if [[ $WARN_COUNT -gt 0 ]]; then
    # 포트는 로컬에서 LISTEN 중이지만 바깥 접속을 막을 수 있는 항목이 있다 (루프백 바인딩, 방화벽 규칙 등)
    printf '결론: 로컬 LISTEN 정상, 확인 필요 %d건 — %s\n' "$WARN_COUNT" "$FIRST_WARN"
    exit 0
fi
printf '결론: %s\n' "포트 정상"
exit 0
