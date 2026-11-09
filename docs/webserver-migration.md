# 웹서버(Nginx) 전환 가이드

관제 대상이 `agent-app` 에서 **웹서버(Nginx)** 로 바뀔 때 점검할 **프로세스·포트·로그/임계값**을 어떻게 바꾸는지 정리합니다. 설계 배경은 [`design.md`](design.md), 항목별 근거는 [`checklist.md`](checklist.md) 를 참고합니다.

- [0. 요약](#0-요약)
- [1. 전환 전 체크포인트](#1-전환-전-체크포인트)
- [2. 프로세스 체크포인트](#2-프로세스-체크포인트)
- [3. 포트 체크포인트](#3-포트-체크포인트)
- [4. 로그 체크포인트](#4-로그-체크포인트)
- [5. 임계값 전환](#5-임계값-전환)
- [6. 전환 절차](#6-전환-절차)
- [7. 롤백](#7-롤백)
- [8. 전환 후 검증 체크리스트](#8-전환-후-검증-체크리스트)
- [9. 실측 결과 요약](#9-실측-결과-요약)

> 이 가이드의 절차는 Ubuntu 22.04 서버(증빙 컨테이너)에 nginx 1.18 을 설치해 **그대로 실행해 본 결과**로 검증했습니다 → [`evidence/23-nginx-migration.txt`](evidence/23-nginx-migration.txt)

---

## 0. 요약

`monitor.sh` 는 관제 대상이 **모두 환경변수**(프로세스 정규식·라벨, 포트, 로그 경로, 임계값)라 **코드를 고치지 않고** 환경 파일만 바꿔 전환합니다. 전환에 쓸 값은 예시 파일 [`../config/examples/monitor-nginx.env`](../config/examples/monitor-nginx.env) 에 모아 두었습니다.

| 변수 | agent-app | nginx | 이유 |
| --- | --- | --- | --- |
| `APP_PROCESS_REGEX` | `^agent[_-]app([._-].*)?$` | `^nginx([: ].*)?$` | nginx 는 명령줄을 `nginx: master process …` 로 바꾸므로 뒤에 `:`·공백이 붙는다 |
| `APP_PROCESS_LABEL` | `agent-app` | `nginx` | 출력 라벨 |
| `AGENT_PORT` | `15034` | `80` (필요하면 `443` 추가) | 웹서버 기본 포트 |
| `APP_USER` | (지정 없음) | (비움) | master 는 root, worker 는 www-data 라 한 계정으로 못 묶는다 |
| `MONITOR_LOG` | `…/monitor.log` | `…/monitor-nginx.log` | 기존 기록과 섞이지 않게 분리 |
| `CPU_WARN` | `20` | `70` | 웹서버는 CPU 변동이 커 20% 는 너무 낮다 |
| `MEM_WARN` | `10` | `80` | MemAvailable 기준 전체 메모리 여유 |
| `DISK_WARN` | `80` | `80` | 동일 |

## 1. 전환 전 체크포인트

전환하기 전에 **대상 환경을 직접 확인**합니다. 항목마다 확인 명령을 함께 적었습니다.

- [ ] 서비스 이름·실행 계정을 확인합니다 — `systemctl status nginx`, `ps -o user,pid,ppid,args -C nginx` (master=root, worker=www-data 인지)
- [ ] 프로세스 구조가 **master 1 + worker N** 인지 확인합니다 — `pgrep -c -f '^nginx: worker'` (`worker_processes auto` 면 CPU 수만큼, 실측 16 vCPU → 16개)
- [ ] 포트 80(필요하면 443)이 LISTEN 중인지 확인합니다 — `ss -ltnp 'sport = :80'`
- [ ] 방화벽에 80·443 을 엽니다 — `sudo ufw allow 80/tcp`, `sudo ufw allow 443/tcp`. 더 이상 안 쓰는 `15034` 규칙은 **전환이 끝나고 Nginx 가 안정된 뒤** `sudo ufw delete allow 15034/tcp` 로 정리합니다
- [ ] 로그 위치·권한을 확인합니다 — Ubuntu 22.04 의 `/var/log/nginx/*.log` 는 `www-data:adm 0640` 이라(실측) cron 실행자(agent-admin)는 **읽을 수 없습니다**. 읽어야 하면 `sudo setfacl -m g:agent-core:r /var/log/nginx/*.log` + 디렉토리에 `setfacl -m g:agent-core:rx /var/log/nginx`, logrotate 가 새로 만드는 파일에도 적용되도록 `setfacl -d -m g:agent-core:r /var/log/nginx` 를 함께 둡니다. agent-admin 을 `adm` 그룹에 넣는 방법도 있지만 adm 은 auth.log 등 시스템 로그 전체를 읽는 그룹이라 최소 권한에 어긋납니다(그룹 추가는 **재로그인 후** 반영)
- [ ] 모니터 로그 경로를 분리했는지 확인합니다 — `MONITOR_LOG=/var/log/agent-app/monitor-nginx.log`
- [ ] Nginx 자체 로그의 logrotate 설정이 있는지 확인합니다 — `test -f /etc/logrotate.d/nginx`

## 2. 프로세스 체크포인트

`monitor.sh` 는 `/proc/<pid>/cmdline` 의 **argv[0] basename** 을 정규식과 비교합니다(자세한 선택 이유는 [`design.md` 3장](design.md#3-monitorsh-내부-구조)).

Nginx 는 실행 직후 자기 명령줄을 바꿉니다.

```
nginx: master process /usr/sbin/nginx -g daemon on; master_process on;
nginx: worker process
```

명령줄 전체가 argv[0] 하나에 들어가므로, `monitor.sh` 가 비교하는 basename(마지막 `/` 뒤)은 실측에서 다음과 같았습니다.

| 프로세스 | argv[0] | basename (정규식 비교 대상) |
| --- | --- | --- |
| master (root) | `nginx: master process /usr/sbin/nginx -g daemon on; master_process on;` | `nginx -g daemon on; master_process on;` |
| worker (www-data) | `nginx: worker process` | `nginx: worker process` |

기존 `^agent[_-]app…` 는 당연히 안 맞고, `^nginx$` 처럼 **정확히 `nginx`** 와 비교하는 방식(`pgrep -x nginx` 와 같은 발상)도 둘 다 뒤에 글자가 붙어 **하나도 못 찾습니다**. 그래서 뒤에 `:` 또는 공백이 붙는 경우까지 받는 정규식을 씁니다.

```sh
APP_PROCESS_REGEX='^nginx([: ].*)?$'
```

### 함정 두 가지 (실측)

| 바꾼 것 | 결과 | 왜 위험한가 |
| --- | --- | --- |
| `AGENT_PORT=80` **만** 바꿈 | Health Check **통과**(exit 0), 기록된 PID 는 agent-app | 프로세스는 여전히 agent-app 을 찾고 80 은 nginx 가 열고 있어 **거짓 OK**. nginx 가 죽어도 agent-app 이 살아 있으면 계속 OK |
| `APP_PROCESS_REGEX='^nginx$'` | `Checking process 'nginx'... [FAIL]`, exit 1 | nginx 가 명령줄을 바꿔서 정확한 이름으로는 못 찾음 → 정상인데 매분 장애 |

그래서 **프로세스 정규식·라벨·포트를 한 파일에 묶어 함께** 바꿉니다(`monitor-nginx.env`).

핵심은 **master 가 살아 있는지**입니다. worker 는 죽어도 master 가 다시 띄우므로, master 부재가 곧 서비스 중단입니다. 참고로 `monitor.sh` 가 로그에 남기는 PID 는 포트를 가진 프로세스 중 하나(실측: **worker** 중 하나)라서, `Process` 줄의 RSS·CPU 는 worker 1개의 값입니다. master 는 아래로 따로 확인합니다.

```sh
pgrep -f '^nginx: master'        # master PID (없으면 서비스 중단)
pgrep -c -f '^nginx: worker'     # worker 개수 (^ 를 붙여야 이 명령을 실행한 셸 자신이 세어지지 않음)
systemctl is-active nginx        # 서비스 단위 상태도 함께 본다 (권장)
```

## 3. 포트 체크포인트

80·443 은 **1024 미만**이라 root 권한이 있는 master 가 bind 하고, 실제 요청은 www-data 로 도는 worker 가 처리합니다.

진단 스크립트로 포트 상태를 단계별로 봅니다.

```sh
sudo bash bin/diagnose-port.sh 80 --process '^nginx([: ].*)?$'
```

`diagnose-port.sh` 의 **6번 단계(1024 미만 포트 권한)** 는 80 처럼 특권 포트를 일반 계정이 아닌 root(또는 `CAP_NET_BIND_SERVICE`)가 열었는지 확인합니다. master 가 root 라면 정상입니다(실측: `80 는 1024 미만이지만 root(uid 0) 프로세스(PID …)가 bind`). **5번 단계(환경변수)는 WARN** 이 나오는데, nginx 는 `AGENT_PORT` 환경변수가 아니라 `/etc/nginx/sites-enabled/*` 의 `listen 80;` 으로 포트를 정하기 때문이라 정상입니다 — nginx 는 `sudo nginx -T | grep -E '^\s*listen'` 으로 대신 확인합니다.

`monitor.sh` 는 **포트 하나**(`AGENT_PORT`)만 봅니다. 443 도 감시하려면 crontab 에 포트만 바꾼 줄을 하나 더 둡니다.

```cron
* * * * * AGENT_ENV_FILE=/etc/agent-app/monitor-nginx.env AGENT_PORT=443 /home/agent-admin/agent-app/bin/monitor.sh --no-stats --quiet >> /var/log/agent-app/cron-nginx.log 2>&1
```

> crontab 은 줄 끝 `\` 로 줄을 이을 수 없습니다. 위처럼 **한 줄**로 씁니다.

LISTEN 여부만으로는 502·503 같은 **애플리케이션 오류를 못 잡습니다**. L7(응답 코드)까지 보려면 cron 의 별도 줄이나 작은 래퍼에서 다음을 확인합니다(파일로 만들 필요는 없고, 한 줄로도 됩니다).

```sh
code="$(curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1/)" || echo "nginx L7 실패"
[ "$code" = 200 ] || echo "nginx 응답 코드 비정상: $code"
```

## 4. 로그 체크포인트

Nginx 로그는 보통 `/var/log/nginx/access.log`, `/var/log/nginx/error.log` 에 있습니다.

최근 1분의 **5xx 비율**(combined 포맷은 `$9` 가 상태코드, `$4` 가 `[시각`):

```sh
awk -v since="$(date -d '1 min ago' '+%d/%b/%Y:%H:%M')" '
  $4 > "["since { total++; if ($9 ~ /^5/) err++ }
  END { if (total) printf "5xx %d/%d (%.1f%%)\n", err, total, 100*err/total; else print "요청 없음" }
' /var/log/nginx/access.log
```

`error.log` 의 대표 오류 집계:

```sh
grep -c 'upstream timed out'            /var/log/nginx/error.log
grep -c 'connect() failed'             /var/log/nginx/error.log
grep -c 'worker_connections are not enough' /var/log/nginx/error.log
```

로그 관리는 **대상을 나눕니다**. Nginx 자체 로그(`access.log`·`error.log`)는 `/etc/logrotate.d/nginx`(Ubuntu 기본 `daily`, `rotate 14`)가 관리하고, 관제 기록인 `monitor-nginx.log` 는 `monitor.sh` 내장 순환(10MB×10)이 관리합니다. **같은 파일을 두 방식으로 돌리지 않습니다**(이중 순환이 되어 꼬입니다).

## 5. 임계값 전환

| 지표 | agent-app 현재 | 웹서버 시작값 | 근거 |
| --- | --- | --- | --- |
| CPU | 20 | 70 | 웹서버는 트래픽에 따라 CPU 변동이 커 20% 는 상시 경고가 된다 |
| MEM | 10 | 80 | `MemAvailable` 기준 전체 여유. 캐시를 뺀 실제 여유가 20% 아래면 경고 |
| DISK | 80 | 80 | 동일 |
| 활성 연결 | — | (추가) | `stub_status` 의 Active connections 를 `worker_connections` 대비로 본다 |
| 5xx 비율 | — | (추가) | 포트가 열려도 502/503 은 못 잡으므로 함께 본다 |
| 응답 시간(latency) | — | (추가) **p95 > 200ms 경고** | 평균은 느린 소수 요청을 가리므로 p95(상위 5% 경계)를 본다. 바깥에서는 `curl -w '%{time_total}'`, 서버 안에서는 access log 의 `$request_time` |

시작값은 **"출발점"** 일 뿐입니다. 전환 후 **1주일 baseline** 을 모은 뒤 조정합니다.

```sh
bin/report.sh --from "2026-11-10" --to "2026-11-16" --file /var/log/agent-app/monitor-nginx.log
```

평균·최대를 보고, 평소 최대보다 여유를 둔 값으로 `CPU_WARN`·`MEM_WARN` 을 다시 정합니다.

### 응답시간(latency) 측정 예 (실측)

웹서버에서는 "프로세스·포트가 살아 있다" 다음으로 **"얼마나 빨리 응답하나"** 가 핵심 지표입니다. CPU 가 낮아도 백엔드 대기·디스크 I/O 때문에 느려질 수 있기 때문입니다. 아래는 같은 서버에 nginx 를 띄워 실제로 돌린 명령과 결과입니다([`evidence/27-feedback-round2.txt`](evidence/27-feedback-round2.txt) ⑩).

① **바깥에서 본 응답시간** — curl 20회의 전체 시간(total) 분포:

```bash
for i in $(seq 20); do curl -o /dev/null -s -w '%{http_code} %{time_connect} %{time_starttransfer} %{time_total}\n' http://127.0.0.1/; done > /tmp/lat.txt
awk '{print $4*1000}' /tmp/lat.txt | sort -n | awk '{a[NR]=$1} END {printf "p50=%.2fms p95=%.2fms max=%.2fms\n", a[int(NR*0.5)], a[int(NR*0.95)], a[NR]}'
# 실측: p50=0.65ms p95=0.72ms max=0.82ms, 200 이 아닌 응답 0건 (정적 기본 페이지, 같은 서버에서 호출)
```

② **서버 안에서 본 처리시간** — 기존 access.log 는 두고 `$request_time` 을 담은 로그를 하나 더 남깁니다(`/etc/nginx/conf.d/timing.conf`):

```nginx
log_format timing '$remote_addr [$time_local] "$request" $status rt=$request_time';
access_log /var/log/nginx/timing.log timing;
```

`sudo nginx -t && sudo systemctl reload nginx` 후 줄이 `… "GET / HTTP/1.1" 200 rt=0.000` 처럼 남습니다. 리버스 프록시로 앱 서버를 앞에 둔다면 `$upstream_response_time` 도 같은 방식으로 추가해 "nginx 가 느린지, 뒤의 앱이 느린지" 를 나눠 봅니다.

③ **임계값 판정** — 최근 100건 p95 가 `LATENCY_WARN_MS` 를 넘으면 WARNING. monitor.sh 의 CPU/MEM 처럼 **경고만**(서비스는 응답 중) 등급입니다:

```bash
LATENCY_WARN_MS=200
p95=$(tail -n 100 /var/log/nginx/timing.log | grep -o 'rt=[0-9.]*' | cut -d= -f2 | sort -n \
      | awk '{a[NR]=$1} END {printf "%.1f", a[int(NR*0.95)]*1000}')
awk -v p="$p95" -v t="$LATENCY_WARN_MS" 'BEGIN { if (p > t) print "[WARNING] latency p95 " p "ms > " t "ms"; else print "[OK] latency p95 " p "ms" }'
```

시작값 200ms 는 "사람이 지연을 느끼기 시작하는 수준" 을 출발점으로 잡은 값이고, CPU·MEM 과 마찬가지로 1주일 baseline 의 p95 에 여유를 둬 다시 정합니다. 5xx 비율(`awk '$9 ~ /^5/'`)과 함께 보면 "느려졌는데 오류는 없다(과부하)" 와 "빠른데 오류가 난다(앱 장애)" 를 구분할 수 있습니다.

## 6. 전환 절차

① 공용 env 를 백업합니다.

```sh
sudo cp -a /etc/agent-app/agent-app.env /etc/agent-app/agent-app.env.bak.$(date +%Y%m%d-%H%M%S)
```

② `monitor-nginx.env` 를 설치합니다.

```sh
sudo install -m 0640 -o root -g agent-core config/examples/monitor-nginx.env /etc/agent-app/monitor-nginx.env
```

③ 방화벽을 엽니다.

```sh
sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
```

④ 수동으로 한 번 실행해 결과와 종료 코드를 봅니다.

```sh
sudo -u agent-admin env AGENT_ENV_FILE=/etc/agent-app/monitor-nginx.env \
  /home/agent-admin/agent-app/bin/monitor.sh --no-stats; echo $?
```

⑤ 포트를 진단합니다.

```sh
sudo bash bin/diagnose-port.sh 80 --process '^nginx([: ].*)?$'
```

⑥ crontab 줄을 추가/교체합니다(기존 agent-app 줄을 함께 운영할지, 교체할지는 운영 정책에 따릅니다). 실측에서는 **병행 운영**(기존 줄 유지 + nginx 줄 추가)으로 했고, 경고·오류도 `cron-nginx.log` 로 분리했습니다.

```sh
(sudo crontab -u agent-admin -l; echo '* * * * * AGENT_ENV_FILE=/etc/agent-app/monitor-nginx.env /home/agent-admin/agent-app/bin/monitor.sh --no-stats --quiet >> /var/log/agent-app/cron-nginx.log 2>&1') | sudo crontab -u agent-admin -
```

⑦ 2분 뒤 cron 실행과 기록을 확인합니다. `check-cron.sh` 도 같은 env 파일을 읽게 하면 nginx 쪽 `monitor-nginx.log` 를 점검합니다.

```sh
grep CRON /var/log/syslog | grep agent-admin | tail -n 4
tail /var/log/agent-app/monitor-nginx.log
sudo env AGENT_ENV_FILE=/etc/agent-app/monitor-nginx.env CRON_LOG=/var/log/agent-app/cron-nginx.log bash verify/check-cron.sh
```

## 7. 롤백

- crontab 에서 추가/교체한 줄을 **되돌립니다**(agent-app 줄 복원, nginx 줄 제거).
- env 파일을 제거합니다 — `sudo rm -f /etc/agent-app/monitor-nginx.env`.
- 방화벽 규칙을 닫습니다 — `sudo ufw delete allow 80/tcp`(필요하면 443 도).
- 기존 `monitor.log` 는 **그대로 남아** agent-app 관제가 재개되면 이어서 기록됩니다(분리해 두었으므로 nginx 전환이 기존 기록을 건드리지 않았습니다).

## 8. 전환 후 검증 체크리스트

| 항목 | 명령 | 기대 결과 |
| --- | --- | --- |
| master 프로세스 | `pgrep -f '^nginx: master'` | PID 1개 |
| worker 수 | `pgrep -c -f '^nginx: worker'` | 1 이상 |
| 서비스 상태 | `systemctl is-active nginx` | `active` |
| 포트 LISTEN | `ss -ltnp 'sport = :80'` | 80 LISTEN(master=root) |
| L7 응답 | `curl -fsS -o /dev/null -w '%{http_code}' http://127.0.0.1/` | `200` |
| 응답시간 | `curl -o /dev/null -s -w '%{time_total}\n' http://127.0.0.1/` 를 여러 번 (§5 응답시간 측정 예) | p95 가 `LATENCY_WARN_MS`(시작값 200ms) 이하 |
| 바깥 접속 | (다른 PC) `curl -s -o /dev/null -w '%{http_code}' http://<서버>/` | `200` (방화벽 허용 전에는 응답 없음) |
| 포트 진단 | `sudo bash bin/diagnose-port.sh 80 --process '^nginx([: ].*)?$'` | FAIL 없음(exit 0), 5단계 WARN 은 정상 |
| cron 기록 | `sudo env AGENT_ENV_FILE=/etc/agent-app/monitor-nginx.env CRON_LOG=/var/log/agent-app/cron-nginx.log bash verify/check-cron.sh` | FAIL 없음(exit 0) |
| 모니터 로그 | `tail /var/log/agent-app/monitor-nginx.log` | 지정 포맷 줄이 매분 누적 |
| 장애 감지 | `sudo systemctl stop nginx` 후 수동 실행 | `Checking process 'nginx'... [FAIL]`, exit 1 (확인 후 `start`) |

## 9. 실측 결과 요약

Ubuntu 22.04.5 + nginx 1.18.0, agent-app 을 띄운 채로 위 절차를 실행했습니다 → [`evidence/23-nginx-migration.txt`](evidence/23-nginx-migration.txt)

| 단계 | 결과 |
| --- | --- |
| 전환 전 | master 1(root) + worker 16(www-data), 80 LISTEN, 방화벽에 80 없음, nginx 로그 `www-data:adm 0640` → agent-admin 읽기 불가 |
| 함정 ① 포트만 변경 | exit 0, 기록 PID = agent-app → **거짓 OK** 재현 |
| 함정 ② `^nginx$` | 프로세스 FAIL, exit 1 |
| 방화벽 | 허용 전 바깥에서 `HTTP 000`(timeout) → `ufw allow 80/tcp` 후 `HTTP 200` |
| 수동 실행 | `Checking process 'nginx'... [OK]`, `port 80 [OK]`, 임계값 70/80/80 이라 경고 없음, `monitor-nginx.log` 에 기록 |
| 포트 진단 | FAIL 없음, 6단계 root bind OK, 5단계 WARN(nginx 는 AGENT_PORT 미사용) |
| 장애 감지 | `systemctl stop nginx` → 프로세스 FAIL, exit 1 |
| 로그 | ACL 부여 후 agent-admin 이 5xx 비율 집계 가능 |
| cron 병행 | 같은 분에 두 줄이 각각 실행, `monitor-nginx.log` · `monitor.log` 각각 매분 누적 |
| 롤백 | crontab 줄 · env · 80 규칙 · ACL 제거 → agent-app 관제는 그대로 정상 |
| 응답시간 (`27` ⑩) | curl 20회 p50 0.65ms · p95 0.72ms · max 0.82ms, 비200 0건 / `timing.log` 에 `rt=` 기록, p95 판정 `[OK]` |
