# 증빙 수집에 쓴 "서버" 환경: systemd 로 부팅하는 Ubuntu 22.04 (sshd · UFW · cron 이 실제 서비스로 동작)
#
#   docker build -t linux-server-ops-vm verify/container
#   docker network create opsnet
#   docker run -d --name agent-server --hostname agent-server --network opsnet \
#     --privileged --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock linux-server-ops-vm
#
# --privileged 는 systemd 와 UFW(iptables)를 컨테이너 안에서 쓰기 위해 필요하다. 방화벽 규칙은 컨테이너의
# 네트워크 네임스페이스에만 적용되어 호스트에는 영향이 없다. 자세한 절차: docs/evidence/README.md
# fail2ban 은 설치만 해 두고 꺼 둔다(선택 단계 setup/08-fail2ban.sh 가 켠다).
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive TZ=Asia/Seoul
RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv dbus openssh-server ufw cron sudo acl iproute2 procps \
      tzdata rsyslog less nano unzip file ca-certificates openssh-client python3 \
      logrotate fail2ban curl lsof \
    && ln -sf /usr/share/zoneinfo/Asia/Seoul /etc/localtime && echo Asia/Seoul > /etc/timezone \
    && rm -rf /var/lib/apt/lists/* \
    && systemctl enable ssh cron rsyslog && systemctl disable fail2ban \
    && rm -f /etc/ssh/ssh_host_* && ssh-keygen -A
STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
