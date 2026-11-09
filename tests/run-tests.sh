#!/usr/bin/env bash
# monitor.sh / report.sh / log-retention.sh 자동 테스트 (root 권한·실제 서버 설정 불필요)
#
#   bash tests/run-tests.sh
#
# 임시 폴더를 AGENT_HOME / AGENT_LOG_DIR 로 쓰고, 가짜 앱(tests/fake_agent_app.py)을
# agent_app.py 라는 이름으로 띄워 실제와 같은 조건에서 스크립트를 실행한다.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d -t lso-test-XXXXXX)"
PORT="${TEST_PORT:-$(( 20000 + RANDOM % 20000 ))}"
PASS=0; FAIL=0; APP_PID=""

cleanup() {
    [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null
    [[ -n "${HTTP_PID:-}" ]] && kill "$HTTP_PID" 2>/dev/null
    rm -rf "$TMP"
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  {
    FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'
    # GitHub Actions 에서는 실패 항목을 주석(annotation)으로도 남겨 로그를 열지 않아도 보이게 한다
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        local detail="${2:-}"; detail="${detail//'%'/'%25'}"; detail="${detail//$'\n'/'%0A'}"
        printf '::error title=test failed::%s%%0A%s\n' "$1" "${detail:0:3000}"
    fi
    return 0
}
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "${OUT:-}"; fi; }
section() { printf '\n[%s]\n' "$1"; }

export AGENT_HOME="$TMP/agent-app" AGENT_LOG_DIR="$TMP/log" AGENT_PORT="$PORT"
export AGENT_ENV_FILE="$TMP/none.env" CPU_SAMPLE_SEC=0.2 FIREWALL=ufw UFW_CONF="$TMP/ufw.conf" UFW_USE_STATUS=0
mkdir -p "$AGENT_HOME/bin" "$AGENT_LOG_DIR"
echo "ENABLED=yes" > "$UFW_CONF"
cp "$ROOT/bin/"*.sh "$AGENT_HOME/bin/"
chmod 750 "$AGENT_HOME/bin/"*.sh
MON="$AGENT_HOME/bin/monitor.sh"
REPORT="$AGENT_HOME/bin/report.sh"
RET="$AGENT_HOME/bin/log-retention.sh"
cp "$ROOT/tests/fake_agent_app.py" "$TMP/agent_app.py"

start_app() { python3 "$TMP/agent_app.py" "$@" >/dev/null 2>&1 & APP_PID=$!; sleep 0.7; }
stop_app()  { [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""; }
run_mon()   { OUT="$("$MON" --no-stats 2>&1)"; CODE=$?; }
LOG_RE='^\[[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\] PID:[0-9]+ CPU:[0-9]+\.[0-9]% MEM:[0-9]+\.[0-9]% DISK_USED:[0-9]+%$'

section "문법 검사"
for f in "$ROOT"/bin/*.sh "$ROOT"/setup/*.sh "$ROOT"/verify/*.sh; do
    [[ -f "$f" ]] || continue
    check "bash -n $(basename "$f")" bash -n "$f"
done
if command -v shellcheck >/dev/null 2>&1; then
    OUT="$(shellcheck -S warning "$ROOT"/bin/*.sh "$ROOT"/setup/*.sh "$ROOT"/verify/*.sh 2>&1)"
    check "shellcheck (warning 이상 없음)" test -z "$OUT"
fi

section "monitor.sh: 정상 상태"
start_app "$PORT"
run_mon
check "종료 코드 0" test "$CODE" -eq 0
check "프로세스 OK + PID 표시" grep -q "Checking process 'agent-app'... \[OK\] (PID: $APP_PID)" <<< "$OUT"
check "포트 OK" grep -q "Checking port $PORT... \[OK\]" <<< "$OUT"
check "CPU/MEM/DISK 출력" grep -Eq 'CPU Usage : [0-9.]+%' <<< "$OUT"
check "monitor.log 에 1줄 기록" test "$(wc -l < "$AGENT_LOG_DIR/monitor.log")" -eq 1
check "로그 포맷 [YYYY-MM-DD HH:MM:SS] PID CPU MEM DISK_USED" grep -Eq "$LOG_RE" "$AGENT_LOG_DIR/monitor.log"
check "로그의 PID 가 앱 PID" grep -q "PID:$APP_PID " "$AGENT_LOG_DIR/monitor.log"
run_mon
check "두 번째 실행은 덧붙이기(>>)로 2줄" test "$(wc -l < "$AGENT_LOG_DIR/monitor.log")" -eq 2

section "monitor.sh: 임계값 경고 (종료하지 않음)"
OUT="$(CPU_WARN=-1 MEM_WARN=-1 DISK_WARN=-1 "$MON" --no-stats 2>&1)"; CODE=$?
check "경고가 있어도 종료 코드 0" test "$CODE" -eq 0
check "CPU 경고" grep -q '\[WARNING\] CPU threshold exceeded' <<< "$OUT"
check "MEM 경고" grep -q '\[WARNING\] MEM threshold exceeded' <<< "$OUT"
check "DISK 경고" grep -q '\[WARNING\] DISK threshold exceeded' <<< "$OUT"
OUT="$(CPU_WARN=1000 MEM_WARN=1000 DISK_WARN=1000 "$MON" --no-stats 2>&1)"
check "임계값 미만이면 경고 없음" bash -c '! grep -q WARNING <<< "$1"' _ "$OUT"

section "monitor.sh: 방화벽 비활성 → 경고만"
echo "ENABLED=no" > "$UFW_CONF"
run_mon
check "종료 코드 0" test "$CODE" -eq 0
check "[WARNING] Firewall is inactive" grep -q '\[WARNING\] Firewall is inactive' <<< "$OUT"
echo "ENABLED=yes" > "$UFW_CONF"

section "monitor.sh: extended 로그 형식 (B4-2 재사용)"
OUT="$(MONITOR_LOG="$TMP/ext.log" MONITOR_LOG_FORMAT=extended "$MON" --no-stats 2>&1)"
check "프로세스 RSS·스레드 필드 추가" grep -Eq 'P_CPU:[0-9.]+% P_MEM:[0-9.]+% RSS:[0-9.]+MB THREADS:[0-9]+ FIREWALL:active$' "$TMP/ext.log"

section "monitor.sh: 프로세스 순간 CPU (ps 평균이 아니라 측정 구간의 사용률)"
stop_app
start_app "$PORT" --busy
sleep 1
OUT="$(MONITOR_LOG="$TMP/busy.log" MONITOR_LOG_FORMAT=extended CPU_SAMPLE_SEC=1 "$MON" --no-stats 2>&1)"
pcpu="$(grep -o 'P_CPU:[0-9.]*' "$TMP/busy.log" | cut -d: -f2)"
check "CPU 를 계속 쓰는 프로세스는 P_CPU ≥ 50% (측정값: ${pcpu:-없음}%)" awk -v v="${pcpu:-0}" 'BEGIN { exit !(v >= 50) }'
stop_app
start_app "$PORT"

section "monitor.sh: Health Check 실패"
stop_app
before="$(wc -l < "$AGENT_LOG_DIR/monitor.log")"
run_mon
check "프로세스 없음 → 종료 코드 1" test "$CODE" -eq 1
check "프로세스 FAIL 표시" grep -q "Checking process 'agent-app'... \[FAIL\]" <<< "$OUT"
check "실패 시 monitor.log 에 기록하지 않음" test "$(wc -l < "$AGENT_LOG_DIR/monitor.log")" -eq "$before"
check "프로세스 없음 → 복구 안내([HINT] 앱 출력 로그·재기동)" bash -c 'grep -q "^\[HINT\] 앱 출력" <<< "$1" && grep -q "^\[HINT\] 재기동" <<< "$1"' _ "$OUT"
start_app "$PORT" --no-listen
run_mon
check "프로세스는 있는데 포트 없음 → 종료 코드 1" test "$CODE" -eq 1
check "포트 FAIL 표시" grep -q "Checking port $PORT... \[FAIL\]" <<< "$OUT"
check "포트 없음 → 복구 안내([HINT] diagnose-port.sh·바인딩 오류 로그)" bash -c 'grep -q "^\[HINT\] 원인 진단: .*diagnose-port.sh $2" <<< "$1" && grep -q "^\[HINT\] 바인딩 오류 로그" <<< "$1"' _ "$OUT" "$PORT"
stop_app
OUT="$(bash -c 'exec -a /tmp/agent-app/bin/monitor.sh sleep 5' & sleep 0.3; "$MON" --no-stats 2>&1)"; CODE=$?
check "이름에 agent-app 이 들어간 다른 프로세스(*.sh)는 앱으로 보지 않음" test "$CODE" -eq 1

section "monitor.sh: 실행 환경 오류"
OUT="$(AGENT_LOG_DIR="$TMP/no-such-dir" "$MON" --no-stats 2>&1)"; CODE=$?
check "로그 디렉토리 없음 → 종료 코드 2" test "$CODE" -eq 2
OUT="$(CPU_WARN=abc "$MON" --no-stats 2>&1)"; CODE=$?
check "잘못된 임계값 → 종료 코드 2" test "$CODE" -eq 2
if [[ "$(id -u)" -ne 0 ]]; then
    mkdir -p "$TMP/ro" && chmod 555 "$TMP/ro"
    OUT="$(AGENT_LOG_DIR="$TMP/ro" "$MON" --no-stats 2>&1)"; CODE=$?
    check "로그 디렉토리 쓰기 불가 → 종료 코드 2" test "$CODE" -eq 2
fi

section "monitor.sh: 용량 기반 순환 (MAX_LOG_SIZE_BYTES/MAX_LOG_FILES)"
start_app "$PORT"
export MONITOR_LOG="$TMP/rot/monitor.log"
mkdir -p "$TMP/rot"
for _ in 1 2 3 4 5 6; do
    head -c 300 /dev/zero | tr '\0' 'x' > "$MONITOR_LOG"    # 300바이트 > 한도 200
    MAX_LOG_SIZE_BYTES=200 MAX_LOG_FILES=4 "$MON" --no-stats >/dev/null 2>&1
done
rotated=("$TMP/rot"/monitor.log*)
count="${#rotated[@]}"
check "파일 수 상한 유지 (monitor.log + .1~.3 = 4개)" test "$count" -eq 4
check "가장 오래된 파일(.4)은 삭제됨" test ! -e "$MONITOR_LOG.4"
check "순환 직후 새 monitor.log 는 1줄" test "$(wc -l < "$MONITOR_LOG")" -eq 1
unset MONITOR_LOG
stop_app

section "report.sh: 통계 (보너스 1)"
cat > "$TMP/sample.log" <<'LOG'
[2026-02-25 13:58:01] PID:48291 CPU:10.2% MEM:3.2% DISK_USED:23%
[2026-02-25 13:59:01] PID:48291 CPU:18.7% MEM:5.0% DISK_USED:23%
[2026-02-25 14:00:01] PID:48291 CPU:25.3% MEM:9.8% DISK_USED:24%
이 줄은 형식이 달라 제외된다
[2026-02-25 14:01:01] PID:48291 CPU:31.4% MEM:6.1% DISK_USED:24% P_CPU:3.0% P_MEM:1.0% RSS:20.0MB THREADS:3 FIREWALL:active
LOG
OUT="$("$REPORT" --file "$TMP/sample.log" 2>&1)"; CODE=$?
check "종료 코드 0" test "$CODE" -eq 0
check "CPU 평균 21.4%" grep -q 'Average : 21.4%' <<< "$OUT"
check "CPU 최대 31.4% + 시각" grep -q 'Maximum : 31.4% at 2026-02-25 14:01:01' <<< "$OUT"
check "CPU 최소 10.2% + 시각" grep -q 'Minimum : 10.2% at 2026-02-25 13:58:01' <<< "$OUT"
check "메모리 최대 9.8%" grep -q 'Maximum : 9.8% at 2026-02-25 14:00:01' <<< "$OUT"
check "샘플 수 4 (형식 다른 줄 제외)" grep -q 'Data Points: 4 samples' <<< "$OUT"
OUT="$("$REPORT" --file "$TMP/sample.log" --from "2026-02-25 13:59:00" --to "2026-02-25 14:00:59" 2>&1)"
check "--from/--to 구간 필터 (2개)" grep -q 'Data Points: 2 samples' <<< "$OUT"
check "구간 CPU 평균 22.0%" grep -q 'Average : 22.0%' <<< "$OUT"
OUT="$("$REPORT" --file "$TMP/sample.log" --last 1 2>&1)"
check "--last 1" grep -q 'Data Points: 1 samples' <<< "$OUT"
OUT="$("$REPORT" --file "$TMP/sample.log" --from "2030-01-01" 2>&1)"; CODE=$?
check "구간에 샘플 없음 → 안내 + 종료 코드 1" bash -c '[[ $1 -eq 1 ]] && grep -q "No samples" <<< "$2"' _ "$CODE" "$OUT"
OUT="$("$REPORT" --file "$TMP/sample.log" --from "25/02/2026" 2>&1)"; CODE=$?
check "잘못된 시각 형식 → 종료 코드 2" test "$CODE" -eq 2
cp "$TMP/sample.log" "$TMP/r.log.1"; head -n 1 "$TMP/sample.log" > "$TMP/r.log"
OUT="$("$REPORT" --file "$TMP/r.log" --include-rotated 2>&1)"
check "--include-rotated: 순환 파일까지 5개" grep -q 'Data Points: 5 samples' <<< "$OUT"

section "log-retention.sh: 압축·아카이브·삭제 (보너스 2)"
export SRC_DIR="$TMP/ret/src" ARCHIVE_DIR="$TMP/ret/archive"
mkdir -p "$SRC_DIR"
echo old > "$SRC_DIR/old.log";            touch -d '8 days ago' "$SRC_DIR/old.log"
echo old > "$SRC_DIR/monitor.log.3";      touch -d '10 days ago' "$SRC_DIR/monitor.log.3"
echo new > "$SRC_DIR/monitor.log";        touch -d '1 day ago' "$SRC_DIR/monitor.log"
echo edge > "$SRC_DIR/edge.log";          touch -d '6 days ago' "$SRC_DIR/edge.log"
OUT="$("$RET" --dry-run 2>&1)"; CODE=$?
check "dry-run: 종료 코드 0" test "$CODE" -eq 0
check "dry-run: 대상 2개 표시" grep -q 'compressed=2' <<< "$OUT"
check "dry-run: 실제 변경 없음" test -e "$SRC_DIR/old.log" -a ! -d "$ARCHIVE_DIR"
OUT="$("$RET" 2>&1)"; CODE=$?
check "실행: 종료 코드 0" test "$CODE" -eq 0
check "7일 이상 지난 로그 압축·이동" bash -c 'ls "$1"/old.log.*.gz >/dev/null 2>&1 && ls "$1"/monitor.log.3.*.gz >/dev/null 2>&1' _ "$ARCHIVE_DIR"
check "원본 삭제" test ! -e "$SRC_DIR/old.log"
check "최근 로그(1일, 6일)는 유지" test -e "$SRC_DIR/monitor.log" -a -e "$SRC_DIR/edge.log"
check "압축 파일 무결성" bash -c 'gzip -t "$1"/*.gz' _ "$ARCHIVE_DIR"
check "아카이브는 원본 수정 시각 유지" test -n "$(find "$ARCHIVE_DIR" -name 'old.log.*.gz' -mtime +6)"
echo x | gzip > "$ARCHIVE_DIR/ancient.log.20250101.gz"; touch -d '31 days ago' "$ARCHIVE_DIR/ancient.log.20250101.gz"
echo x | gzip > "$ARCHIVE_DIR/recent.log.20250101.gz"; touch -d '29 days ago' "$ARCHIVE_DIR/recent.log.20250101.gz"
OUT="$("$RET" 2>&1)"
check "30일 이상 지난 아카이브 삭제" test ! -e "$ARCHIVE_DIR/ancient.log.20250101.gz"
check "29일 된 아카이브는 유지" test -e "$ARCHIVE_DIR/recent.log.20250101.gz"
check "대상 없을 때 안내" grep -q '압축 대상 없음' <<< "$OUT"
OUT="$(SRC_DIR="$TMP/nope" ARCHIVE_DIR="$TMP/nope2" "$RET" 2>&1)"; CODE=$?
check "디렉토리 없음 → 경고 후 정상 종료" bash -c '[[ $1 -eq 0 ]] && grep -q "\[WARN\]" <<< "$2"' _ "$CODE" "$OUT"

section "diagnose-port.sh"
DIAG="$AGENT_HOME/bin/diagnose-port.sh"
HTTP_PID=""
run_diag() { OUT="$(UFW_USER_RULES="$TMP/user.rules" "$DIAG" "$@" 2>&1)"; CODE=$?; }

# a) 앱이 PORT 를 열고 있고 ufw user.rules 에 허용 규칙이 있으면 모두 정상
printf -- '-A ufw-user-input -p tcp --dport %s -j ACCEPT\n' "$PORT" > "$TMP/user.rules"
start_app "$PORT"
run_diag "$PORT"
check "a) 정상 → 종료 코드 0" test "$CODE" -eq 0
check "a) 2단계 포트 LISTEN OK" grep -Eq '\[2/8\].*\[OK\]' <<< "$OUT"
check "a) 8단계 방화벽 허용 OK" grep -Eq '\[8/8\].*\[OK\]' <<< "$OUT"

# b) 같은 앱, user.rules 가 비어 있으면 방화벽 단계는 WARN (그래도 FAIL 아님)
: > "$TMP/user.rules"
run_diag "$PORT"
check "b) 허용 규칙 없어도 종료 코드 0" test "$CODE" -eq 0
check "b) 8단계 방화벽 WARN" grep -Eq '\[8/8\].*\[WARN\]' <<< "$OUT"
stop_app

# d) 루프백에만 바인딩 → 2단계 WARN(루프백)
start_app "$PORT" --bind 127.0.0.1
run_diag "$PORT"
check "d) 2단계 루프백 WARN" bash -c 'grep -Eq "\[2/8\].*\[WARN\]" <<< "$1" && grep -q "루프백" <<< "$1"' _ "$OUT"
stop_app

# e) 앱이 PORT+1 을 열고 있는데 PORT 를 진단 → 3단계에서 실제 포트(PORT+1)를 지목
start_app "$((PORT + 1))"
run_diag "$PORT"
check "e) 포트 불일치 → 종료 코드 1" test "$CODE" -eq 1
check "e) 3단계가 실제 포트 $((PORT + 1)) 지목" grep -Eq "\[3/8\].*$((PORT + 1))" <<< "$OUT"
stop_app

# c) --no-listen 으로 포트를 안 연 앱 → 2단계 FAIL
start_app "$PORT" --no-listen
run_diag "$PORT"
check "c) 포트 미개방 → 종료 코드 1" test "$CODE" -eq 1
check "c) 2단계 포트 LISTEN FAIL" grep -Eq '\[2/8\].*\[FAIL\]' <<< "$OUT"

# f) 앱은 포트를 안 열고(--no-listen) 다른 프로세스가 PORT 를 점유 → 4단계 포트 충돌 FAIL
python3 -m http.server "$PORT" --bind 127.0.0.1 >/dev/null 2>&1 & HTTP_PID=$!
sleep 0.7
run_diag "$PORT"
check "f) 포트 충돌 → 종료 코드 1" test "$CODE" -eq 1
check "f) 4단계 포트 충돌 FAIL" grep -Eq '\[4/8\].*\[FAIL\]' <<< "$OUT"
kill "$HTTP_PID" 2>/dev/null; wait "$HTTP_PID" 2>/dev/null; HTTP_PID=""
stop_app

# g) 숫자가 아닌 포트 → 사용법 오류(종료 코드 2)
run_diag abc
check "g) 잘못된 포트 → 종료 코드 2" test "$CODE" -eq 2

section "check-cron.sh: cron ↔ syslog ↔ monitor.log 연동 점검"
CC="$ROOT/verify/check-cron.sh"
CD="$TMP/cron"; mkdir -p "$CD"
MLINE='* * * * * /x/monitor.sh --no-stats --quiet >> /x/cron.log 2>&1'
printf '%s\n' "$MLINE" > "$CD/crontab.good"
printf '%s\n' '0 3 * * * /x/other.sh' > "$CD/crontab.bad"
printf '%s host CRON[123]: (agent-admin) CMD (%s)\n' "$(LC_ALL=C date '+%b %e %H:%M:%S')" "/x/monitor.sh --no-stats --quiet >> /x/cron.log 2>&1" > "$CD/syslog.fresh"
printf '%s host CRON[123]: (agent-admin) CMD (%s)\n' "$(date -Iseconds)" "/x/monitor.sh --no-stats --quiet >> /x/cron.log 2>&1" > "$CD/syslog.rfc"
printf '[%s] PID:1 CPU:1.0%% MEM:1.0%% DISK_USED:1%%\n' "$(date '+%F %T')" > "$CD/monitor.fresh"
printf '[%s] PID:1 CPU:1.0%% MEM:1.0%% DISK_USED:1%%\n' "$(date -d '10 minutes ago' '+%F %T')" > "$CD/monitor.stale"
: > "$CD/cron.empty"
printf '[ERROR] 앱 프로세스가 실행 중이 아닙니다\n' > "$CD/cron.err"
printf '[ERROR] 앱 프로세스가 실행 중이 아닙니다\n[HINT] 앱 출력·종료 원인: ...\n[HINT] 재기동: ...\n' > "$CD/cron.hint"
cc_run() { OUT="$(SKIP_SERVICE=1 SKIP_SUDO=1 CRON_USER=agent-admin \
    CRONTAB_FILE="$1" SYSLOG_FILE="$2" MONITOR_LOG="$3" CRON_LOG="$4" MAX_AGE_MIN="${5:-3}" \
    bash "$CC" 2>&1)"; CODE=$?; }

cc_run "$CD/crontab.good" "$CD/syslog.fresh" "$CD/monitor.fresh" "$CD/cron.empty"
check "a) 정상 체인 → 종료 코드 0" test "$CODE" -eq 0
check "a) 결론 정상" grep -q '결론: 정상' <<< "$OUT"

cc_run "$CD/crontab.good" "$CD/syslog.fresh" "$CD/monitor.stale" "$CD/cron.empty"
check "b) monitor.log 오래됨 → 종료 코드 1" test "$CODE" -eq 1
check "b) 5단계 FAIL" grep -Eq '\[5/7\] monitor.log 갱신 \.\.\. \[FAIL\]' <<< "$OUT"

cc_run "$CD/crontab.bad" "$CD/syslog.fresh" "$CD/monitor.fresh" "$CD/cron.empty"
check "c) crontab 미등록 → 종료 코드 1" test "$CODE" -eq 1
check "c) 1단계 FAIL" grep -Eq '\[1/7\] crontab 등록 \.\.\. \[FAIL\]' <<< "$OUT"

cc_run "$CD/crontab.good" "$CD/syslog.fresh" "$CD/monitor.fresh" "$CD/cron.err"
check "d) cron.log 오류 → 종료 코드 1" test "$CODE" -eq 1
check "d) 6단계 FAIL" grep -Eq '\[6/7\] cron.log 오류 \.\.\. \[FAIL\]' <<< "$OUT"
cc_run "$CD/crontab.good" "$CD/syslog.fresh" "$CD/monitor.fresh" "$CD/cron.hint"
check "d) 오류 뒤 [HINT] 줄이 붙어도 6단계 FAIL" grep -Eq '\[6/7\] cron.log 오류 \.\.\. \[FAIL\] \[ERROR\]' <<< "$OUT"

cc_run "$CD/crontab.good" "$CD/syslog.rfc" "$CD/monitor.fresh" "$CD/cron.empty"
check "e) RFC3339 syslog 파싱 → 4단계 OK" grep -Eq '\[4/7\] syslog 의 CRON 실행 기록 \.\.\. \[OK\]' <<< "$OUT"

OUT="$(SKIP_SERVICE=1 SKIP_SUDO=1 bash "$CC" --max-age abc 2>&1)"; CODE=$?
check "f) --max-age abc → 종료 코드 2" test "$CODE" -eq 2

# 7단계: cron 과 같은 최소 환경(env -i)에서 env 파일 로드
cc_env() { local f="$1"; shift; OUT="$(AGENT_ENV_FILE="$f" SKIP_SERVICE=1 SKIP_SUDO=1 CRON_USER=agent-admin \
    CRONTAB_FILE="$CD/crontab.good" SYSLOG_FILE="$CD/syslog.fresh" MONITOR_LOG="$CD/monitor.fresh" CRON_LOG="$CD/cron.empty" \
    "$@" bash "$CC" 2>&1)"; CODE=$?; }
cc_env "$TMP/none.env" env
check "g) env 파일 없음 → 7단계 WARN" grep -Eq '\[7/7\] cron 환경의 env 로드 \.\.\. \[WARN\]' <<< "$OUT"
check "g) WARN 만이면 종료 코드 0" test "$CODE" -eq 0
printf 'AGENT_PORT=%s\nAGENT_LOG_DIR=%s\n' "$PORT" "$AGENT_LOG_DIR" > "$CD/good.env"
cc_env "$CD/good.env" env
check "h) env 로드 성공 → 7단계 OK + 값 표시" grep -Eq "\[7/7\] cron 환경의 env 로드 \.\.\. \[OK\] .*AGENT_PORT=$PORT" <<< "$OUT"
check "h) 종료 코드 0" test "$CODE" -eq 0
printf 'AGENT_PORT=(\n' > "$CD/broken.env"
cc_env "$CD/broken.env" env
check "i) 문법 오류 env → 7단계 FAIL, 종료 코드 1" bash -c '[[ $1 -eq 1 ]] && grep -Eq "\[7/7\].*\[FAIL\]" <<< "$2"' _ "$CODE" "$OUT"
# 점검하는 셸에 export 된 값이 env 파일의 기본값 문법(${AGENT_PORT:-...})을 덮으면 cron 과 값이 달라진다
printf 'AGENT_PORT="${AGENT_PORT:-15034}"\n' > "$CD/default.env"
cc_env "$CD/default.env" env AGENT_PORT="$PORT"
check "j) 셸 export 값과 cron 값 불일치 → 7단계 FAIL" grep -Eq '\[7/7\].*\[FAIL\] cron 환경 AGENT_PORT=15034' <<< "$OUT"
if [[ "$(id -u)" -ne 0 ]]; then
    cp "$CD/good.env" "$CD/locked.env"; chmod 000 "$CD/locked.env"
    cc_env "$CD/locked.env" env
    check "k) 읽을 수 없는 env → 7단계 FAIL" grep -Eq '\[7/7\].*\[FAIL\] .*읽을 수 없습니다' <<< "$OUT"
    chmod 600 "$CD/locked.env"
fi

section "알림 훅"
ALERT="$AGENT_HOME/bin/alert.sh"
# 가짜 알림 훅: 받은 "LEVEL MESSAGE" 를 "LEVEL|MESSAGE" 한 줄로 기록한다
cat > "$TMP/fake-alert.sh" <<EOF
#!/usr/bin/env bash
printf '%s|%s\n' "\$1" "\$2" >> "$TMP/alerts.txt"
EOF
chmod +x "$TMP/fake-alert.sh"

# (1) 임계값 경고 발생 → WARNING 알림 (monitor 종료 코드는 0 유지)
start_app "$PORT"
: > "$TMP/alerts.txt"
OUT="$(ALERT_CMD="$TMP/fake-alert.sh" CPU_WARN=-1 "$MON" --no-stats 2>&1)"; CODE=$?
check "경고 시 monitor 종료 코드 0" test "$CODE" -eq 0
check "WARNING 알림 전달" grep -q '^WARNING|CPU threshold exceeded' "$TMP/alerts.txt"

# (2) Health Check 실패 → CRITICAL 알림 (종료 코드 1 유지)
stop_app
: > "$TMP/alerts.txt"
OUT="$(ALERT_CMD="$TMP/fake-alert.sh" "$MON" --no-stats 2>&1)"; CODE=$?
check "장애 시 monitor 종료 코드 1" test "$CODE" -eq 1
check "CRITICAL 알림 전달" grep -q '^CRITICAL|' "$TMP/alerts.txt"

# (3) ALERT_CMD 미설정 → 동작 불변 (종료 코드·로그 포맷 그대로)
start_app "$PORT"
run_mon
check "ALERT_CMD 없이 종료 코드 0" test "$CODE" -eq 0
check "ALERT_CMD 없이 로그 포맷 정상" grep -Eq "$LOG_RE" "$AGENT_LOG_DIR/monitor.log"
stop_app

# (4) alert.sh 직접: 쿨다운(중복 억제)
rm -rf "$TMP/st"; : > "$TMP/a.log"
al() { ALERT_LOGGER=0 ALERT_LOG_FILE="$TMP/a.log" ALERT_STATE_DIR="$TMP/st" "$ALERT" "$@"; }
al WARNING "CPU threshold exceeded (32.3% > 20%)"
al WARNING "CPU threshold exceeded (40.1% > 20%)"
check "쿨다운: 숫자만 다른 같은 경고는 1줄" test "$(wc -l < "$TMP/a.log")" -eq 1
al CRITICAL "앱 프로세스가 실행 중이 아닙니다"
check "다른 종류 경고는 추가 전송 → 2줄" test "$(wc -l < "$TMP/a.log")" -eq 2
ALERT_COOLDOWN_SEC=0 ALERT_LOGGER=0 ALERT_LOG_FILE="$TMP/a.log" ALERT_STATE_DIR="$TMP/st" \
    "$ALERT" WARNING "CPU threshold exceeded (55.0% > 20%)"
check "쿨다운 0 이면 재전송 → 3줄" test "$(wc -l < "$TMP/a.log")" -eq 3

printf '\n결과: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
