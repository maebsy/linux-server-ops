#!/usr/bin/env bash
# =============================================================================
#  collect-evidence.sh — 요구사항 수행 내역서(docs/report.md)의 증빙을 한 번에 수집
#
#    sudo bash verify/collect-evidence.sh            # 결과: docs/evidence/NN-*.txt
#    sudo bash verify/collect-evidence.sh --no-wait  # cron 누적 확인(70초 대기) 생략
#
#  각 파일 첫머리에 수집 시각·호스트·실행 명령이 남는다. 스크린샷이 필요한 항목은
#  터미널에서 'cat docs/evidence/NN-*.txt' 를 띄워 캡처하면 된다.
#  앱이 실행 중이어야 06~09 항목이 정상으로 나온다:
#    sudo -iu agent-admin /home/agent-admin/agent-app/bin/run-agent.sh --background
# =============================================================================
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/docs/evidence"
AGENT_ENV_FILE="${AGENT_ENV_FILE:-/etc/agent-app/agent-app.env}"
# shellcheck disable=SC1090
[[ -r "$AGENT_ENV_FILE" ]] && source "$AGENT_ENV_FILE"
AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/var/log/monitor/agent-app/archive}"
SSH_PORT="${SSH_PORT:-20022}"
WAIT=1
[[ "${1:-}" == "--no-wait" ]] && WAIT=0

if [[ "$(id -u)" -ne 0 ]]; then
    echo "[ERROR] 설정 파일과 다른 계정의 권한을 확인해야 해서 root 가 필요합니다: sudo bash $0" >&2
    exit 1
fi
mkdir -p "$OUT"

# 파일 하나 = 증빙 하나. 명령을 그대로 보여준 뒤 실행 결과를 남긴다.
current=""
begin() {
    current="$OUT/$1.txt"
    {
        echo "# $2"
        echo "# 수집: $(date '+%Y-%m-%d %H:%M:%S %Z') · 호스트: $(hostname) · $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-linux}")"
        echo
    } > "$current"
    echo "[$1] $2"
}
cmd() {
    { echo "\$ $*"; bash -c "$*" 2>&1; echo; } >> "$current"
}
note() { echo "$*" >> "$current"; }

as() { sudo -u "$1" -- bash -c "$2" >/dev/null 2>&1 && echo "O" || echo "X"; }

# ------------------------------------------------------------------ 01 SSH
begin 01-ssh "SSH 포트 20022, Root 원격 로그인 차단"
cmd "cat /etc/ssh/sshd_config.d/00-agent-hardening.conf"
cmd "grep -nE '^[#[:space:]]*(Port|PermitRootLogin)' /etc/ssh/sshd_config"
note "## sshd 가 실제로 적용한 값 (sshd -T: 모든 설정 파일을 합친 최종 값)"
cmd "sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin) '"
note "## 포트 리슨 상태"
cmd "ss -tulnp | grep -E 'sshd|:$SSH_PORT\\b'"

# ------------------------------------------------------------------ 02 방화벽
begin 02-firewall "방화벽 활성화, 20022/tcp · 15034/tcp 만 허용"
if command -v ufw >/dev/null 2>&1; then
    cmd "ufw status verbose"
    cmd "ufw status numbered"
else
    cmd "firewall-cmd --state"
    cmd "firewall-cmd --list-all"
fi

# ------------------------------------------------------------------ 03 계정/그룹
begin 03-accounts "계정 agent-admin/dev/test, 그룹 agent-common/core"
cmd "id agent-admin; id agent-dev; id agent-test"
cmd "getent group agent-common agent-core"

# ------------------------------------------------------------------ 04 디렉토리/권한/ACL
begin 04-permissions "디렉토리 구조, 소유자·권한, ACL, 계정별 접근 매트릭스"
cmd "ls -ld $(dirname "$AGENT_HOME") $AGENT_HOME $AGENT_HOME/upload_files $AGENT_HOME/api_keys $AGENT_HOME/bin $AGENT_LOG_DIR $ARCHIVE_DIR"
cmd "ls -l $AGENT_HOME/api_keys/"
cmd "getfacl -p $(dirname "$AGENT_HOME") $AGENT_HOME/upload_files $AGENT_HOME/api_keys $AGENT_LOG_DIR"
cmd "namei -l $AGENT_HOME/api_keys/t_secret.key"
note "## 계정별 실제 접근 테스트 (O = 가능, X = 불가) — sudo -u <계정> 으로 직접 시도한 결과"
{
    printf '%-38s %-12s %-12s %-12s  %s\n' "대상 (동작)" "agent-admin" "agent-dev" "agent-test" "기대값"
    row() {   # 설명 테스트명령 기대값
        printf '%-38s %-12s %-12s %-12s  %s\n' "$1" "$(as agent-admin "$2")" "$(as agent-dev "$2")" "$(as agent-test "$2")" "$3"
    }
    row "upload_files 쓰기"             "f=$AGENT_HOME/upload_files/.probe.\$\$; touch \$f && rm -f \$f" "O O O"
    row "api_keys/t_secret.key 읽기"    "cat $AGENT_HOME/api_keys/t_secret.key"                       "O O X"
    row "api_keys 쓰기"                 "f=$AGENT_HOME/api_keys/.probe.\$\$; touch \$f && rm -f \$f"     "O O X"
    row "/var/log/agent-app 쓰기"       "f=$AGENT_LOG_DIR/.probe.\$\$; touch \$f && rm -f \$f"           "O O X"
    row "monitor.sh 실행 권한(x)"       "test -x $AGENT_HOME/bin/monitor.sh"                           "O O X"
    row "monitor.sh 수정(w)"            "test -w $AGENT_HOME/bin/monitor.sh"                           "X O X"
} >> "$current"
note ""

