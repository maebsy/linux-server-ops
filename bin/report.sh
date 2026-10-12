#!/usr/bin/env bash
# =============================================================================
#  report.sh — [보너스 1] monitor.log 요약 리포트
#
#  monitor.log 를 읽어 CPU / MEM / DISK 의 평균·최대·최소(발생 시각 포함)와 샘플 수를 출력한다.
#  시작/종료 시각을 주면 그 구간만 분석한다.
#
#    report.sh                                        # 전체
#    report.sh --from "2026-02-25 13:00:00" --to "2026-02-25 14:00:00"
#    report.sh --last 60                              # 최근 60개 샘플 (= 최근 1시간)
#    report.sh --include-rotated                      # monitor.log.1 ~ .9 까지 시간순으로 포함
#
#  시각은 "YYYY-MM-DD HH:MM:SS" 형식. 이 형식은 문자열 비교 순서와 시간 순서가 같아서
#  날짜 변환 없이 awk 문자열 비교만으로 구간을 거를 수 있다.
# =============================================================================
set -uo pipefail
export LC_ALL=C

AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
FILE="${MONITOR_LOG:-$AGENT_LOG_DIR/monitor.log}"
FROM=""
TO=""
LAST=0
ROTATED=0

usage() {
    cat <<EOF
사용법: $(basename "$0") [--file PATH] [--from "YYYY-MM-DD HH:MM:SS"] [--to "YYYY-MM-DD HH:MM:SS"]
                 [--last N] [--include-rotated]

  --file PATH         분석할 로그 (기본: $FILE)
  --from / --to       분석 구간 (포함). 날짜만 주면 00:00:00 / 23:59:59 로 간주
  --last N            조건을 만족하는 마지막 N개 샘플만
  --include-rotated   순환된 monitor.log.1 ~ .9 도 시간순으로 포함
EOF
}

valid_ts() { [[ "$1" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}( [0-9]{2}:[0-9]{2}:[0-9]{2})?$ ]]; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --file) FILE="${2:-}"; shift ;;
        --from) FROM="${2:-}"; shift ;;
        --to) TO="${2:-}"; shift ;;
        --last) LAST="${2:-}"; shift ;;
        --include-rotated) ROTATED=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1 (--help 참고)" >&2; exit 2 ;;
    esac
    shift
done

for ts_name in FROM TO; do
    value="${!ts_name}"
    if [[ -n "$value" ]] && ! valid_ts "$value"; then
        echo "[ERROR] --${ts_name,,} 형식이 올바르지 않습니다: '$value' (예: 2026-02-25 13:00:00)" >&2
        exit 2
    fi
done
[[ -n "$FROM" && ${#FROM} -eq 10 ]] && FROM="$FROM 00:00:00"
[[ -n "$TO" && ${#TO} -eq 10 ]] && TO="$TO 23:59:59"
if [[ -n "$FROM" && -n "$TO" && "$FROM" > "$TO" ]]; then
    echo "[ERROR] --from 이 --to 보다 늦습니다: $FROM > $TO" >&2
    exit 2
fi
if ! [[ "$LAST" =~ ^[0-9]+$ ]]; then
    echo "[ERROR] --last 는 0 이상의 정수여야 합니다: $LAST" >&2
    exit 2
fi
if [[ ! -r "$FILE" ]]; then
    echo "[ERROR] 로그 파일을 읽을 수 없습니다: $FILE" >&2
    exit 2
fi

# 순환된 파일은 숫자가 클수록 오래된 것: .9 → … → .1 → monitor.log 순서로 이어 붙인다
sources=()
if [[ $ROTATED -eq 1 ]]; then
    for i in 9 8 7 6 5 4 3 2 1; do
        [[ -r "$FILE.$i" ]] && sources+=("$FILE.$i")
    done
fi
sources+=("$FILE")

cat -- "${sources[@]}" | awk -v from="$FROM" -v to="$TO" -v last="$LAST" -v src="$FILE" '
# [2026-02-25 13:58:01] PID:48291 CPU:10.2% MEM:3.2% DISK_USED:23%   (뒤에 확장 필드가 있어도 됨)
match($0, /^\[[0-9-]+ [0-9:]+\] PID:[^ ]+ CPU:[0-9.]+% MEM:[0-9.]+% DISK_USED:[0-9]+%/) {
    ts = substr($0, 2, 19)
    if (from != "" && ts < from) next
    if (to != "" && ts > to) next
    split($0, f, " ")
    cpu = f[4]; sub(/^CPU:/, "", cpu); sub(/%$/, "", cpu)
    mem = f[5]; sub(/^MEM:/, "", mem); sub(/%$/, "", mem)
    dsk = f[6]; sub(/^DISK_USED:/, "", dsk); sub(/%$/, "", dsk)
    n++
    T[n] = ts; C[n] = cpu + 0; M[n] = mem + 0; D[n] = dsk + 0
    next
}
{ skipped++ }
function stat(label, V, unit,    i, start, sum, mx, mn, tmx, tmn, cnt) {
    start = (last > 0 && n > last) ? n - last + 1 : 1
    for (i = start; i <= n; i++) {
        cnt++; sum += V[i]
        if (cnt == 1 || V[i] > mx) { mx = V[i]; tmx = T[i] }
        if (cnt == 1 || V[i] < mn) { mn = V[i]; tmn = T[i] }
    }
    printf "[%s]\n", label
    printf "  Average : %.1f%s\n", sum / cnt, unit
    printf "  Maximum : %.1f%s at %s\n", mx, unit, tmx
    printf "  Minimum : %.1f%s at %s\n", mn, unit, tmn
}
END {
    print "====== STATISTICS REPORT ======"
    if (from != "" || to != "") printf "Range   : %s ~ %s\n", (from != "" ? from : "(start)"), (to != "" ? to : "(end)")
    if (n == 0) {
        print "No samples found" (from != "" || to != "" ? " in the given range" : "") "."
        exit 3
    }
    used = (last > 0 && n > last) ? last : n
    printf "Period  : %s ~ %s\n", T[n - used + 1], T[n]
    stat("CPU", C, "%")
    stat("Memory", M, "%")
    stat("Disk", D, "%")
    print "[Samples]"
    printf "  Data Points: %d samples\n", used
    if (skipped > 0) printf "  (형식이 다른 줄 %d개는 제외)\n", skipped
}'
status=$?
[[ $status -eq 3 ]] && exit 1   # 샘플 없음: 출력은 했지만 종료 코드는 1
exit "$status"
