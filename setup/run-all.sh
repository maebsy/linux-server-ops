#!/usr/bin/env bash
# 전체 서버 구성을 순서대로 실행한다. 각 단계는 여러 번 실행해도 안전하다(멱등).
#
#   sudo bash setup/run-all.sh            # 실제 적용
#   DRY_RUN=1 bash setup/run-all.sh       # 실행할 명령만 미리 보기
#
# 순서 이유: 계정 → 디렉토리(계정 필요) → 환경변수 → 스크립트 설치(디렉토리 필요)
#            → 방화벽(20022 를 먼저 연다) → SSH 포트 변경(방화벽에 20022 가 있어야 안전) → cron
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
for step in 03-accounts 04-directories 05-environment 06-install-monitor 02-firewall 01-ssh 07-cron; do
    printf '\n\033[1m========== %s ==========\033[0m\n' "$step"
    bash "$DIR/$step.sh" "$@"
done
printf '\n다음 단계: agent-app.zip 을 %s 에 풀고\n' "${AGENT_HOME:-/home/agent-admin/agent-app}"
echo "  sudo -iu agent-admin ${AGENT_HOME:-/home/agent-admin/agent-app}/bin/run-agent.sh   # Boot Sequence 확인"
echo "  sudo bash verify/collect-evidence.sh                                                # 증빙 수집"