# ------------------------------------------------------------------ 05 환경변수
begin 05-environment "환경변수 AGENT_HOME / PORT / UPLOAD_DIR / KEY_PATH / LOG_DIR"
cmd "cat $AGENT_ENV_FILE"
cmd "sudo -iu agent-admin bash -lc 'env | grep ^AGENT_ | sort'"
cmd "ls -l $AGENT_HOME/api_keys/ && cat $AGENT_HOME/api_keys/t_secret.key"

# ------------------------------------------------------------------ 06 Boot Sequence
begin 06-boot "앱 Boot Sequence 5단계 [OK] + Agent READY, 0.0.0.0:15034 LISTEN"
if [[ -s "$AGENT_LOG_DIR/agent-app.out" ]]; then
    cmd "head -n 30 $AGENT_LOG_DIR/agent-app.out"
else
    note "(백그라운드 실행 기록이 없습니다. 포그라운드 실행 화면을 캡처하세요: sudo -iu agent-admin $AGENT_HOME/bin/run-agent.sh)"
fi
cmd "ps -eo user,pid,ppid,etime,cmd | grep -E '[a]gent[-_]app'"
cmd "ss -tlnp | grep ':$AGENT_PORT\\b'"

# ------------------------------------------------------------------ 07 monitor.sh 실행
begin 07-monitor "monitor.sh 실행 결과 (agent-admin, 프로세스·포트·리소스·경고)"
cmd "ls -l $AGENT_HOME/bin/monitor.sh"
cmd "sudo -u agent-admin env AGENT_ENV_FILE=$AGENT_ENV_FILE $AGENT_HOME/bin/monitor.sh --stats; echo \"(exit code: \$?)\""

# ------------------------------------------------------------------ 08 monitor.log
begin 08-monitor-log "monitor.log 누적 기록 (최근 라인)"
cmd "ls -l $AGENT_LOG_DIR/"
cmd "tail -n 10 $AGENT_LOG_DIR/monitor.log"

# ------------------------------------------------------------------ 09 cron
begin 09-cron "agent-admin crontab 매분 등록, 1분 후 로그 증가"
cmd "crontab -u agent-admin -l"
cmd "systemctl is-active cron 2>/dev/null || systemctl is-active crond"
if [[ $WAIT -eq 1 ]]; then
    before="$(wc -l < "$AGENT_LOG_DIR/monitor.log")"
    note "## $(date '+%H:%M:%S') monitor.log ${before}줄 → 70초 대기"
    echo "    (cron 실행을 기다리는 중: 70초)"
    sleep 70
    after="$(wc -l < "$AGENT_LOG_DIR/monitor.log")"
    note "## $(date '+%H:%M:%S') monitor.log ${after}줄 (증가: $((after - before))줄)"
    cmd "tail -n 3 $AGENT_LOG_DIR/monitor.log"
fi
cmd "grep CRON /var/log/syslog 2>/dev/null | grep agent-admin | tail -n 3"

# ------------------------------------------------------------------ 10 용량 관리
begin 10-log-capacity "monitor.log 용량 관리 (10MB / 10개 파일)"
cmd "grep -nE '^(MAX_LOG_SIZE_BYTES|MAX_LOG_FILES)=' $AGENT_HOME/bin/monitor.sh"
note "## 시연: 한도를 200바이트·4개로 줄인 임시 로그에 6번 실행 → 파일 수가 4개로 유지되는지"
demo="$(sudo -u agent-admin mktemp -d)"
cmd "sudo -u agent-admin env AGENT_ENV_FILE=$AGENT_ENV_FILE MONITOR_LOG=$demo/monitor.log MAX_LOG_SIZE_BYTES=200 MAX_LOG_FILES=4 bash -c 'for i in 1 2 3 4 5 6; do printf \"%0300d\" 0 > \$MONITOR_LOG; $AGENT_HOME/bin/monitor.sh --no-stats --quiet; done'; ls -l $demo"
rm -rf "$demo"

# ------------------------------------------------------------------ 11~12 보너스
begin 11-report "[보너스 1] report.sh 요약 리포트"
cmd "sudo -u agent-admin $AGENT_HOME/bin/report.sh --file $AGENT_LOG_DIR/monitor.log"
first="$(head -n 1 "$AGENT_LOG_DIR/monitor.log" | cut -c2-20)"
last="$(tail -n 1 "$AGENT_LOG_DIR/monitor.log" | cut -c2-20)"
[[ -n "$first" ]] && cmd "sudo -u agent-admin $AGENT_HOME/bin/report.sh --file $AGENT_LOG_DIR/monitor.log --from '$first' --to '$last'"

begin 12-retention "[보너스 2] 로그 보존 정책 (dry-run + 설정)"
cmd "sudo -u agent-admin $AGENT_HOME/bin/log-retention.sh --dry-run"
cmd "ls -ld $ARCHIVE_DIR; ls -l $ARCHIVE_DIR"

echo
echo "[DONE] $OUT 에 증빙을 저장했습니다. docs/report.md 의 체크리스트와 함께 커밋하세요."
