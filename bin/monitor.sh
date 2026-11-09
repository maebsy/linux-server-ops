#!/usr/bin/env bash
# =============================================================================
#  monitor.sh — agent-app 시스템 관제 스크립트
#
#  설치 위치 : $AGENT_HOME/bin/monitor.sh   (소유 agent-dev : 그룹 agent-core, 권한 750)
#  실행 계정 : agent-admin (agent-core 그룹이라 r-x 권한으로 실행 가능), cron 매분
#
#  처리 순서
#    1. Health Check (실패 시 exit 1)  : 앱 프로세스 실행 여부 → TCP 포트 LISTEN 여부 (서비스 불가 = 즉시 조치)
#    2. 상태 점검   (경고만, 계속 진행) : 방화벽(UFW/firewalld) 활성화 여부
#    3. 자원 수집                      : CPU(%) / 메모리(%) / 루트 파티션 디스크(%)
#    4. 임계값 경고 (경고만)            : CPU > 20%, MEM > 10%, DISK > 80% (서비스는 동작 중 = 추세 관찰, 순간 급등마다 exit 하면 오탐 장애가 쌓임)
#    5. 로그 기록                      : [YYYY-MM-DD HH:MM:SS] PID:.. CPU:..% MEM:..% DISK_USED:..%  (시각 = 서버 로컬 TZ, 이 서버는 KST +0900)
#       - 10MB 를 넘으면 monitor.log → monitor.log.1 … .9 로 순환 (최대 10개 파일 유지)
#
#  종료 코드
#    0 정상 (경고가 있어도 0) / 1 Health Check 실패 / 2 실행 환경 오류(로그 쓰기 불가, 잘못된 설정)
#
#  모든 값은 환경변수로 바꿀 수 있다 (cron 은 로그인 셸이 아니므로 기본값을 스크립트에 둔다).
# =============================================================================
set -uo pipefail
export LC_ALL=C           # 숫자·날짜 형식을 로케일과 무관하게 고정 (awk 소수점, ps 출력)

SCRIPT_NAME="$(basename "$0")"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly SCRIPT_NAME SCRIPT_DIR

# ---------------------------------------------------------------- 설정 (환경변수)
# /etc/agent-app/agent-app.env 가 있으면 먼저 읽는다 (cron 환경에서도 같은 값 사용)
AGENT_ENV_FILE="${AGENT_ENV_FILE:-/etc/agent-app/agent-app.env}"
if [[ -r "$AGENT_ENV_FILE" ]]; then
    # shellcheck disable=SC1090
    source "$AGENT_ENV_FILE"
fi

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
# 앱 실행 파일 이름(경로 제외)에 대한 정규식: agent_app.py / agent-app-linux-x86 / agent-app-linux-arm64 …
APP_PROCESS_REGEX="${APP_PROCESS_REGEX:-^agent[_-]app([._-].*)?$}"
APP_PROCESS_LABEL="${APP_PROCESS_LABEL:-agent-app}"

CPU_WARN="${CPU_WARN:-20}"          # %
MEM_WARN="${MEM_WARN:-10}"          # %
DISK_WARN="${DISK_WARN:-80}"        # %
CPU_SAMPLE_SEC="${CPU_SAMPLE_SEC:-1}"  # 초. /proc/stat 을 이 간격으로 두 번 읽은 차이 = 그 구간 평균 (1초: 순간값에 가깝고 cron 매분 실행도 짧게). 소수 1자리

MONITOR_LOG="${MONITOR_LOG:-$AGENT_LOG_DIR/monitor.log}"
MAX_LOG_SIZE_BYTES="${MAX_LOG_SIZE_BYTES:-10485760}"   # 10MB
MAX_LOG_FILES="${MAX_LOG_FILES:-10}"                   # monitor.log + monitor.log.1 ~ .9
MONITOR_LOG_FORMAT="${MONITOR_LOG_FORMAT:-basic}"      # basic | extended (프로세스 자원 추가, B4-2 재사용)
UFW_CONF="${UFW_CONF:-/etc/ufw/ufw.conf}"
UFW_USE_STATUS="${UFW_USE_STATUS:-1}"                  # 1: ufw status 우선, 0: ufw.conf 만 확인
FIREWALL="${FIREWALL:-auto}"                           # auto | ufw | firewalld | none

SHOW_STATS="auto"
QUIET=0

