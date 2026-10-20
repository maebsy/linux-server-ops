#!/usr/bin/env bash
# =============================================================================
#  remote-check.sh — 서버 "밖"(다른 PC)에서 SSH·방화벽 설정이 실제로 동작하는지 확인
#
#    bash verify/remote-check.sh <서버 주소> [접속 계정] [--blocked-port N]
#    예) bash verify/remote-check.sh 192.168.56.10 agent-admin --blocked-port 8080 \
#          | tee docs/evidence/13-remote-check.txt
#
#  collect-evidence.sh 는 서버 안에서 설정 "값"을 보여 주고, 이 스크립트는 바깥에서 본 "결과"를 남긴다.
#    - 20022/tcp, 15034/tcp 는 열려 있고 22/tcp 는 닫혀 있는가
#    - --blocked-port: 서버에서 프로그램이 LISTEN 중이어도 방화벽이 막는가 (허용 목록 밖 포트)
#    - ssh -p 20022 <계정> 은 되고, root 는 같은 방법으로도 거부되는가
#  SSH 는 키 인증(BatchMode)으로 시도한다. 비밀번호를 묻지 않고, 실패하면 바로 이유를 출력한다.
# =============================================================================
set -uo pipefail
HOST="${1:?사용법: $0 <서버 주소> [접속 계정] [--blocked-port N]}"
USER_NAME="agent-admin"
BLOCKED=""
shift
while [[ $# -gt 0 ]]; do
    case "$1" in
        --blocked-port) BLOCKED="${2:?--blocked-port 에 포트 번호가 필요합니다}"; shift 2 ;;
        *) USER_NAME="$1"; shift ;;
    esac
done
SSH_PORT="${SSH_PORT:-20022}"
APP_PORT="${AGENT_PORT:-15034}"
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new)

echo "# 원격 점검: $(hostname) → $HOST"
echo "# 수집: $(date '+%Y-%m-%d %H:%M:%S %Z')"
echo

# TCP 연결 시도: 연결됨 / 거부(RST, 포트 닫힘) / 시간 초과(방화벽이 버림)
probe() {
    local port="$1" out rc
    out="$(timeout 4 bash -c "exec 3<>/dev/tcp/$HOST/$port" 2>&1)"; rc=$?
    if [[ $rc -eq 0 ]]; then echo "open"
    elif [[ $rc -eq 124 ]]; then echo "timeout (응답 없음 — 방화벽 DROP)"
    elif [[ "$out" == *refused* ]]; then echo "refused (닫힌 포트)"
    else echo "fail ($out)"; fi
}

echo "## 1. 포트 (기대: 20022·15034 만 open)"
printf '%-7s %-13s %s\n' "PORT" "SERVICE" "RESULT"
printf '%-7s %-13s %s\n' "$SSH_PORT" "sshd" "$(probe "$SSH_PORT")"
printf '%-7s %-13s %s\n' "$APP_PORT" "agent-app" "$(probe "$APP_PORT")"
printf '%-7s %-13s %s\n' "22" "ssh(default)" "$(probe 22)"
[[ -n "$BLOCKED" ]] && printf '%-7s %-13s %s\n' "$BLOCKED" "not-allowed" "$(probe "$BLOCKED")"
echo

echo "## 2. SSH 접속"
echo "\$ ssh -p $SSH_PORT $USER_NAME@$HOST 'id; hostname'"
ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "$USER_NAME@$HOST" 'id; hostname' 2>&1; echo "(exit code: $?)"
echo
echo "\$ ssh -p $SSH_PORT root@$HOST 'id'     # PermitRootLogin no → 키가 있어도 거부되어야 함"
ssh "${SSH_OPTS[@]}" -p "$SSH_PORT" "root@$HOST" 'id' 2>&1; echo "(exit code: $?)"
echo
echo "\$ ssh -p 22 $USER_NAME@$HOST 'id'      # 22 는 닫혀 있어야 함"
ssh "${SSH_OPTS[@]}" -p 22 "$USER_NAME@$HOST" 'id' 2>&1; echo "(exit code: $?)"
