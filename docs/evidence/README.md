# evidence — 실제 수행 증빙

[`docs/report.md`](../report.md) 의 체크리스트가 가리키는 **실제 실행 결과**입니다. 파일마다 첫머리에 수집 시각 · 호스트 · 실행 명령이 있고, 그 아래는 명령의 출력 그대로입니다(색상 코드만 제거).

## 수행 환경

| 항목 | 값 |
| --- | --- |
| 서버 | Docker 컨테이너 `agent-server` — Ubuntu 22.04.5 LTS, systemd 부팅(sshd · UFW · cron · rsyslog 가 실제 서비스로 동작), [`verify/container/Dockerfile`](../../verify/container/Dockerfile) |
| 바깥 접속 점검 | 같은 Docker 네트워크의 두 번째 컨테이너 `ops-laptop` (서버 주소 `172.18.0.2`) |
| 호스트 | Ubuntu, Docker 29.9.1, 커널 7.0.0, 16 vCPU, 메모리 약 14.5GB |
| 앱 | 제공 바이너리 `agent-app-linux-x86` (sha256 `cdbae8c066e734916b7cd25dc9e651818acf63b2e6817125ede5e85a4de0ff5a`) — 저장소에는 포함하지 않음 |
| 수행 일시 | 2026-10-21 00:44 ~ 00:58 KST |

미션 6장이 "Linux 실습 환경(컨테이너/VM)" 을 허용해 VM 대신 컨테이너를 썼습니다. 컨테이너라서 생기는 차이:

- **CPU · MEM · DISK 는 호스트 전체 값**입니다. 컨테이너는 호스트 커널을 함께 써서 `/proc/stat` · `/proc/meminfo` · `df /` 가 호스트를 보여 줍니다. 그래서 CPU 는 5% 안팎(16 vCPU 기준), MEM 은 35% 안팎(호스트의 다른 프로그램 포함)이고, 임계값 경고는 MEM 만 뜹니다. 앱 자체의 사용량은 `Process` 줄(RSS · 프로세스 CPU)에서 봅니다.
- UFW 규칙은 컨테이너의 네트워크 네임스페이스에만 걸립니다. 그래서 "바깥" 은 같은 Docker 네트워크의 다른 컨테이너입니다.
- 원격 점검용으로 agent-admin 과 root 의 `authorized_keys` 에 같은 시험용 키를 넣었습니다(root 는 키가 맞아도 `PermitRootLogin no` 로 거부되는지 보려고). 비밀번호는 어느 계정에도 설정하지 않았습니다.

## 파일

