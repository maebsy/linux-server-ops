#!/usr/bin/env bash
# monitor.sh(필수)와 report.sh·log-retention.sh(보너스), 운영 도구 alert.sh·diagnose-port.sh 를 $AGENT_HOME/bin 에 설치한다.
#
#   소유자 agent-dev (작성자) : 그룹 agent-core : 권한 750 (rwxr-x---)
#     agent-dev   → rwx : 수정·실행
#     agent-admin → r-x : agent-core 그룹이라 읽고 실행 가능 (cron 실행자). 수정은 불가
#     agent-test  → --- : 그룹 밖이라 내용도 볼 수 없다
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root
id agent-dev >/dev/null 2>&1 || [[ "$DRY_RUN" == 1 ]] || die "먼저 setup/03-accounts.sh 를 실행하세요"

for script in monitor.sh report.sh log-retention.sh run-agent.sh alert.sh diagnose-port.sh; do
    run install -o agent-dev -g agent-core -m 0750 "$REPO_DIR/bin/$script" "$AGENT_HOME/bin/$script"
done

# 로그 파일을 미리 만들어 두면 첫 기록 전에도 권한을 확인할 수 있다 (그룹 쓰기 가능)
run install -o agent-admin -g agent-core -m 0660 /dev/null "$AGENT_LOG_DIR/monitor.log.tmp"
[[ -e "$AGENT_LOG_DIR/monitor.log" ]] || run mv "$AGENT_LOG_DIR/monitor.log.tmp" "$AGENT_LOG_DIR/monitor.log"
run rm -f "$AGENT_LOG_DIR/monitor.log.tmp"

echo
info "확인"
[[ "$DRY_RUN" == 1 ]] || ls -l "$AGENT_HOME/bin/"
info "용량 관리: monitor.sh 가 기록 직전에 10MB 이상이면 monitor.log.1~.9 로 순환합니다 (최대 10개)."
info "logrotate 를 쓰고 싶다면 config/logrotate.d/agent-app 참고 (두 방식을 동시에 쓰지 마세요)."
