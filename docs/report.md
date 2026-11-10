# 요구사항 수행 내역서

> B4-1 · 컴퓨터가 알아서 자기 상태를 점검하게 만들기
> 대상 서버: Ubuntu 22.04 LTS · 방화벽: **UFW** · 앱: 제공 바이너리 `agent-app-linux-x86` (Apple Silicon 은 `-arm64`)

이 문서는 **무엇을 어떻게 설정했는지(수행 내역 + 명령어 기록)** 와 **어떻게 확인했는지(증빙)** 를 요구사항 순서대로 정리합니다.
모든 설정은 `setup/` 스크립트로 재현할 수 있고, 증빙은 `verify/collect-evidence.sh` 가 `docs/evidence/*.txt` 로 수집합니다.

| 수행 정보 | 내용 |
| --- | --- |
| 수행 환경 | **Docker 컨테이너, Ubuntu 22.04.5 LTS** (systemd 로 부팅해 sshd · UFW · cron 이 실제 서비스로 동작, 호스트명 `agent-server`). 바깥 접속 점검은 같은 Docker 네트워크의 두 번째 컨테이너(`ops-laptop`)에서 — [재현 방법](evidence/README.md#재현-방법) |
| 수행 일시 | 2026-10-21 00:44 ~ 00:58 KST |
| 재현 방법 | `sudo bash setup/run-all.sh` → 앱 실행 → `sudo bash verify/collect-evidence.sh` (+ 다른 PC 에서 `verify/remote-check.sh`) |
| 앱 | 제공 바이너리 `agent-app-linux-x86` (sha256 `cdbae8c0…de0ff5a`) |

---

## 필수 증거 자료 체크리스트

| # | 증빙 항목 | 증빙 파일 | 확인 |
| --- | --- | --- | --- |
| 1 | SSH 포트 변경(20022) 및 Root 원격 접속 차단 | [`01-ssh.txt`](evidence/01-ssh.txt) · 바깥에서 확인 [`13-remote-check.txt`](evidence/13-remote-check.txt) | ☑ |
| 2 | 방화벽 활성화, 20022/tcp · 15034/tcp 만 허용 | [`02-firewall.txt`](evidence/02-firewall.txt) · 바깥에서 확인 [`13-remote-check.txt`](evidence/13-remote-check.txt) | ☑ |
| 3 | 계정/그룹(agent-admin/dev/test, agent-common/core) | [`03-accounts.txt`](evidence/03-accounts.txt) | ☑ |
| 4 | 디렉토리 구조 및 권한(ACL 포함) | [`04-permissions.txt`](evidence/04-permissions.txt) (계정별 실제 접근 매트릭스) | ☑ |
| 5 | Boot Sequence 5단계 [OK] 및 "Agent READY" | [`06-boot.txt`](evidence/06-boot.txt) · 포그라운드 실행 화면(TTY 기록) [`06a-boot-foreground.txt`](evidence/06a-boot-foreground.txt) | ☑ |
| 6 | monitor.sh 실행 결과(프로세스/포트/리소스/경고) | [`07-monitor.txt`](evidence/07-monitor.txt) · 장애 상황 [`14-failure-cases.txt`](evidence/14-failure-cases.txt) | ☑ |
| 7 | monitor.log 누적 기록(최근 라인) | [`08-monitor-log.txt`](evidence/08-monitor-log.txt) | ☑ |
| 8 | crontab 매분 등록 및 자동 실행(1분 후 로그 증가) | [`09-cron.txt`](evidence/09-cron.txt) | ☑ |
| + | 서버 구성 실행 기록 | [`00-setup.txt`](evidence/00-setup.txt) | ☑ |
| + | 환경변수 · Boot 실패 재현 | [`05-environment.txt`](evidence/05-environment.txt) · [`06b-boot-troubleshooting.txt`](evidence/06b-boot-troubleshooting.txt) | ☑ |
| + | 로그 용량 관리 · 보너스 1 · 보너스 2 | [`10-log-capacity.txt`](evidence/10-log-capacity.txt) · [`11-report.txt`](evidence/11-report.txt) · [`12-retention.txt`](evidence/12-retention.txt) · [`15-retention-demo.txt`](evidence/15-retention-demo.txt) | ☑ |
| + | 동료 평가 피드백 보완 (2026-11-09) — setup 전후 `ss`, firewalld, Boot 단계별, exit 1·2, cron 장애 복구, 포트 진단, fail2ban, nginx 전환, logrotate, 알림, `>` 실수 | [`16`](evidence/16-ports.txt) ~ [`26`](evidence/26-redirect.txt) · 항목별 대응 [`feedback-checklist.md`](feedback-checklist.md) | ☑ |
| + | 2차 동료 평가 보완 (2026-11-09) — 계정 잠금·비밀번호 정책, 로그 타임존, cron 환경 env 로드 검증(`check-cron.sh` 7단계), Health Check 실패 시 `[HINT]`, 바인딩 실패 로그 수집, 동시 실행 잠금, latency 지표, AppArmor/SELinux 영향 | [`27`](evidence/27-feedback-round2.txt) · [`feedback-checklist.md` 2차 표](feedback-checklist.md#2차-평가-반영) | ☑ |
| + | 3차 동료 평가 보완 (2026-11-10) — logrotate 전환(`setup/09-logrotate.sh`, 내장 순환과 동시 동작 차단), 설치 로그의 계정 권한 표 · 파일 권한 확인, root crontab 교차 확인, cron 실패 알림, SSH 변경 안전 점검, 웹서버 URL · TLS 점검 | [`28`](evidence/28-feedback-round3.txt) · [`feedback-checklist.md` 3차 표](feedback-checklist.md#3차-평가-반영) | ☑ |

> 증빙 파일마다 첫머리에 수집 시각 · 호스트 · 실행 명령이 있고, 그 아래가 명령의 실제 출력입니다. 파일 목록과 각 파일이 보여 주는 것: [`evidence/README.md`](evidence/README.md)
>
> **수행 환경의 특성**: 컨테이너는 호스트 커널을 함께 쓰기 때문에 `/proc/stat` · `/proc/meminfo` · `df /` 가 **호스트 전체(16 vCPU · 메모리 약 14.5GB)** 값입니다. 그래서 monitor.sh 의 CPU 는 5% 안팎으로 낮고 MEM 은 35% 안팎(호스트의 다른 프로세스 포함)으로 나와 MEM 경고만 계속 뜹니다. 앱 자체의 사용량은 `Process` 줄(RSS · 프로세스 CPU)에서 봅니다.

---

## 1. SSH 설정 — 포트 20022, Root 원격 로그인 차단

**수행 내역**

| 설정 | 값 | 위치 |
| --- | --- | --- |
| 접속 포트 | `Port 20022` | `/etc/ssh/sshd_config.d/00-agent-hardening.conf` |
| root 원격 로그인 | `PermitRootLogin no` | 같은 파일 |
| 본문의 기존 `Port` 줄 | 주석 처리 | `/etc/ssh/sshd_config` (백업 `.bak.<시각>`) |

- 설정 조각 파일 이름을 `00-` 으로 시작한 이유: sshd 는 같은 설정이 여러 번 나오면 **처음 읽은 값**을 쓰고, `sshd_config.d/*.conf` 는 알파벳 순으로 맨 앞에서 읽힙니다. `00-` 은 `50-cloud-init.conf` 같은 조각보다 먼저 읽혀 확실히 적용됩니다.
- 단 `Port` 는 예외로 **누적**(여러 개면 모두 listen)되므로, 22 가 남지 않도록 본문의 다른 `Port` 줄을 주석 처리했습니다.
- 재시작 전에 `sshd -t` 로 문법을 검사하고, 실패하면 변경을 되돌립니다(원격 접속 잠김 방지).

**명령어 기록** (`setup/01-ssh.sh`)

```bash
sudo install -m 0644 config/sshd_config.d/00-agent-hardening.conf /etc/ssh/sshd_config.d/
sudo sed -i -E 's/^([[:space:]]*Port[[:space:]]+)/# disabled by 01-ssh.sh: \1/' /etc/ssh/sshd_config
sudo sshd -t                     # 문법 검사
sudo systemctl restart ssh       # Ubuntu 22.04 (22.10+ 는 ssh.socket 재시작)
```

**실제 결과** ([`01-ssh.txt`](evidence/01-ssh.txt))

```console
$ sshd -T | grep -Ei '^(port|permitrootlogin) '
port 20022
permitrootlogin no
$ ss -tulnp | grep -E 'sshd|:20022\b'
tcp   LISTEN 0      128          0.0.0.0:20022      0.0.0.0:*    users:(("sshd",pid=500,fd=3))
tcp   LISTEN 0      128             [::]:20022         [::]:*    users:(("sshd",pid=500,fd=4))
```

**바깥에서 확인** ([`13-remote-check.txt`](evidence/13-remote-check.txt), 다른 호스트에서 `verify/remote-check.sh`): agent-admin 은 20022 로 접속되고, root 는 **올바른 키가 등록돼 있어도** 거부되며, 22 는 응답이 없습니다.

```console
$ ssh -p 20022 agent-admin@172.18.0.2 'id; hostname'
uid=1000(agent-admin) gid=1002(agent-admin) groups=1002(agent-admin),1000(agent-common),1001(agent-core)
agent-server
$ ssh -p 20022 root@172.18.0.2 'id'
root@172.18.0.2: Permission denied (publickey,password).
$ ssh -p 22 agent-admin@172.18.0.2 'id'
ssh: connect to host 172.18.0.2 port 22: Connection timed out
```

## 2. 방화벽 — UFW, 20022/tcp · 15034/tcp 만 허용

**수행 내역**: 기본 정책 `deny incoming / allow outgoing` + 허용 목록 2개. 기존 규칙은 `ufw --force reset` 으로 지워 "필요한 포트만" 을 확실히 했습니다.

**명령어 기록** (`setup/02-firewall.sh`)

```bash
sudo ufw --force reset
sudo ufw default deny incoming
sudo ufw default allow outgoing
sudo ufw allow 20022/tcp comment 'SSH (sshd Port)'
sudo ufw allow 15034/tcp comment 'agent-app'
sudo ufw --force enable
```

**실제 결과** ([`02-firewall.txt`](evidence/02-firewall.txt))

```console
$ ufw status verbose
Status: active
Logging: on (low)
Default: deny (incoming), allow (outgoing), deny (routed)
New profiles: skip

To                         Action      From
--                         ------      ----
20022/tcp                  ALLOW IN    Anywhere                   # SSH (sshd Port)
15034/tcp                  ALLOW IN    Anywhere                   # agent-app
20022/tcp (v6)             ALLOW IN    Anywhere (v6)              # SSH (sshd Port)
15034/tcp (v6)             ALLOW IN    Anywhere (v6)              # agent-app
```

`(v6)` 줄은 같은 규칙의 IPv6 판입니다(추가로 열린 포트가 아님).

**바깥에서 확인** ([`13-remote-check.txt`](evidence/13-remote-check.txt)): 서버에서 8080 에 웹 서버를 띄워 둔 상태에서도 바깥에서는 허용한 두 포트만 열립니다. 막힌 포트는 거부(RST) 대신 **응답 없음**(UFW 기본 정책 DROP)이라 시간 초과로 끝납니다.

```console
PORT    SERVICE       RESULT
20022   sshd          open
15034   agent-app     open
22      ssh(default)  timeout (응답 없음 — 방화벽 DROP)
8080    not-allowed   timeout (응답 없음 — 방화벽 DROP)
```
 원격 접속 중이라면 방화벽을 **SSH 포트 변경보다 먼저** 적용해 20022 가 열린 상태에서 sshd 를 재시작합니다(`setup/run-all.sh` 순서). firewalld 를 쓰는 배포판은 `setup/02-firewall-firewalld.sh`.

## 3. 계정 / 그룹

| 계정 | 역할 | agent-common | agent-core |
| --- | --- | :---: | :---: |
| agent-admin | 운영/관리, 앱 실행, cron 실행자 | ✓ | ✓ |
| agent-dev | 개발/운영, monitor.sh 작성자 | ✓ | ✓ |
| agent-test | QA/테스트 | ✓ | ✗ |

**명령어 기록** (`setup/03-accounts.sh`)

```bash
sudo groupadd agent-common && sudo groupadd agent-core
sudo useradd -m -s /bin/bash agent-admin   # agent-dev, agent-test 동일
sudo usermod -aG agent-common,agent-core agent-admin
sudo usermod -aG agent-common,agent-core agent-dev
sudo usermod -aG agent-common agent-test
```

**실제 결과** ([`03-accounts.txt`](evidence/03-accounts.txt))

```console
$ id agent-admin; id agent-dev; id agent-test
uid=1000(agent-admin) gid=1002(agent-admin) groups=1002(agent-admin),1000(agent-common),1001(agent-core)
uid=1001(agent-dev) gid=1003(agent-dev) groups=1003(agent-dev),1000(agent-common),1001(agent-core)
uid=1002(agent-test) gid=1004(agent-test) groups=1004(agent-test),1000(agent-common)
$ getent group agent-common agent-core
agent-common:x:1000:agent-admin,agent-dev,agent-test
agent-core:x:1001:agent-admin,agent-dev
```

## 4. 디렉토리 구조와 권한 (ACL 포함)

| 경로 | 소유자:그룹 | 권한 | ACL | 정책 |
| --- | --- | --- | --- | --- |
| `/home/agent-admin` | agent-admin:agent-admin | 750 | `g:agent-common:--x` | 공유 폴더로 **지나가기만** 허용 (목록 X) |
| `$AGENT_HOME` | agent-admin:agent-common | 750 | | |
| `$AGENT_HOME/upload_files` | agent-admin:**agent-common** | 2770 | `g:agent-common:rwx` + default | **공유**: admin/dev/test R/W |
| `$AGENT_HOME/api_keys` | agent-admin:**agent-core** | 2770 | `g:agent-core:rwx` + default, `o::---` | **보안**: admin/dev 만 |
| `$AGENT_HOME/api_keys/t_secret.key` | agent-admin:agent-core | 640 | | 내용 `agent_api_key_test` |
| `$AGENT_HOME/api_keys/secret.key` | → `t_secret.key` 심볼릭 링크 | | | 제공 앱이 읽는 이름 ([5-1](#5-1-명세와-실제-동작의-차이) 참고) |
| `$AGENT_HOME/bin` | agent-dev:agent-core | 2750 | | 스크립트 위치 |
| `/var/log/agent-app` | agent-admin:**agent-core** | 2770 | `g:agent-core:rwx` + default, `o::---` | **보안**: admin/dev 만 |
| `/var/log/monitor/agent-app/archive` | agent-admin:agent-core | 2770 | 위와 동일 | 보너스 2 아카이브 |

- `2xxx`(setgid): 안에서 만든 파일이 디렉토리 그룹(agent-common/core)을 물려받습니다. 없으면 만든 사람의 개인 그룹(예: agent-dev)이 붙어 다른 사람이 못 고칩니다.
- default ACL: 각자 umask 가 022 여도 새 파일에 그룹 rw 가 자동으로 붙습니다.
- Ubuntu 22.04 의 홈 디렉토리는 기본 750 이라 dev/test 가 `upload_files` 까지 **경로를 지나갈 수도 없습니다.** 홈 전체를 열지 않고 `--x`(통과)만 ACL 로 줬습니다.

**명령어 기록** (`setup/04-directories.sh`, 일부)

```bash
sudo setfacl -m g:agent-common:--x /home/agent-admin
sudo install -d -o agent-admin -g agent-common -m 2770 $AGENT_HOME/upload_files
sudo install -d -o agent-admin -g agent-core   -m 2770 $AGENT_HOME/api_keys
sudo install -d -o agent-admin -g agent-core   -m 2770 /var/log/agent-app
sudo setfacl -m g:agent-core:rwx,o::--- $AGENT_HOME/api_keys
sudo setfacl -d -m g:agent-core:rwx,o::--- $AGENT_HOME/api_keys
printf 'agent_api_key_test\n' | sudo tee $AGENT_HOME/api_keys/t_secret.key
sudo chown agent-admin:agent-core $AGENT_HOME/api_keys/t_secret.key && sudo chmod 640 $_
sudo ln -sfn t_secret.key $AGENT_HOME/api_keys/secret.key
```

**확인**: `ls -ld`, `getfacl`, `namei -l`, 그리고 **계정별 실제 접근 테스트**(각 계정으로 `sudo -u` 해서 직접 읽기/쓰기 시도). 실제 결과는 기대값과 6개 항목 모두 일치했습니다 ([`04-permissions.txt`](evidence/04-permissions.txt)):

| target (action) | agent-admin | agent-dev | agent-test | 기대값 |
| --- | :---: | :---: | :---: | :---: |
| upload_files (write) | O | O | O | O O O |
| t_secret.key (read) | O | O | **X** | O O X |
| api_keys (write) | O | O | **X** | O O X |
| /var/log/agent-app (write) | O | O | **X** | O O X |
| monitor.sh (execute) | O | O | **X** | O O X |
| monitor.sh (modify) | X | O | X | X O X |

```console
$ namei -l /home/agent-admin/agent-app/api_keys/t_secret.key
drwxr-xr-x root        root         /
drwxr-xr-x root        root         home
drwxr-x--- agent-admin agent-admin  agent-admin      ← ACL g:agent-common:--x 로 통과만 허용
drwxr-x--- agent-admin agent-common agent-app
drwxrws--- agent-admin agent-core   api_keys
-rw-r----- agent-admin agent-core   t_secret.key
```

## 5. 앱 실행 환경 — 환경변수와 키 파일

| 변수 | 값 |
| --- | --- |
| `AGENT_HOME` | `/home/agent-admin/agent-app` |
| `AGENT_PORT` | `15034` |
| `AGENT_UPLOAD_DIR` | `$AGENT_HOME/upload_files` |
| `AGENT_KEY_PATH` | `$AGENT_HOME/api_keys` (디렉토리 — 아래 5-1 참고) |
| `AGENT_LOG_DIR` | `/var/log/agent-app` |

- 값은 `/etc/agent-app/agent-app.env` **한 곳**에만 두고, 로그인 셸은 `/etc/profile.d/agent-app.sh` 가, cron 과 스크립트는 같은 파일을 직접 읽습니다. 로그인 셸과 cron 이 서로 다른 값을 보면 "직접 실행하면 되는데 cron 에서는 실패" 하는 장애가 생기기 때문입니다.
- 확인: `sudo -iu agent-admin bash -lc 'env | grep ^AGENT_'` → 다섯 값 모두 위 표와 같음 ([`05-environment.txt`](evidence/05-environment.txt))

### 5-1. 명세와 실제 동작의 차이

과제 문서대로 `AGENT_KEY_PATH=$AGENT_HOME/api_keys/t_secret.key` 로 설정하고 제공 바이너리(`agent-app-linux-x86`)를 실행하면 Boot 가 실패했습니다. 메시지를 근거로 원인을 확인하고 조치했습니다.

| 단계 | 내용 |
| --- | --- |
| 증상 1 | `[2/5] Verifying Environment Variables [FAIL]` → `>>> Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys` |
| 원인 1 | 앱은 키 **파일**이 아니라 키 **디렉토리** 경로를 기대한다 |
| 조치 1 | `AGENT_KEY_PATH=$AGENT_HOME/api_keys` |
| 증상 2 | `[3/5] Checking Required Files [FAIL]` → `>>> Missing File: secret.key (Expected location: …/api_keys/secret.key)` |
| 원인 2 | 앱이 찾는 파일 이름은 `secret.key` (명세는 `t_secret.key`) |
| 조치 2 | 명세의 `t_secret.key` 를 원본으로 두고 `secret.key → t_secret.key` 심볼릭 링크 추가. 키 값이 한 곳에만 있어서 바꿀 때 어긋나지 않는다 |
| 결과 | 5단계 모두 `[OK]`, `Agent READY` |
| 재발 방지 | `setup/04·05` 스크립트에 반영하고, 이유를 스크립트 주석과 이 문서에 기록 |

이 실패는 수행 환경에서 다시 재현해 기록했습니다 ([`06b-boot-troubleshooting.txt`](evidence/06b-boot-troubleshooting.txt): ① 파일 경로로 줬을 때, ② `secret.key` 가 없을 때, ③ root 로 실행하려 할 때).

```
$ sudo -iu agent-admin env AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys/t_secret.key …/agent-app-linux-x86
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
   ... Running as service user 'agent-admin' (uid=1000)
[2/5] Verifying Environment Variables     [FAIL]
   >>> Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys
[3/5] Checking Required Files             [FAIL]
   >>> Skipped due to previous critical failure.
…
System Boot Failed. Process Terminated.
```

## 6. 앱 실행 — Boot Sequence 5단계와 Agent READY

```bash
# agent-app.zip 을 $AGENT_HOME 에 풀고 (소유자 agent-admin)
sudo -iu agent-admin
/home/agent-admin/agent-app/bin/run-agent.sh              # 포그라운드: Boot 5단계 확인 후 Ctrl+C
/home/agent-admin/agent-app/bin/run-agent.sh --background # 관제·cron 확인용 백그라운드 실행
```

`run-agent.sh` 는 root 실행을 거부하고(요구사항: 일반 계정 실행), 환경 파일을 읽은 뒤 CPU 에 맞는 바이너리(`-x86` / `-arm64`)를 실행합니다.

**실제 결과** — 포그라운드 실행 화면을 `script` 로 TTY 그대로 기록 ([`06a-boot-foreground.txt`](evidence/06a-boot-foreground.txt), 처음 20줄)

```
agent-admin@agent-server:~$ /home/agent-admin/agent-app/bin/run-agent.sh
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
   ... Running as service user 'agent-admin' (uid=1000)
[2/5] Verifying Environment Variables     [OK]
   ... All required Envs correct
[3/5] Checking Required Files             [OK]
   ... Verified 'secret.key' with correct key string.
[4/5] Checking Port Availability          [OK]
   ... Port 15034 is available.
[5/5] Verifying Log Permission            [OK]
   ... Log directory is writable: /var/log/agent-app
------------------------------------------------------------
All Boot Checks Passed!
Agent READY
2026-10-21 00:44:32,957 [INFO] [SafetyGuard] Process priority lowered (nice=10).
2026-10-21 00:44:32,957 [INFO] Agent listening at port 15034
2026-10-21 00:44:32,957 [INFO] === Agent Worker Started ===
2026-10-21 00:44:32,957 [INFO]    > Cycle: 0 -> 256MB/Lv10 -> 0
```

앱은 READY 후 메모리를 0 → 256MB → 0 으로, CPU 점유를 Level 1 → 10 으로 오르내리는 부하를 스스로 만듭니다. 그래서 monitor.sh 의 CPU·MEM 경고가 주기적으로 나타나는 것이 정상입니다.
제공 앱은 PyInstaller 형식이라 **같은 이름의 프로세스가 2개**(부트로더 부모 + 실제 앱 자식) 뜹니다. monitor.sh 는 포트를 가진 자식 PID 를 골라 기록합니다.

백그라운드 실행 후 ([`06-boot.txt`](evidence/06-boot.txt)):

```console
$ ps -eo user,pid,ppid,etime,cmd | grep -E '[a]gent[-_]app'
agent-a+     600       1       09:19 /home/agent-admin/agent-app/agent-app-linux-x86
agent-a+     602     600       09:19 /home/agent-admin/agent-app/agent-app-linux-x86
$ ss -tlnp | grep ':15034\b'
LISTEN 1      1            0.0.0.0:15034      0.0.0.0:*    users:(("agent-app-linux",pid=602,fd=4))
```

## 7. monitor.sh — 시스템 관제 자동화 스크립트

| 항목 | 내용 |
| --- | --- |
| 소스 | [`bin/monitor.sh`](../bin/monitor.sh) → 설치 `$AGENT_HOME/bin/monitor.sh` |
| 소유 / 권한 | **agent-dev : agent-core / 750** (`setup/06-install-monitor.sh`) |
| Health Check (실패 시 `exit 1`) | 앱 프로세스 → TCP 15034 LISTEN |
| 상태 점검 (경고만) | 방화벽 비활성 → `[WARNING]`, 계속 진행 |
| 자원 수집 | CPU(`/proc/stat` 1초 간격 2회), MEM(`MemTotal−MemAvailable`), DISK(`df -P /`) |
| 임계값 경고 (경고만) | CPU > 20%, MEM > 10%, DISK > 80% (환경변수로 조정) |
| 로그 | `/var/log/agent-app/monitor.log` 에 `>>` 로 한 줄 추가 |
| 종료 코드 | 0 정상(경고 포함) / 1 Health Check 실패 / 2 실행 환경 오류 |

**실제 결과** ([`07-monitor.txt`](evidence/07-monitor.txt), agent-admin 으로 실행)

```
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app'... [OK] (PID: 602)
Checking port 15034... [OK]
Checking firewall... [OK] (active)

[RESOURCE MONITORING]
CPU Usage : 5.6%
MEM Usage : 35.7%
DISK Used : 24%
Process   : PID 602 CPU 47.2% MEM 1.7% RSS 264.3MB Threads 1

[WARNING] MEM threshold exceeded (35.7% > 10%)

====== STATISTICS REPORT ======   ← 터미널에서 실행하면 report.sh 요약을 함께 출력
Period  : 2026-10-21 00:46:02 ~ 2026-10-21 00:54:11
…
[INFO] Log appended: /var/log/agent-app/monitor.log
(exit code: 0)
```

CPU · MEM · DISK 는 호스트 전체 값입니다([수행 환경의 특성](#필수-증거-자료-체크리스트)). 앱 자체는 `Process` 줄처럼 RSS 264MB, 측정 구간 CPU 47% 로 부하를 만들고 있습니다.

**장애 상황** ([`14-failure-cases.txt`](evidence/14-failure-cases.txt)) — 요구사항대로 "점검은 경고만, Health Check 실패는 종료"인지 실제로 확인했습니다.

| 상황 | monitor.sh 결과 | 종료 코드 | monitor.log |
| --- | --- | :---: | --- |
| 방화벽을 잠시 끔 (`ufw disable`) | `Checking firewall... [WARN] (inactive)` + `[WARNING] Firewall is inactive` | 0 | 기록함 |
| 앱을 멈춤 (`run-agent.sh --stop`) | `Checking process 'agent-app'... [FAIL]` + `[ERROR] 앱 프로세스가 실행 중이 아닙니다` | **1** | 기록 안 함 (14줄 → 14줄) |
| 멈춘 동안의 cron 실행 | 같은 `[ERROR]` 가 `cron.log` 에 남음 | — | — |
| 앱 재시작 | 다시 `[OK]` | 0 | 기록함 |

설계 상세(프로세스 식별 방법, 파싱 방식, 방화벽 확인을 root 없이 하는 방법)는 [`design.md`](design.md).

## 8. monitor.log — 누적 기록과 용량 관리

**포맷**: `[YYYY-MM-DD HH:MM:SS] PID:<pid> CPU:<n.n>% MEM:<n.n>% DISK_USED:<n>%`

**실제 결과** ([`08-monitor-log.txt`](evidence/08-monitor-log.txt), cron 이 매분 02초 전후에 기록)

```
[2026-10-21 00:50:02] PID:602 CPU:5.5% MEM:34.6% DISK_USED:24%
[2026-10-21 00:51:02] PID:602 CPU:4.9% MEM:35.1% DISK_USED:24%
[2026-10-21 00:52:02] PID:602 CPU:4.9% MEM:34.9% DISK_USED:24%
[2026-10-21 00:53:03] PID:602 CPU:5.5% MEM:35.0% DISK_USED:24%
[2026-10-21 00:54:02] PID:602 CPU:3.8% MEM:35.4% DISK_USED:24%
```

**용량 관리 (10MB / 10개)**: monitor.sh 가 기록 직전에 크기를 확인해 10MB 이상이면 `monitor.log → .1 → … → .9` 로 밀어내고 가장 오래된 것을 버립니다. 항상 **현재 파일 + 순환 9개 = 최대 10개**입니다. 동시에 두 번 실행돼도 꼬이지 않게 `flock` 으로 잠급니다.
logrotate 를 쓰는 대안은 [`config/logrotate.d/agent-app`](../config/logrotate.d/agent-app) 에 있습니다(두 방식을 함께 쓰지 않음).
증빙 [`10-log-capacity.txt`](evidence/10-log-capacity.txt) 는 한도를 200바이트·4개로 줄여 6번 실행한 시연입니다. 실제로 `monitor.log` + `.1` ~ `.3` 의 **4개로 유지**됐습니다.

## 9. 자동 실행 — agent-admin crontab 매분

```cron
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
AGENT_ENV_FILE=/etc/agent-app/agent-app.env
* * * * * /home/agent-admin/agent-app/bin/monitor.sh --no-stats --quiet >> /var/log/agent-app/cron.log 2>&1
17 3 * * * /home/agent-admin/agent-app/bin/log-retention.sh >> /var/log/agent-app/retention.log 2>&1
```

- cron 은 로그인 셸이 아니라 `PATH` 가 짧고 `/etc/profile.d` 를 읽지 않습니다. 그래서 PATH 와 환경 파일 경로를 crontab 에 직접 적었습니다.
- monitor.sh 의 정상 결과는 `monitor.log` 에, 경고·오류(stderr 포함)는 `cron.log` 에 남아 실패 원인을 추적할 수 있습니다.
- 등록: `sudo bash setup/07-cron.sh` (기존 crontab 의 다른 줄은 유지)
- 확인 ([`09-cron.txt`](evidence/09-cron.txt)): `systemctl is-active cron` → `active`, 그리고 70초 사이에 cron 이 한 번 더 실행돼 줄이 늘었습니다.

```
## 00:54:11 monitor.log 11줄 → 70초 대기
## 00:55:21 monitor.log 12줄 (증가: 1줄)
$ grep CRON /var/log/syslog | grep agent-admin | tail -n 3
Oct 21 00:53:01 agent-server CRON[1700]: (agent-admin) CMD (/home/agent-admin/agent-app/bin/monitor.sh --no-stats --quiet >> /var/log/agent-app/cron.log 2>&1)
Oct 21 00:54:01 agent-server CRON[1825]: (agent-admin) CMD (…)
Oct 21 00:55:01 agent-server CRON[2188]: (agent-admin) CMD (…)
```

## 10. 보너스

**보너스 1 — report.sh 요약 리포트** ([`bin/report.sh`](../bin/report.sh))

**실제 결과** ([`11-report.txt`](evidence/11-report.txt), cron 이 쌓은 12개 기록)

```console
$ report.sh --file /var/log/agent-app/monitor.log --from '2026-10-21 00:45:02' --to '2026-10-21 00:55:02'
====== STATISTICS REPORT ======
Range   : 2026-10-21 00:45:02 ~ 2026-10-21 00:55:02
Period  : 2026-10-21 00:45:02 ~ 2026-10-21 00:55:02
[CPU]
  Average : 5.6%
  Maximum : 9.1% at 2026-10-21 00:48:02
  Minimum : 3.6% at 2026-10-21 00:55:02
[Memory]
  Average : 35.2%
  Maximum : 36.1% at 2026-10-21 00:49:03
  Minimum : 34.4% at 2026-10-21 00:55:02
[Disk] …
[Samples]
  Data Points: 12 samples
```

옵션: `--from/--to`(구간), `--last N`(최근 N개), `--include-rotated`(순환 파일 포함). → `11-report.txt`

**보너스 2 — 시간 기반 로그 보존** ([`bin/log-retention.sh`](../bin/log-retention.sh), 매일 03:17 cron)

| 단계 | 대상 | 동작 |
| --- | --- | --- |
| 압축 | `/var/log/agent-app/*.log`, `*.log.N` 중 7일 이상 | gzip → 무결성 검사(`gzip -t`) 통과 시에만 원본 삭제 |
| 아카이브 | 압축 파일 | `/var/log/monitor/agent-app/archive/<이름>.<날짜>.gz` (원본 수정 시각 유지) |
| 삭제 | `archive/*.gz` 중 30일 이상 | 삭제 |
| 예외 | 디렉토리 없음 / 권한 부족 / 대상 0개 | 경고 후 안전 종료 / 무엇을 못 했는지 + 종료 코드 1 / "대상 없음" |

`--dry-run` 으로 변경 없이 대상만 확인할 수 있습니다. 수행 직후에는 7일 지난 로그가 없어 [`12-retention.txt`](evidence/12-retention.txt) 는 "대상 없음" 이라, 수정 시각을 과거로 맞춘 시연용 파일로 **실제 실행**했습니다 ([`15-retention-demo.txt`](evidence/15-retention-demo.txt)):

```
[COMPRESS] /var/log/agent-app/demo-old.log.1 → /var/log/monitor/agent-app/archive/demo-old.log.1.20261013.gz   (8일 전)
[COMPRESS] /var/log/agent-app/demo-old.log → /var/log/monitor/agent-app/archive/demo-old.log.20261011.gz       (10일 전)
[DELETE] /var/log/monitor/agent-app/archive/demo-ancient.log.20260910.gz                                       (40일 전)
[DONE] compressed=2 deleted=1 errors=0
```

2일 지난 `demo-recent.log` 와 29일 지난 아카이브는 그대로 남았고, 압축본을 풀어 원본 2,500줄이 그대로인 것도 확인했습니다. 시연용 파일은 확인 후 지웠습니다.

---

## 자동화 스크립트 소스코드

| 파일 | 설명 |
| --- | --- |
| [`bin/monitor.sh`](../bin/monitor.sh) | **제출 대상**: 시스템 상태 수집 및 로깅 |
| [`bin/report.sh`](../bin/report.sh) | 보너스 1 |
| [`bin/log-retention.sh`](../bin/log-retention.sh) | 보너스 2 |
| [`bin/run-agent.sh`](../bin/run-agent.sh) | 앱 실행 도우미 (일반 계정 강제) |
| [`setup/`](../setup/) | 서버 구성 자동화 (멱등, `DRY_RUN=1` 미리 보기) |
| [`verify/collect-evidence.sh`](../verify/collect-evidence.sh) | 증빙 수집 (서버 안) |
| [`verify/remote-check.sh`](../verify/remote-check.sh) | 바깥에서 포트 · SSH 접속 확인 |
| [`tests/run-tests.sh`](../tests/run-tests.sh) | 스크립트 자동 테스트 71개 |
