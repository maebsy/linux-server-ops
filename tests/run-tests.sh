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

cleanup() { [[ -n "$APP_PID" ]] && kill "$APP_PID" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | sed 's/^/       | /'; }
check() { local name="$1"; shift; if "$@"; then ok "$name"; else bad "$name" "${OUT:-}"; fi; }
section() { printf '\n[%s]\n' "$1"; }

export AGENT_HOME="$TMP/agent-app" AGENT_LOG_DIR="$TMP/log" AGENT_PORT="$PORT"
export AGENT_ENV_FILE="$TMP/none.env" CPU_SAMPLE_SEC=0.2 FIREWALL=ufw UFW_CONF="$TMP/ufw.conf"
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

section "monitor.sh: Health Check 실패"
stop_app
before="$(wc -l < "$AGENT_LOG_DIR/monitor.log")"
run_mon
check "프로세스 없음 → 종료 코드 1" test "$CODE" -eq 1
check "프로세스 FAIL 표시" grep -q "Checking process 'agent-app'... \[FAIL\]" <<< "$OUT"
check "실패 시 monitor.log 에 기록하지 않음" test "$(wc -l < "$AGENT_LOG_DIR/monitor.log")" -eq "$before"
start_app "$PORT" --no-listen
run_mon
check "프로세스는 있는데 포트 없음 → 종료 코드 1" test "$CODE" -eq 1
check "포트 FAIL 표시" grep -q "Checking port $PORT... \[FAIL\]" <<< "$OUT"
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

printf '\n결과: %d passed, %d failed\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
