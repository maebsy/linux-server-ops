# /etc/profile.d/agent-app.sh — 로그인 셸에서 agent-app 환경변수를 export 한다.
# 값은 /etc/agent-app/agent-app.env 한 곳에서만 관리한다.
if [ -r /etc/agent-app/agent-app.env ]; then
    set -a
    . /etc/agent-app/agent-app.env
    set +a
fi
