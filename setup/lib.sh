#!/usr/bin/env bash
# setup/*.sh 공용 함수. 직접 실행하지 않고 source 해서 쓴다.
#   DRY_RUN=1 이면 실제로 바꾸지 않고 실행할 명령만 출력한다.

# shellcheck disable=SC2034  # 아래 값은 source 한 스크립트에서 사용
AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
AGENT_PORT="${AGENT_PORT:-15034}"
AGENT_LOG_DIR="${AGENT_LOG_DIR:-/var/log/agent-app}"
SSH_PORT="${SSH_PORT:-20022}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/var/log/monitor/agent-app/archive}"
ENV_FILE="${ENV_FILE:-/etc/agent-app/agent-app.env}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DRY_RUN="${DRY_RUN:-0}"

info()  { printf '\033[36m[INFO]\033[0m %s\n' "$*"; }
ok()    { printf '\033[32m[ OK ]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
die()   { printf '\033[31m[FAIL]\033[0m %s\n' "$*" >&2; exit 1; }

# 명령을 보여주고 실행한다 (DRY_RUN=1 이면 보여주기만)
run() {
    printf '  $ %s\n' "$*"
    [[ "$DRY_RUN" == 1 ]] && return 0
    "$@"
}

require_root() {
    [[ "$DRY_RUN" == 1 ]] && return 0
    [[ "$(id -u)" -eq 0 ]] || die "root 권한이 필요합니다: sudo bash $0"
}

# 설정 파일을 바꾸기 전에 원본을 .bak.<시각> 으로 남긴다 (되돌리기용)
backup() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    run cp -a -- "$f" "$f.bak.$(date +%Y%m%d%H%M%S)"
}

need_cmd() {
    local cmd="$1" pkg="${2:-$1}"
    command -v "$cmd" >/dev/null 2>&1 && return 0
    info "$cmd 가 없어 $pkg 패키지를 설치합니다"
    if command -v apt-get >/dev/null 2>&1; then run apt-get install -y "$pkg"
    elif command -v dnf >/dev/null 2>&1; then run dnf install -y "$pkg"
    else die "$cmd 를 설치할 수 없습니다. 직접 설치하세요: $pkg"; fi
}