| 파일 | 내용 | 체크리스트 |
| --- | --- | --- |
| [`00-setup.txt`](00-setup.txt) | `sudo bash setup/run-all.sh` 전체 출력 (계정 → 디렉토리 → 환경 → 설치 → 방화벽 → SSH → cron) | 수행 내역 |
| [`01-ssh.txt`](01-ssh.txt) | 설정 조각 파일, `sshd -T` 최종 값(`port 20022`, `permitrootlogin no`), 20022 LISTEN | 1 |
| [`02-firewall.txt`](02-firewall.txt) | `ufw status verbose / numbered` — active, deny incoming, 20022 · 15034 만 | 2 |
| [`03-accounts.txt`](03-accounts.txt) | `id`, `getent group` | 3 |
| [`04-permissions.txt`](04-permissions.txt) | `ls -ld`, `getfacl`, `namei -l`, **계정별 실제 접근 매트릭스**(6개 항목 기대값과 일치) | 4 |
| [`05-environment.txt`](05-environment.txt) | 환경 파일, 로그인 셸에서 본 `AGENT_*`, 키 파일 | 환경변수 |
| [`06-boot.txt`](06-boot.txt) | 백그라운드 실행 출력의 Boot 5단계 + `Agent READY`, 프로세스 2개(부모·자식), `0.0.0.0:15034` | 5 |
| [`06a-boot-foreground.txt`](06a-boot-foreground.txt) | 포그라운드 실행 화면 — `script` 로 기록한 실제 TTY 출력 | 5 |
| [`06b-boot-troubleshooting.txt`](06b-boot-troubleshooting.txt) | 과제 명세값 그대로일 때의 Boot 실패 2가지 재현, root 실행 거부 | 5 (report 5-1) |
| [`07-monitor.txt`](07-monitor.txt) | `monitor.sh --stats` 실행 결과(Health Check · 자원 · 경고 · 요약), exit 0 | 6 |
| [`08-monitor-log.txt`](08-monitor-log.txt) | `monitor.log` 최근 10줄 | 7 |
| [`09-cron.txt`](09-cron.txt) | agent-admin crontab, cron active, 70초 사이 줄 수 증가, syslog 의 CRON 실행 기록 | 8 |
| [`10-log-capacity.txt`](10-log-capacity.txt) | 한도를 줄인 순환 시연 — 6번 실행 후 파일 4개 유지 | 용량 관리 |
| [`11-report.txt`](11-report.txt) | [보너스 1] report.sh 전체 · 구간 요약 (12 samples) | 보너스 1 |
| [`12-retention.txt`](12-retention.txt) | [보너스 2] log-retention.sh `--dry-run` (수행 직후라 대상 없음) | 보너스 2 |
| [`13-remote-check.txt`](13-remote-check.txt) | **바깥에서** 본 포트(20022 · 15034 open, 22 · 8080 DROP)와 SSH(agent-admin 성공, root 거부) | 1 · 2 |
| [`14-failure-cases.txt`](14-failure-cases.txt) | 방화벽 꺼짐 → 경고만(exit 0), 앱 중지 → Health Check 실패(exit 1, 기록 안 함, cron.log 에 원인), 재시작 → 정상 | 6 |
| [`15-retention-demo.txt`](15-retention-demo.txt) | [보너스 2] 수정 시각을 과거로 맞춘 시연용 파일로 실제 압축 · 이동 · 삭제 | 보너스 2 |

## 재현 방법

```bash
# 1) 서버 컨테이너 (systemd) + 바깥 점검용 컨테이너
docker build -t linux-server-ops-vm verify/container
docker network create opsnet
docker run -d --name agent-server --hostname agent-server --network opsnet --privileged \
  --cgroupns=host -v /sys/fs/cgroup:/sys/fs/cgroup:rw --tmpfs /run --tmpfs /run/lock linux-server-ops-vm
docker run -d --name ops-laptop --hostname ops-laptop --network opsnet linux-server-ops-vm sleep infinity

# 2) 저장소와 제공 앱을 서버에 복사하고 구성
git archive --prefix=linux-server-ops/ HEAD | docker exec -i agent-server tar -x -C /srv
docker cp agent-app.zip agent-server:/srv/
docker exec agent-server bash -c 'cd /srv/linux-server-ops && bash setup/run-all.sh'
docker exec agent-server bash -c 'sudo -u agent-admin unzip -oq /srv/agent-app.zip -x "__MACOSX/*" -d /home/agent-admin/agent-app'

# 3) 앱 실행 → (cron 이 몇 분 쌓은 뒤) 증빙 수집
docker exec agent-server sudo -iu agent-admin /home/agent-admin/agent-app/bin/run-agent.sh --background
docker exec agent-server bash -c 'cd /srv/linux-server-ops && bash verify/collect-evidence.sh'
docker cp agent-server:/srv/linux-server-ops/docs/evidence/. docs/evidence/

# 4) 바깥에서 점검 (ops-laptop 의 공개키를 서버 agent-admin 의 authorized_keys 에 넣은 뒤)
docker cp verify/remote-check.sh ops-laptop:/root/
docker exec ops-laptop bash /root/remote-check.sh agent-server agent-admin --blocked-port 8080
```

`06a` · `06b` · `14` · `15` 는 각 파일 머리에 적힌 명령을 서버 안에서 실행해 같은 형식으로 남긴 것입니다.