usage() {
    cat <<EOF
사용법: $SCRIPT_NAME [--stats|--no-stats] [--quiet] [--help]

agent-app 프로세스·포트를 점검하고 CPU/MEM/DISK 사용률을 monitor.log 에 기록합니다.

옵션
  --stats      실행 후 최근 통계(report.sh)를 함께 출력 (터미널에서 실행하면 기본)
  --no-stats   통계 출력 안 함 (cron 실행 시 기본)
  --quiet      경고·오류만 출력
  -h, --help   도움말

주요 환경변수 (기본값)
  AGENT_HOME=$AGENT_HOME  AGENT_PORT=$AGENT_PORT
  AGENT_LOG_DIR=$AGENT_LOG_DIR
  CPU_WARN=$CPU_WARN  MEM_WARN=$MEM_WARN  DISK_WARN=$DISK_WARN
  MAX_LOG_SIZE_BYTES=$MAX_LOG_SIZE_BYTES  MAX_LOG_FILES=$MAX_LOG_FILES

종료 코드: 0 정상(경고 포함) / 1 Health Check 실패 / 2 실행 환경 오류
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --stats) SHOW_STATS=1 ;;
        --no-stats) SHOW_STATS=0 ;;
        --quiet|-q) QUIET=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1 (--help 참고)" >&2; exit 2 ;;
    esac
    shift
done

# ---------------------------------------------------------------- 출력 도우미
say()   { [[ $QUIET -eq 1 ]] || printf '%s\n' "$*"; }
warn()  { printf '[WARNING] %s\n' "$*"; }
fail()  { printf '[ERROR] %s\n' "$*" >&2; }

is_number() { [[ "$1" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; }   # 임계값을 음수로 주면 항상 경고 (테스트용)
# 소수 비교는 bash 가 못 하므로 awk 로: gt 25.3 20 → 참이면 0
gt() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a > b) }'; }

for name in CPU_WARN MEM_WARN DISK_WARN; do
    if ! is_number "${!name}"; then
        fail "$name 값이 숫자가 아닙니다: ${!name}"
        exit 2
    fi
done
for name in AGENT_PORT MAX_LOG_SIZE_BYTES MAX_LOG_FILES; do
    if ! [[ "${!name}" =~ ^[1-9][0-9]*$ ]]; then
        fail "$name 값은 1 이상의 정수여야 합니다: ${!name}"
        exit 2
    fi
done
if (( MAX_LOG_FILES < 2 )); then
    fail "MAX_LOG_FILES 는 2 이상이어야 합니다 (현재 파일 + 순환 파일 1개 이상): $MAX_LOG_FILES"
    exit 2
fi

