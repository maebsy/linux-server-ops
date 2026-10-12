#!/usr/bin/env bash
# 앱 실행 환경변수를 한 파일에 고정하고, 로그인 셸과 cron 이 같은 값을 쓰게 한다.
#
#   /etc/agent-app/agent-app.env   KEY=VALUE 원본 (monitor.sh, run-agent.sh, cron 이 읽음)
#   /etc/profile.d/agent-app.sh    로그인 셸에서 위 파일을 export
#
# 왜 파일 하나로 모으나: 로그인 셸(.bashrc)과 cron(로그인 셸이 아님, 환경이 거의 비어 있음)이
# 서로 다른 값을 보면 "수동 실행은 되는데 cron 에서는 실패" 하는 전형적인 장애가 생긴다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root

content="# agent-app 실행 환경 (setup/05-environment.sh 가 생성)
AGENT_HOME=$AGENT_HOME
AGENT_PORT=$AGENT_PORT
AGENT_UPLOAD_DIR=$AGENT_HOME/upload_files
AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key
AGENT_LOG_DIR=$AGENT_LOG_DIR"

run install -d -o root -g root -m 0755 "$(dirname "$ENV_FILE")"
if [[ "$DRY_RUN" == 1 ]]; then
    printf '  $ cat > %s <<EOF\n%s\nEOF\n' "$ENV_FILE" "$content"
else
    printf '%s\n' "$content" > "$ENV_FILE"
    chmod 0644 "$ENV_FILE"        # 경로만 담겨 있고 비밀값은 없다 (키 내용은 api_keys 에만)
fi
run install -o root -g root -m 0644 "$REPO_DIR/config/profile.d/agent-app.sh" /etc/profile.d/agent-app.sh

echo
info "확인 (새 로그인 셸 기준)"
[[ "$DRY_RUN" == 1 ]] || sudo -iu agent-admin bash -lc 'env | grep ^AGENT_ | sort'
