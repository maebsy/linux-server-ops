#!/usr/bin/env bash
# 제공 앱(agent-app)을 일반 계정으로 실행한다. root 로는 실행하지 않는다.
#
#   run-agent.sh                # 포그라운드 실행 → Boot Sequence 5단계와 "Agent READY" 확인 (Ctrl+C 종료)
#   run-agent.sh --background   # 백그라운드 실행, 출력은 $AGENT_LOG_DIR/agent-app.out
#   run-agent.sh --stop         # 백그라운드 앱 종료
#
# 실행 파일: $AGENT_APP_BIN 이 있으면 그것을, 없으면 CPU 에 맞춰 agent-app-linux-x86 / -arm64 를 찾는다.
set -uo pipefail
AGENT_ENV_FILE="${AGENT_ENV_FILE:-/etc/agent-app/agent-app.env}"
if [[ -r "$AGENT_ENV_FILE" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$AGENT_ENV_FILE"
    set +a
fi
: "${AGENT_HOME:?AGENT_HOME 이 없습니다 (setup/05-environment.sh 실행)}"
PID_FILE="${AGENT_LOG_DIR:-/var/log/agent-app}/agent-app.pid"

if [[ "$(id -u)" -eq 0 ]]; then
    echo "[ERROR] root 로 실행하지 마세요. 예: sudo -iu agent-admin $0" >&2
    exit 1
fi

if [[ "${1:-}" == "--stop" ]]; then
    if [[ -f "$PID_FILE" ]] && kill "$(cat "$PID_FILE")" 2>/dev/null; then
        echo "[INFO] 종료 신호를 보냈습니다 (PID $(cat "$PID_FILE"))"; rm -f "$PID_FILE"; exit 0
    fi
    echo "[WARN] 실행 중인 백그라운드 앱을 찾지 못했습니다"; exit 1
fi

case "$(uname -m)" in
    x86_64|amd64) default_bin="agent-app-linux-x86" ;;
    aarch64|arm64) default_bin="agent-app-linux-arm64" ;;
    *) default_bin="agent-app" ;;
esac
BIN="${AGENT_APP_BIN:-}"
if [[ -z "$BIN" ]]; then
    for candidate in "$AGENT_HOME/$default_bin" "$AGENT_HOME"/agent-app*/"$default_bin" "$AGENT_HOME/agent_app.py"; do
        [[ -e "$candidate" ]] && { BIN="$candidate"; break; }
    done
fi
[[ -n "$BIN" && -e "$BIN" ]] || { echo "[ERROR] 앱 실행 파일이 없습니다. agent-app.zip 을 $AGENT_HOME 에 풀었는지 확인하세요." >&2; exit 1; }
[[ "$BIN" == *.py ]] && CMD=(python3 "$BIN") || { chmod u+x "$BIN" 2>/dev/null; CMD=("$BIN"); }

cd "$AGENT_HOME" || exit 1
if [[ "${1:-}" == "--background" ]]; then
    nohup "${CMD[@]}" > "${AGENT_LOG_DIR:-/var/log/agent-app}/agent-app.out" 2>&1 &
    echo $! > "$PID_FILE"
    sleep 2
    echo "[INFO] 백그라운드 실행: PID $! (출력: ${AGENT_LOG_DIR:-/var/log/agent-app}/agent-app.out)"
    tail -n 20 "${AGENT_LOG_DIR:-/var/log/agent-app}/agent-app.out"
else
    exec "${CMD[@]}"
fi
