#!/usr/bin/env bash
# agent-admin 의 crontab 에 monitor.sh(매분)와 log-retention.sh(매일, 보너스)를 등록한다.
# 기존 crontab 의 다른 줄은 유지하고, 표시(--- agent-app monitoring ---) 구간만 교체한다.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root
need_cmd crontab cron

BLOCK="$(sed "s#/home/agent-admin/agent-app#$AGENT_HOME#g; s#/var/log/agent-app#$AGENT_LOG_DIR#g" \
    "$REPO_DIR/config/crontab.agent-admin")"
current="$(crontab -u agent-admin -l 2>/dev/null || true)"
others="$(printf '%s\n' "$current" | sed '/^# --- agent-app monitoring/,/^# --- end agent-app monitoring/d')"
new="$(printf '%s\n%s\n' "$others" "$BLOCK" | sed '/./,$!d')"

if [[ "$DRY_RUN" == 1 ]]; then
    printf '  $ crontab -u agent-admin - <<EOF\n%s\nEOF\n' "$new"
else
    printf '%s\n' "$new" | crontab -u agent-admin -
fi
run systemctl enable --now cron

echo
info "확인"
if [[ "$DRY_RUN" != 1 ]]; then
    crontab -u agent-admin -l
    before="$(wc -l < "$AGENT_LOG_DIR/monitor.log" 2>/dev/null || echo 0)"
    info "monitor.log 현재 ${before}줄. 1~2분 뒤 'wc -l $AGENT_LOG_DIR/monitor.log' 로 증가를 확인하세요."
    info "(앱이 실행 중이어야 기록됩니다: sudo -iu agent-admin $AGENT_HOME/bin/run-agent.sh --background)"
fi
