#!/usr/bin/env bash
# =============================================================================
#  log-retention.sh — [보너스 2] 시간 기반 로그 보존 정책
#
#    1) 압축   : /var/log/agent-app/ 의 *.log, *.log.N 중 7일 이상 지난 파일을 gzip
#    2) 아카이브: 압축 파일을 /var/log/monitor/agent-app/archive/ 로 이동
#    3) 삭제   : archive/*.gz 중 30일 이상 지난 파일 삭제
#
#  용량 기반 순환(monitor.sh, 10MB×10개)은 "갑자기 로그가 늘 때 디스크를 지키는 장치"이고,
#  이 스크립트는 "오래된 로그를 싸게 보관했다가 기간이 지나면 지우는 장치"다. 둘은 함께 쓴다.
#
#  안전장치
#    - 디렉토리가 없으면 경고 후 정상 종료 (보존할 대상이 없을 뿐 오류가 아님)
#    - 권한이 없으면 무엇을 못 했는지 알리고 종료 코드 1
#    - 대상 0개면 "대상 없음" 출력 후 정상 종료
#    - gzip 무결성 검사(gzip -t)를 통과한 경우에만 원본을 지운다
#    - --dry-run 으로 실제 변경 없이 대상만 확인
#
#  find -mtime +N 은 "N×24시간을 넘게(N+1일 이상) 지난 파일" 이다.
#  그래서 "7일 이상" 은 -mtime +6, "30일 이상" 은 -mtime +29 로 쓴다.
# =============================================================================
set -uo pipefail
export LC_ALL=C

SRC_DIR="${SRC_DIR:-${AGENT_LOG_DIR:-/var/log/agent-app}}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/var/log/monitor/agent-app/archive}"
COMPRESS_AFTER_DAYS="${COMPRESS_AFTER_DAYS:-7}"
DELETE_AFTER_DAYS="${DELETE_AFTER_DAYS:-30}"
DRY_RUN=0

usage() {
    cat <<EOF
사용법: $(basename "$0") [--dry-run] [--help]

  ${COMPRESS_AFTER_DAYS}일 이상 지난 $SRC_DIR/*.log(.N) 를 압축해 $ARCHIVE_DIR 로 옮기고,
  ${DELETE_AFTER_DAYS}일 이상 지난 아카이브(*.gz)를 삭제합니다.

  --dry-run   실제로 바꾸지 않고 대상만 출력
환경변수: SRC_DIR, ARCHIVE_DIR, COMPRESS_AFTER_DAYS, DELETE_AFTER_DAYS
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run|-n) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "[ERROR] 알 수 없는 옵션: $1 (--help 참고)" >&2; exit 2 ;;
    esac
    shift
done

for name in COMPRESS_AFTER_DAYS DELETE_AFTER_DAYS; do
    if ! [[ "${!name}" =~ ^[0-9]+$ ]] || (( ${!name} < 1 )); then
        echo "[ERROR] $name 는 1 이상의 정수여야 합니다: ${!name}" >&2
        exit 2
    fi
done

log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
prefix=""
[[ $DRY_RUN -eq 1 ]] && prefix="(dry-run) "
errors=0
compressed=0
deleted=0

# ------------------------------------------------------------------ 1+2. 압축 → 아카이브
if [[ ! -d "$SRC_DIR" ]]; then
    log "[WARN] 원본 로그 디렉토리가 없습니다: $SRC_DIR — 압축 단계를 건너뜁니다"
else
    if [[ ! -d "$ARCHIVE_DIR" ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            log "${prefix}[INFO] 아카이브 디렉토리를 만들 예정: $ARCHIVE_DIR"
        elif ! mkdir -p -- "$ARCHIVE_DIR" 2>/dev/null; then
            log "[ERROR] 아카이브 디렉토리를 만들 수 없습니다(권한 확인): $ARCHIVE_DIR"
            exit 1
        fi
    fi
    if [[ -d "$ARCHIVE_DIR" && ! -w "$ARCHIVE_DIR" ]]; then
        log "[ERROR] 아카이브 디렉토리에 쓸 권한이 없습니다: $ARCHIVE_DIR (현재 사용자: $(id -un))"
        exit 1
    fi

    mapfile -d '' -t targets < <(find "$SRC_DIR" -maxdepth 1 -type f \
        \( -name '*.log' -o -name '*.log.[0-9]*' \) ! -name '*.gz' \
        -mtime +"$((COMPRESS_AFTER_DAYS - 1))" -print0 2>/dev/null)
    if [[ ${#targets[@]} -eq 0 ]]; then
        log "[INFO] 압축 대상 없음 (${COMPRESS_AFTER_DAYS}일 이상 지난 로그가 없습니다: $SRC_DIR)"
    fi
    for file in "${targets[@]}"; do
        stamp="$(date -r "$file" '+%Y%m%d')"
        dest="$ARCHIVE_DIR/$(basename -- "$file").$stamp.gz"
        [[ -e "$dest" ]] && dest="$ARCHIVE_DIR/$(basename -- "$file").$stamp-$(date '+%H%M%S').gz"
        if [[ $DRY_RUN -eq 1 ]]; then
            log "${prefix}[COMPRESS] $file → $dest"
            compressed=$((compressed + 1))
            continue
        fi
        if [[ ! -r "$file" ]]; then
            log "[ERROR] 읽을 권한이 없습니다: $file"
            errors=$((errors + 1)); continue
        fi
        # 임시 이름으로 압축 → 무결성 검사 → 최종 이름으로 이동 → 원본 삭제 (중간에 실패해도 원본 보존)
        tmp="$dest.part"
        if gzip -c -- "$file" > "$tmp" 2>/dev/null && gzip -t -- "$tmp" 2>/dev/null; then
            touch -r "$file" "$tmp"                  # 아카이브의 '경과 일수' 를 원본 기준으로 유지
            mv -f -- "$tmp" "$dest"
            if rm -f -- "$file" 2>/dev/null && [[ ! -e "$file" ]]; then
                log "[COMPRESS] $file → $dest"
                compressed=$((compressed + 1))
            else
                log "[ERROR] 압축은 했지만 원본을 지울 권한이 없습니다: $file"
                errors=$((errors + 1))
            fi
        else
            rm -f -- "$tmp"
            log "[ERROR] 압축 실패: $file"
            errors=$((errors + 1))
        fi
    done
fi

# ------------------------------------------------------------------ 3. 오래된 아카이브 삭제
if [[ ! -d "$ARCHIVE_DIR" ]]; then
    log "[WARN] 아카이브 디렉토리가 없습니다: $ARCHIVE_DIR — 삭제 단계를 건너뜁니다"
else
    mapfile -d '' -t old < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.gz' \
        -mtime +"$((DELETE_AFTER_DAYS - 1))" -print0 2>/dev/null)
    if [[ ${#old[@]} -eq 0 ]]; then
        log "[INFO] 삭제 대상 없음 (${DELETE_AFTER_DAYS}일 이상 지난 아카이브가 없습니다)"
    fi
    for file in "${old[@]}"; do
        if [[ $DRY_RUN -eq 1 ]]; then
            log "${prefix}[DELETE] $file"
            deleted=$((deleted + 1))
        elif rm -f -- "$file" 2>/dev/null && [[ ! -e "$file" ]]; then
            log "[DELETE] $file"
            deleted=$((deleted + 1))
        else
            log "[ERROR] 삭제 권한이 없습니다: $file"
            errors=$((errors + 1))
        fi
    done
fi

log "${prefix}[DONE] compressed=$compressed deleted=$deleted errors=$errors"
[[ $errors -eq 0 ]]