# ================================================================= 1. 프로세스
# 실행 파일 이름(argv[0] 또는 python 스크립트인 argv[1])의 basename 으로 판단한다.
# pgrep -f 'agent-app' 처럼 명령줄 전체를 검색하면 /home/agent-admin/agent-app/bin/monitor.sh
# (이 스크립트 자신)나 편집기·grep 까지 잡히기 때문이다.
find_app_pids() {
    local dir pid args exe script
    for dir in /proc/[0-9]*; do
        pid="${dir#/proc/}"
        [[ "$pid" == "$$" || "$pid" == "$PPID" ]] && continue
        [[ -r "$dir/cmdline" ]] || continue
        mapfile -d '' -t args < "$dir/cmdline" 2>/dev/null || continue
        [[ ${#args[@]} -gt 0 ]] || continue          # 커널 스레드는 cmdline 이 비어 있다
        exe="$(basename -- "${args[0]}")"
        script="$(basename -- "${args[1]:-x}")"
        [[ "$exe" == *.sh || "$script" == *.sh ]] && continue
        if [[ "$exe" =~ $APP_PROCESS_REGEX ]] || { [[ "$exe" == python* ]] && [[ "$script" =~ $APP_PROCESS_REGEX ]]; }; then
            if [[ -n "${APP_USER:-}" && "$(stat -c %U "$dir" 2>/dev/null)" != "$APP_USER" ]]; then
                continue                               # APP_USER 를 지정하면 그 계정의 프로세스만
            fi
            echo "$pid"
        fi
    done
}

# 포트를 LISTEN 중인지: ss(iproute2 — Ubuntu·RHEL 기본 포함)를 쓴다. netstat(net-tools)은 폐기 예정이라 22.04 기본 미설치. ss 도 없으면 /proc/net/tcp 를 직접 읽는다
port_listening() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        [[ -n "$(ss -Hltn "sport = :$port" 2>/dev/null)" ]]
        return
    fi
    local hex files=() f
    hex="$(printf '%04X' "$port")"
    for f in /proc/net/tcp /proc/net/tcp6; do [[ -r "$f" ]] && files+=("$f"); done   # IPv6 가 꺼진 환경 대비
    [[ ${#files[@]} -gt 0 ]] || return 1
    # local_address 컬럼 "00000000:3ABA", st 컬럼 0A = LISTEN
    awk -v p=":$hex" 'FNR > 1 && substr($2, length($2) - 4) == p && $4 == "0A" { found = 1 } END { exit !found }' "${files[@]}"
}

# 포트를 열고 있는 PID. PyInstaller 로 만든 실행 파일은 부트로더(부모)와 실제 앱(자식)이
# 같은 이름으로 두 개 뜨므로, 포트를 가진 쪽을 골라야 자원 수치가 실제 앱의 것이 된다.
#   1) ss -p 의 pid=  2) 없으면 /proc/net/tcp 의 소켓 inode 를 /proc/<pid>/fd 에서 찾는다
port_owner_pid() {
    local port="$1" hex inode pid
    shift
    if command -v ss >/dev/null 2>&1; then
        ss -Hltnp "sport = :$port" 2>/dev/null | grep -o 'pid=[0-9]*' | head -n 1 | cut -d= -f2
        return
    fi
    hex="$(printf '%04X' "$port")"
    inode="$(awk -v p=":$hex" 'FNR > 1 && substr($2, length($2) - 4) == p && $4 == "0A" { print $10; exit }' \
        /proc/net/tcp 2>/dev/null)"
    [[ -n "$inode" ]] || return 1
    local fd
    for pid in "$@"; do
        for fd in "/proc/$pid/fd/"*; do
            if [[ "$(readlink "$fd" 2>/dev/null)" == "socket:[$inode]" ]]; then
                echo "$pid"; return 0
            fi
        done
    done
    return 1
}

# 후보가 여럿인데 포트 주인을 모를 때: 후보 중 '부모도 후보인' 프로세스(= 자식, 실제 앱)를 고른다
pick_child_pid() {
    local pid ppid
    for pid in "$@"; do
        ppid="$(awk '{ print $4 }' "/proc/$pid/stat" 2>/dev/null)"
        if printf '%s\n' "$@" | grep -qx "$ppid"; then echo "$pid"; return 0; fi
    done
    echo "$1"
}

# ================================================================= 2. 방화벽
# 결과를 전역 변수 FW_STATE(active / inactive / unknown)와 FIREWALL_DETAIL(판단 근거)에 담는다.
# $(...) 로 부르면 서브셸이라 변수가 사라지므로 직접 호출한다.
FW_STATE="unknown"
FIREWALL_DETAIL=""
firewall_state() {
    local kind="$FIREWALL" out
    if [[ "$kind" == auto ]]; then
        if command -v ufw >/dev/null 2>&1 || [[ -f "$UFW_CONF" ]]; then kind=ufw
        elif command -v firewall-cmd >/dev/null 2>&1; then kind=firewalld
        else kind=none; fi
    fi
    case "$kind" in
        ufw)
            # ufw status 는 root 권한이 필요하다. cron 실행자(agent-admin)는 일반 계정이므로
            #   1) ufw status (root 로 실행한 경우)  2) sudo -n ufw status (sudoers 에 허용한 경우)
            #   3) /etc/ufw/ufw.conf 의 ENABLED=yes (누구나 읽을 수 있는 설정 파일) 순서로 확인한다.
            #   (UFW_USE_STATUS=0 이면 1·2 를 건너뛰고 설정 파일만 본다 — 테스트·sudo 금지 환경용)
            if [[ "$UFW_USE_STATUS" == 1 ]] && { out="$(ufw status 2>/dev/null)" || out="$(sudo -n ufw status 2>/dev/null)"; }; then
                FIREWALL_DETAIL="ufw status"
                if [[ "$out" == *"Status: active"* ]]; then FW_STATE=active; else FW_STATE=inactive; fi
            elif [[ -r "$UFW_CONF" ]]; then
                FIREWALL_DETAIL="$UFW_CONF"
                if grep -Eq '^[[:space:]]*ENABLED[[:space:]]*=[[:space:]]*yes' "$UFW_CONF"; then
                    FW_STATE=active
                else
                    FW_STATE=inactive
                fi
            else
                FIREWALL_DETAIL="ufw 상태를 확인할 권한이 없습니다"; FW_STATE=unknown
            fi ;;
        firewalld)
            FIREWALL_DETAIL="systemctl is-active firewalld"
            if [[ "$(systemctl is-active firewalld 2>/dev/null)" == active ]]; then FW_STATE=active; else FW_STATE=inactive; fi ;;
        *)
            FIREWALL_DETAIL="UFW/firewalld 를 찾지 못했습니다"; FW_STATE=unknown ;;
    esac
}

# ================================================================= 3. 자원 수집
# CPU: /proc/stat 의 누적 시간을 CPU_SAMPLE_SEC 간격으로 두 번 읽어 차이로 계산 (top 출력 파싱보다 정확·가벼움)
#   사용률 = 100 × (1 − Δidle / Δtotal),  idle = idle + iowait
read_cpu() { awk '/^cpu / { idle = $5 + $6; total = 0; for (i = 2; i <= NF; i++) total += $i; print idle, total }' /proc/stat; }
cpu_usage() {
    local i1 t1 i2 t2
    read -r i1 t1 < <(read_cpu)
    sleep "$CPU_SAMPLE_SEC"
    read -r i2 t2 < <(read_cpu)
    awk -v di=$((i2 - i1)) -v dt=$((t2 - t1)) 'BEGIN { printf "%.1f", (dt > 0) ? 100 * (1 - di / dt) : 0 }'
}

# MEM: (MemTotal − MemAvailable) / MemTotal. MemFree 가 아니라 MemAvailable 을 쓰는 이유는
#      페이지 캐시처럼 필요하면 바로 회수되는 메모리를 '사용 중' 으로 세지 않기 위해서다.
mem_usage() {
    awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "%.1f", (t > 0) ? 100 * (t - a) / t : 0 }' /proc/meminfo
}

# DISK: df -P 는 POSIX 형식(한 줄 고정)이라 장치 이름이 길어도 줄이 밀리지 않는다.
disk_usage() { df -P / | awk 'NR == 2 { gsub("%", "", $5); print $5 }'; }

# 프로세스 자원 (콘솔 표시 + extended 로그용): %MEM, RSS(MB), 스레드 수
proc_stats() { ps -o %mem=,rss=,nlwp= -p "$1" 2>/dev/null | awk '{ printf "%s %.1f %s", $1, $2 / 1024, $3 }'; }

# 프로세스가 지금까지 쓴 CPU 시간(utime + stime, 단위 clock tick).
# ps 의 %cpu 는 "시작 이후 평균" 이라 급등 순간을 놓치므로, 시스템 CPU 를 재는 같은 구간에서
# 이 값의 차이로 프로세스의 '순간' CPU 사용률을 계산한다. comm 에 공백이 있을 수 있어 ')' 뒤부터 센다.
proc_ticks() { awk '{ sub(/^.*\) /, ""); print $12 + $13 }' "/proc/$1/stat" 2>/dev/null; }
now_ns() { date +%s%N; }

# ================================================================= 5. 로그 순환
# monitor.log 가 MAX_LOG_SIZE_BYTES 이상이면 .1 ~ .(MAX_LOG_FILES-1) 로 밀어내고 가장 오래된 파일을 버린다.
rotate_log() {
    local log="$1" size i keep=$((MAX_LOG_FILES - 1))
    [[ -f "$log" ]] || return 0
    size="$(stat -c %s "$log" 2>/dev/null || wc -c < "$log")"
    (( size >= MAX_LOG_SIZE_BYTES )) || return 0
    rm -f -- "$log.$keep"
    for (( i = keep - 1; i >= 1; i-- )); do
        [[ -f "$log.$i" ]] && mv -f -- "$log.$i" "$log.$((i + 1))"
    done
    mv -f -- "$log" "$log.1"
    : > "$log"
    chmod 0660 "$log" 2>/dev/null || true
    say "[INFO] Log rotated: $log ($size bytes ≥ $MAX_LOG_SIZE_BYTES) → $log.1 (최대 ${MAX_LOG_FILES}개 유지)"
}

# ================================================================= 실행
main() {
    # 0) 로그 위치 확인: 쓸 수 없으면 관제 자체가 의미 없으므로 바로 알린다
    if [[ ! -d "$AGENT_LOG_DIR" ]]; then
        fail "로그 디렉토리가 없습니다: $AGENT_LOG_DIR (setup/04-directories.sh 로 생성)"
        exit 2
    fi
    if [[ ! -w "$AGENT_LOG_DIR" ]]; then
        fail "로그 디렉토리에 쓸 권한이 없습니다: $AGENT_LOG_DIR (현재 사용자: $(id -un), agent-core 그룹 필요)"
        exit 2
    fi

    # 같은 순간에 두 번 실행(cron + 수동)되어도 로그 순환이 꼬이지 않도록 잠금 (flock: 끝나면 fd 가 닫혀 자동 해제)
    exec 9>>"$AGENT_LOG_DIR/.monitor.lock"
    if command -v flock >/dev/null 2>&1 && ! flock -w 10 9; then
        fail "다른 monitor.sh 가 실행 중입니다 (잠금 대기 10초 초과)"
        exit 2
    fi

    say "====== SYSTEM MONITOR RESULT ======"
    say ""
    say "[HEALTH CHECK]"

    # 1) 프로세스
    local pids pid owner
    mapfile -t pids < <(find_app_pids)
    if [[ ${#pids[@]} -eq 0 ]]; then
        say "Checking process '$APP_PROCESS_LABEL'... [FAIL]"
        fail "앱 프로세스가 실행 중이 아닙니다 (패턴: $APP_PROCESS_REGEX)"
        notify CRITICAL "앱 프로세스가 실행 중이 아닙니다 (패턴: $APP_PROCESS_REGEX)"; hint_recovery process; exit 1
    fi
    pid="$(pick_child_pid "${pids[@]}")"
    owner="$(port_owner_pid "$AGENT_PORT" "${pids[@]}" || true)"
    if [[ -n "$owner" ]] && printf '%s\n' "${pids[@]}" | grep -qx "$owner"; then
        pid="$owner"
    fi
    say "Checking process '$APP_PROCESS_LABEL'... [OK] (PID: $pid)"

    # 2) 포트
    if ! port_listening "$AGENT_PORT"; then
        say "Checking port $AGENT_PORT... [FAIL]"
        fail "TCP $AGENT_PORT 포트가 LISTEN 상태가 아닙니다 (프로세스는 PID $pid 로 실행 중)"
        notify CRITICAL "TCP $AGENT_PORT 포트가 LISTEN 상태가 아닙니다 (프로세스는 PID $pid 로 실행 중)"; hint_recovery port; exit 1
    fi
    say "Checking port $AGENT_PORT... [OK]"

    # 3) 방화벽 (경고만)
    local fw warnings=()
    firewall_state
    fw="$FW_STATE"
    case "$fw" in
        active) say "Checking firewall... [OK] (active)" ;;
        inactive) say "Checking firewall... [WARN] (inactive)"; warnings+=("Firewall is inactive ($FIREWALL_DETAIL)") ;;
        *) say "Checking firewall... [WARN] (unknown)"; warnings+=("Firewall status unknown: $FIREWALL_DETAIL") ;;
    esac

    # 4) 자원
    local cpu mem disk pstat p_cpu p_mem p_rss p_thr
    local tick0 tick1 ns0 ns1 hz
    hz="$(getconf CLK_TCK 2>/dev/null || echo 100)"
    tick0="$(proc_ticks "$pid")"; ns0="$(now_ns)"
    cpu="$(cpu_usage)"                                   # CPU_SAMPLE_SEC 동안 대기하며 측정
    tick1="$(proc_ticks "$pid")"; ns1="$(now_ns)"
    p_cpu="$(awk -v a="${tick0:-0}" -v b="${tick1:-0}" -v hz="$hz" -v t0="$ns0" -v t1="$ns1" \
        'BEGIN { dt = (t1 - t0) / 1e9; printf "%.1f", (dt > 0 && b >= a) ? 100 * (b - a) / hz / dt : 0 }')"
    mem="$(mem_usage)"
    disk="$(disk_usage)"
    pstat="$(proc_stats "$pid")"
    read -r p_mem p_rss p_thr <<< "${pstat:-0 0 0}"

    say ""
    say "[RESOURCE MONITORING]"
    say "CPU Usage : ${cpu}%"
    say "MEM Usage : ${mem}%"
    say "DISK Used : ${disk}%"
    say "Process   : PID $pid CPU ${p_cpu}% MEM ${p_mem}% RSS ${p_rss}MB Threads ${p_thr}"

    gt "$cpu" "$CPU_WARN"   && warnings+=("CPU threshold exceeded (${cpu}% > ${CPU_WARN}%)")
    gt "$mem" "$MEM_WARN"   && warnings+=("MEM threshold exceeded (${mem}% > ${MEM_WARN}%)")
    gt "$disk" "$DISK_WARN" && warnings+=("DISK threshold exceeded (${disk}% > ${DISK_WARN}%)")

    if [[ ${#warnings[@]} -gt 0 ]]; then
        say ""
        local w
        for w in "${warnings[@]}"; do warn "$w"; notify WARNING "$w"; done
    fi

    # 5) 로그 기록 (>> : 기존 내용 뒤에 덧붙임. > 를 쓰면 매분 이전 기록이 지워진다. 동시 실행은 위 flock 이 직렬화)
    rotate_log "$MONITOR_LOG"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] PID:$pid CPU:${cpu}% MEM:${mem}% DISK_USED:${disk}%"
    if [[ "$MONITOR_LOG_FORMAT" == extended ]]; then
        line+=" P_CPU:${p_cpu}% P_MEM:${p_mem}% RSS:${p_rss}MB THREADS:${p_thr} FIREWALL:${fw}"
    fi
    if ! printf '%s\n' "$line" >> "$MONITOR_LOG"; then
        fail "로그를 기록하지 못했습니다: $MONITOR_LOG"
        exit 2
    fi

    # 터미널에서 실행하면 최근 통계를 함께 보여준다 (cron 에서는 출력하지 않음)
    if [[ "$SHOW_STATS" == 1 || ( "$SHOW_STATS" == auto && -t 1 ) ]] && [[ $QUIET -eq 0 && -x "$SCRIPT_DIR/report.sh" ]]; then
        say ""
        "$SCRIPT_DIR/report.sh" --file "$MONITOR_LOG" --last 10 || true
    fi

    say ""
    say "[INFO] Log appended: $MONITOR_LOG"
    return 0
}

# ================================================================= 알림 훅 (선택 기능)
# 경고·장애 때 "$ALERT_CMD LEVEL MESSAGE" 를 실행한다 (LEVEL = WARNING | CRITICAL).
#   예) /etc/agent-app/agent-app.env 에 ALERT_CMD=/home/agent-admin/agent-app/bin/alert.sh
# 선택 기능이라 본문(1~5단계) 흐름과 분리해 여기에 둔다. main 을 부르기 전에 정의되므로 동작은 같다.
# 실행 파일(x 권한)이 지정됐을 때만 동작하고, 훅이 느리거나 실패해도 관제 결과(종료 코드·로그)는
# 바뀌지 않도록 timeout 10초와 || true 로 감싼다.
ALERT_CMD="${ALERT_CMD:-}"
notify() {
    local level="$1" msg="$2"
    [[ -n "$ALERT_CMD" && -x "$ALERT_CMD" ]] || return 0
    if command -v timeout >/dev/null; then
        timeout 10 "$ALERT_CMD" "$level" "$msg" >/dev/null 2>&1
    else
        "$ALERT_CMD" "$level" "$msg" >/dev/null 2>&1
    fi || true
}

# Health Check 실패 시 다음에 볼 곳을 stderr 에 안내한다 (cron 실행이면 cron.log 에 함께 남는다).
# [HINT] 로 시작해 [ERROR] 줄과 구분된다 (verify/check-cron.sh 는 [HINT] 줄을 건너뛰고 오류를 찾는다).
hint_recovery() {
    local out="$AGENT_LOG_DIR/agent-app.out"
    case "$1" in
        process)
            printf '[HINT] 앱 출력·종료 원인: tail -n 30 %s (부트 단계별 실패는 docs/operations.md §12)\n' "$out" >&2
            printf '[HINT] 재기동: sudo -iu agent-admin %s/bin/run-agent.sh --background\n' "$AGENT_HOME" >&2 ;;
        port)
            printf '[HINT] 원인 진단: %s/diagnose-port.sh %s (바인딩 주소·포트 충돌·방화벽 8단계)\n' "$SCRIPT_DIR" "$AGENT_PORT" >&2
            printf "[HINT] 바인딩 오류 로그: grep -iE 'already in use|permission denied|bind|fail' %s\n" "$out" >&2 ;;
    esac
}

main "$@"
