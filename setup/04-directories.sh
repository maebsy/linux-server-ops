#!/usr/bin/env bash
# 디렉토리 구조, 소유자·권한, ACL, 키 파일을 만든다.
#
#   경로                                   소유자:그룹             권한   ACL
#   /home/agent-admin                      agent-admin:agent-admin  750   g:agent-common:--x (통과만, 목록 X)
#   $AGENT_HOME                            agent-admin:agent-common 750
#   $AGENT_HOME/upload_files   (공유)       agent-admin:agent-common 2770  g:agent-common:rwx + default
#   $AGENT_HOME/api_keys       (보안)       agent-admin:agent-core   2770  g:agent-core:rwx + default, other 없음
#   $AGENT_HOME/api_keys/t_secret.key      agent-admin:agent-core   640   (+ secret.key → t_secret.key 링크)
#   $AGENT_HOME/bin                        agent-dev:agent-core     2750  (dev 가 작성, admin 이 실행)
#   /var/log/agent-app         (보안)       agent-admin:agent-core   2770  g:agent-core:rwx + default
#   /var/log/monitor/agent-app/archive     agent-admin:agent-core   2770  (보너스: 로그 보존)
#
#   2xxx (setgid) : 디렉토리 안에 새로 만든 파일이 만든 사람의 기본 그룹이 아니라 디렉토리 그룹을 물려받는다
#   default ACL   : 새 파일에도 그룹 rw 가 자동으로 붙는다 (각자 umask 022 여도 협업 가능)
set -euo pipefail
source "$(dirname "$0")/lib.sh"
require_root
id agent-admin >/dev/null 2>&1 || [[ "$DRY_RUN" == 1 ]] || die "먼저 setup/03-accounts.sh 를 실행하세요"
need_cmd setfacl acl

mkdir_owned() {   # 경로 소유자 그룹 권한
    run install -d -o "$2" -g "$3" -m "$4" "$1"
}

ADMIN_HOME="$(dirname "$AGENT_HOME")"
info "AGENT_HOME=$AGENT_HOME"

# 홈 디렉토리는 Ubuntu 기본 750 이라 dev/test 는 그 아래로 '지나갈' 수도 없다.
# 홈 전체를 열지 않고 agent-common 에게 통과(x) 권한만 준다 → 목록은 못 보고 아는 경로로만 접근
run chmod 750 "$ADMIN_HOME"
run setfacl -m g:agent-common:--x "$ADMIN_HOME"

mkdir_owned "$AGENT_HOME"              agent-admin agent-common 0750
mkdir_owned "$AGENT_HOME/upload_files" agent-admin agent-common 2770
mkdir_owned "$AGENT_HOME/api_keys"     agent-admin agent-core   2770
mkdir_owned "$AGENT_HOME/bin"          agent-dev   agent-core   2750
mkdir_owned "$AGENT_LOG_DIR"           agent-admin agent-core   2770
mkdir_owned "$ARCHIVE_DIR"             agent-admin agent-core   2770

# ACL: 그룹 권한을 명시하고(default 포함), 그 외 사용자(other)는 아무 권한 없음
run setfacl -m  g:agent-common:rwx,o::--- "$AGENT_HOME/upload_files"
run setfacl -d -m g:agent-common:rwx,o::--- "$AGENT_HOME/upload_files"
for secure in "$AGENT_HOME/api_keys" "$AGENT_LOG_DIR" "$ARCHIVE_DIR"; do
    run setfacl -m  g:agent-core:rwx,o::--- "$secure"
    run setfacl -d -m g:agent-core:rwx,o::--- "$secure"
done

# 키 파일: 앱 Boot Sequence [3/5] 가 내용(agent_api_key_test)까지 검사한다
KEY_FILE="$AGENT_HOME/api_keys/t_secret.key"
if [[ "$DRY_RUN" == 1 ]]; then
    printf '  $ printf "agent_api_key_test\\n" > %s\n' "$KEY_FILE"
else
    printf 'agent_api_key_test\n' > "$KEY_FILE"
fi
run chown agent-admin:agent-core "$KEY_FILE"
run chmod 640 "$KEY_FILE"
# 제공 바이너리는 api_keys/secret.key 를 읽는다 (Boot [3/5] "Missing File: secret.key").
# 과제 명세의 t_secret.key 를 원본으로 두고 secret.key 는 심볼릭 링크로 연결해 값이 하나만 존재하게 한다.
run ln -sfn t_secret.key "$AGENT_HOME/api_keys/secret.key"
run chown -h agent-admin:agent-core "$AGENT_HOME/api_keys/secret.key"

echo
info "확인"
if [[ "$DRY_RUN" != 1 ]]; then
    ls -ld "$ADMIN_HOME" "$AGENT_HOME" "$AGENT_HOME"/{upload_files,api_keys,bin} "$AGENT_LOG_DIR" "$ARCHIVE_DIR"
    ls -l "$AGENT_HOME/api_keys/"
    getfacl -p "$AGENT_HOME/upload_files" "$AGENT_HOME/api_keys" "$AGENT_LOG_DIR" 2>/dev/null
fi
ok "디렉토리·권한·ACL 설정 완료 (권한 매트릭스는 verify/collect-evidence.sh 의 04 항목에서 계정별로 검증)"
