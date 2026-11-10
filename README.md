# linux-server-ops

> Linux server hardening and Bash-based monitoring automation with cron scheduling and log rotation
> 리눅스 서버 보안 설정과 Bash 기반 시스템 모니터링·로그 관리 자동화

![Bash](https://img.shields.io/badge/bash-5.x-4EAA25?logo=gnubash&logoColor=white)
![Ubuntu](https://img.shields.io/badge/Ubuntu-22.04%20LTS-E95420?logo=ubuntu&logoColor=white)
![ShellCheck](https://img.shields.io/badge/ShellCheck-0%20warnings-success)
![Tests](https://github.com/maebsy/linux-server-ops/actions/workflows/tests.yml/badge.svg)

다중 사용자 서버에서 **SSH·방화벽 보안 설정 → 역할 기반 계정·권한(ACL) → 앱 실행 환경 → 관제 스크립트 → cron 자동화 → 로그 용량·보존 관리**까지를 직접 설계하고 스크립트로 자동화했습니다.

- **monitor.sh** — 프로세스·포트 Health Check(실패 시 `exit 1`), 방화벽·임계값 경고, CPU/MEM/DISK 를 `/proc` 에서 직접 계산해 고정 포맷으로 기록, 10MB×10개 내장 순환
- **재현 가능한 서버 구성** — `setup/` 스크립트 7개(멱등, `DRY_RUN=1` 미리 보기, 설정 백업, `sshd -t` 실패 시 자동 복구)
- **증빙 자동 수집** — `verify/collect-evidence.sh` 가 체크리스트 8개 항목을 `docs/evidence/*.txt` 로 저장, **계정별 실제 접근 테스트** 매트릭스 포함. `verify/remote-check.sh` 는 다른 PC 에서 포트·SSH 접속을 확인
- **운영 도구** — 포트 미개방 원인 8단계 진단(`bin/diagnose-port.sh`), cron ↔ syslog ↔ monitor.log 연동 점검(`verify/check-cron.sh`), 경고 알림 훅(`ALERT_CMD` → `bin/alert.sh`, syslog · 웹훅), SSH 무차별 대입 자동 차단(`setup/08-fail2ban.sh`, 선택)
- **실제 수행 증빙** — systemd 로 부팅한 Ubuntu 22.04 컨테이너에서 setup → 앱 Boot → cron 누적 → 장애 상황 → 로그 보존 → 동료 평가 1·2·3차 보완(firewalld · nginx 전환 · cron 장애 복구 · 무차별 대입 차단 · 계정 정책 · 응답시간 · logrotate 전환 · TLS 등)까지 실행한 결과 31개 ([`docs/evidence/`](docs/evidence/README.md))
- **동료 평가 피드백 반영** — 19개 항목의 부족한 점 · 보완을 모두 반영하고 실측으로 확인 ([`docs/feedback-checklist.md`](docs/feedback-checklist.md)), FAIL 이었던 웹서버 전환은 [`docs/webserver-migration.md`](docs/webserver-migration.md)
- **제공 바이너리로 실제 검증** — Boot Sequence 5단계 통과까지 확인하며 발견한 명세와 실제 동작의 차이를 기록
- **테스트 123개 + ShellCheck 경고 0** — Ubuntu 22.04 / 24.04 에서 통과

## 목차

- [빠른 시작](#빠른-시작)
- [구성 요소](#구성-요소)
- [monitor.sh](#monitorsh)
- [서버 구성 요약](#서버-구성-요약)
- [요구사항 구현 매핑](#요구사항-구현-매핑)
- [선택(보너스) 과제 구현 내역](#선택보너스-과제-구현-내역)
- [수행 결과 (증빙)](#수행-결과-증빙)
- [프로젝트 구조](#프로젝트-구조)
- [테스트](#테스트)
- [문서](#문서)

## 빠른 시작

Ubuntu 22.04 LTS 서버(또는 VM)에서 실행합니다.

```bash
git clone https://github.com/maebsy/linux-server-ops.git
cd linux-server-ops

DRY_RUN=1 bash setup/run-all.sh      # 1) 실행될 명령 미리 보기 (아무것도 바꾸지 않음)
sudo bash setup/run-all.sh           # 2) 계정 → 디렉토리/ACL → 환경변수 → 스크립트 설치 → 방화벽 → SSH → cron

# 3) 제공 앱(agent-app.zip)을 $AGENT_HOME 에 풀고 agent-admin 으로 실행
sudo install -o agent-admin -g agent-common -m 0750 agent-app-linux-x86 /home/agent-admin/agent-app/
sudo -iu agent-admin /home/agent-admin/agent-app/bin/run-agent.sh              # Boot Sequence 확인 (Ctrl+C)
sudo -iu agent-admin /home/agent-admin/agent-app/bin/run-agent.sh --background # 관제용 백그라운드 실행

sudo bash verify/collect-evidence.sh  # 4) 증빙 수집 → docs/evidence/*.txt
```

원격(SSH)으로 접속 중이라면 `run-all.sh` 가 **방화벽에 20022 를 먼저 연 뒤** SSH 포트를 바꿉니다. 지금 22번으로 접속해 있다면 `02-firewall.sh` 가 중단하며 `--keep-22` 사용법을 안내합니다. 끝나면 새 터미널에서 `ssh -p 20022` 접속을 확인한 뒤 기존 세션을 닫으세요.

**SSH 설정을 바꾼 뒤 안전 점검** (기존 세션은 끝까지 열어 둔 채로, 실측 [`28`](docs/evidence/28-feedback-round3.txt) ①):

```bash
sudo sshd -t && sudo systemctl restart ssh && systemctl is-active ssh   # 문법 검사 통과 후에만 재시작 → active
ss -Hltnp | grep sshd                                                   # 0.0.0.0:20022 · [::]:20022 만, 22 없음
sudo sshd -T | grep -Ei '^(port|permitrootlogin) '                      # port 20022 · permitrootlogin no
ssh -p 20022 agent-admin@<서버>                                         # 다른 터미널(다른 PC)에서 새 포트로 접속 성공 확인
bash verify/remote-check.sh <서버> agent-admin                          # 바깥에서: 20022·15034 open, 22 닫힘, root 거부
```

새 포트 접속이 확인되기 전에 기존 세션을 닫으면, 설정이 틀렸을 때 서버에 다시 들어갈 방법이 없습니다(콘솔 접근 필요).

## 구성 요소

| 구분 | 파일 | 역할 |
| --- | --- | --- |
| **관제 (필수)** | [`bin/monitor.sh`](bin/monitor.sh) | Health Check, 상태 점검, 자원 수집, 임계값 경고, 로그 기록·순환 |
| 보너스 1 | [`bin/report.sh`](bin/report.sh) | monitor.log 평균·최대·최소·샘플 수, 구간 분석 |
| 보너스 2 | [`bin/log-retention.sh`](bin/log-retention.sh) | 7일 압축 → 아카이브 이동 → 30일 삭제 |
| 실행 도우미 | [`bin/run-agent.sh`](bin/run-agent.sh) | 일반 계정 강제, 환경 로드, CPU 별 바이너리 선택, 백그라운드 실행 |
| 운영 도구 | [`bin/diagnose-port.sh`](bin/diagnose-port.sh) | 프로세스는 있는데 포트가 안 열릴 때 원인 8단계 진단 (바인딩 · 오타 · 충돌 · 권한 · 방화벽) |
| 운영 도구 | [`bin/alert.sh`](bin/alert.sh) | `ALERT_CMD` 알림 훅 — syslog · 웹훅, 같은 경고는 10분에 1번 |
| 운영 도구 | [`verify/check-cron.sh`](verify/check-cron.sh) | crontab · cron 서비스 · 실행 권한 · syslog CRON · monitor.log · cron.log · cron 환경(`env -i`) env 로드 7단계 점검과 복구 명령 |
| 서버 구성 | [`setup/`](setup/) | `01-ssh` `02-firewall` `03-accounts` `04-directories` `05-environment` `06-install-monitor` `07-cron` `08-fail2ban`(선택) `09-logrotate`(선택) `run-all` |
| 설정 원본 | [`config/`](config/) | sshd 설정 조각, crontab, profile.d, logrotate(`config/logrotate.d/agent-app`, `09-logrotate.sh` 로 전환), (선택) fail2ban jail, (예시) nginx 관제 env |
| 증빙 | [`verify/collect-evidence.sh`](verify/collect-evidence.sh) | 체크리스트 증빙 12개 파일 생성 (`ss -tulnp` 전체, check-cron · diagnose-port 결과 포함) |

## monitor.sh

출력 예시입니다(방화벽이 켜진 서버 기준, 수치는 실행마다 다름). 제공 바이너리로 실제 실행한 그대로의 기록은 [`docs/verification.md`](docs/verification.md) 에 있습니다.

```console
$ sudo -u agent-admin /home/agent-admin/agent-app/bin/monitor.sh
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app'... [OK] (PID: 15491)
Checking port 15034... [OK]
Checking firewall... [OK] (active)

[RESOURCE MONITORING]
CPU Usage : 32.3%
MEM Usage : 10.1%
DISK Used : 32%
Process   : PID 15491 CPU 19.6% MEM 2.3% RSS 189.4MB Threads 1

[WARNING] CPU threshold exceeded (32.3% > 20%)
[WARNING] MEM threshold exceeded (10.1% > 10%)

====== STATISTICS REPORT ======        ← 터미널에서 실행하면 최근 10개 통계를 함께 출력
...
[INFO] Log appended: /var/log/agent-app/monitor.log
```

```
/var/log/agent-app/monitor.log
[2026-10-12 17:59:47] PID:15491 CPU:32.3% MEM:10.1% DISK_USED:32%
[2026-10-12 18:00:49] PID:15491 CPU:14.9% MEM:7.5% DISK_USED:32%
[2026-10-12 18:01:50] PID:15491 CPU:8.0% MEM:9.3% DISK_USED:32%
│                     │         │        │        └ 루트 파티션 사용률, % (정수, df Use%)
│                     │         │        └ 메모리 사용률, % (소수 1자리, MemAvailable 기준)
│                     │         └ 시스템 CPU 사용률, % (소수 1자리, 1초 동안 측정)
│                     └ 포트를 연 앱의 PID (바뀌면 재시작된 것)
└ 기록 시각, 서버 로컬 시간(KST) 초 단위
```

| 단계 | 방법 | 실패 시 |
| --- | --- | --- |
| 프로세스 | `/proc/<pid>/cmdline` 의 실행 파일 이름 비교 (자기 자신·`*.sh` 제외, PyInstaller 부모/자식 중 포트 주인 선택) | `exit 1` |
| 포트 | `ss -Hltn "sport = :15034"` (없으면 `/proc/net/tcp`) | `exit 1` |
| 방화벽 | `ufw status` → `sudo -n ufw status` → `/etc/ufw/ufw.conf` (root 없이 확인) | `[WARNING]` |
| CPU | `/proc/stat` 1초 간격 2회 차이 | |
| MEM | `(MemTotal − MemAvailable) / MemTotal` | |
| DISK | `df -P /` Use% | |
| 임계값 | CPU > 20%, MEM > 10%, DISK > 80% | `[WARNING]` |
| 기록 | `>>` 덧붙이기, 10MB 이상이면 `.1~.9` 순환(최대 10개), `flock` 잠금. `/etc/logrotate.d/agent-app` 이 있으면 내장 순환은 건너뛰고 logrotate 에 맡김(둘 중 하나만 동작) | 쓰기 불가면 `exit 2` |

종료 코드: `0` 정상(경고 포함) · `1` Health Check 실패 · `2` 실행 환경 오류.

**실패했을 때 바로 쓰는 명령** — monitor.sh 가 `[ERROR]` 다음 줄 `[HINT]` 로 같은 내용을 안내합니다(실측 [`28`](docs/evidence/28-feedback-round3.txt) ⑤: 안내대로 재기동 → 다시 exit 0).

| 증상 | 확인 | 수동 복구 |
| --- | --- | --- |
| `앱 프로세스가 실행 중이 아닙니다` (exit 1) | `tail -n 30 /var/log/agent-app/agent-app.out` | `sudo -iu agent-admin /home/agent-admin/agent-app/bin/run-agent.sh --background` |
| `포트가 LISTEN 상태가 아닙니다` (exit 1) | `sudo bash bin/diagnose-port.sh` (8단계 원인 진단) | 첫 `[FAIL]` 의 `→` 조치 — 예: 포트 선점이면 그 PID 정리 후 재기동 |
| `로그 디렉토리에 쓸 권한이 없습니다` (exit 2) | `sudo -u agent-admin test -w /var/log/agent-app; echo $?` | `sudo bash setup/04-directories.sh && sudo bash setup/06-install-monitor.sh` |
| cron 에서만 기록이 안 늘어남 | `sudo bash verify/check-cron.sh` (7단계) | 실패한 단계의 `→ 복구:` 명령 |

**cron 실패 알림** — crontab 은 출력을 `cron.log` 로 보내 cron 메일이 가지 않으므로, env 파일에 `ALERT_CMD=/home/agent-admin/agent-app/bin/alert.sh` 를 넣어 Health Check 실패를 syslog(+웹훅)로 받습니다. cron 자체가 멈춘 경우까지 잡으려면 `check-cron.sh` 를 root crontab 에 주기적으로 겁니다 — 방법 3가지 비교는 [`docs/operations.md` §5](docs/operations.md#5-cron-장애-점검과-복구).
모든 값은 환경변수로 바꿀 수 있습니다(`CPU_WARN`, `MEM_WARN`, `DISK_WARN`, `AGENT_PORT`, `MAX_LOG_SIZE_BYTES`, `MAX_LOG_FILES`, `APP_PROCESS_REGEX` …, `monitor.sh --help`).
`ALERT_CMD=…/bin/alert.sh` 를 주면 경고(WARNING)·Health Check 실패(CRITICAL) 때 알림 훅을 실행합니다(결과에는 영향 없음, [`docs/operations.md` §8](docs/operations.md#8-경고-알림-연동)).
`MONITOR_LOG_FORMAT=extended` 를 주면 프로세스 RSS·스레드 수를 덧붙여 기록합니다(다음 미션 B4-2 장애 분석에서 재사용).
방화벽은 `ufw status` → `sudo -n ufw status` → `/etc/ufw/ufw.conf` 순서로 확인합니다(일반 계정인 cron 실행자도 판단 가능). `UFW_USE_STATUS=0` 이면 설정 파일만 봅니다.

## 서버 구성 요약

| 항목 | 설정 |
| --- | --- |
| SSH | `Port 20022`, `PermitRootLogin no` (`/etc/ssh/sshd_config.d/00-agent-hardening.conf`) |
| 무차별 대입 | (선택) fail2ban — 5회 실패/10분 → 1시간 차단, UFW 로 차단 (`sudo bash setup/08-fail2ban.sh`, [`docs/operations.md` §9](docs/operations.md#9-ssh-무차별-대입-대응)) |
| 방화벽 | UFW: 기본 deny incoming, 허용 `20022/tcp`, `15034/tcp` 만 (firewalld 판도 제공) |
| 그룹 | `agent-common` = admin, dev, test · `agent-core` = admin, dev |
| 공유 디렉토리 | `upload_files` — agent-common R/W (setgid + default ACL) |
| 보안 디렉토리 | `api_keys`, `/var/log/agent-app` — **agent-core 만** R/W, 그 외 접근 불가 |
| monitor.sh | `agent-dev:agent-core 750`, agent-admin 의 crontab 매분 실행 (root crontab 에는 두지 않음 — `check-cron.sh` 가 교차 확인) |
| 로그 용량 · 보존 | 기본: monitor.sh 내장 순환(10MB × 10개). logrotate 를 원하면 `sudo bash setup/09-logrotate.sh` — 설정이 설치되면 내장 순환은 자동으로 멈춤. 기간 보존은 `log-retention.sh`(7일 압축 · 30일 삭제)가 따로 담당 |
| 환경변수 | `/etc/agent-app/agent-app.env` 한 곳에서 관리 → 로그인 셸·cron·스크립트가 같은 값 사용 |

| 접근 테스트 | agent-admin | agent-dev | agent-test |
| --- | :---: | :---: | :---: |
| upload_files 쓰기 | O | O | O |
| t_secret.key 읽기 / api_keys 쓰기 | O | O | X |
| /var/log/agent-app 쓰기 | O | O | X |
| monitor.sh 실행 / 수정 | O / X | O / O | X / X |

> **명세와 실제 동작의 차이**: 제공 바이너리는 과제 문서와 달리 `AGENT_KEY_PATH` 로 **디렉토리**(`…/api_keys`)를, 키 파일 이름으로 **`secret.key`** 를 요구합니다. Boot 실패 메시지를 근거로 확인했고, 명세의 `t_secret.key` 를 원본으로 두고 `secret.key` 를 링크로 연결했습니다 → [`docs/report.md` 5-1](docs/report.md#5-1-명세와-실제-동작의-차이)

## 요구사항 구현 매핑

| 요구사항 | 구현 | 증빙 |
| --- | --- | --- |
| SSH 20022, Root 원격 차단 | `setup/01-ssh.sh`, `config/sshd_config.d/` | `01-ssh.txt`, `13-remote-check.txt` |
| UFW 활성화, 20022·15034 만 허용 | `setup/02-firewall.sh` | `02-firewall.txt`, `13-remote-check.txt` |
| 계정 3개, 그룹 2개 | `setup/03-accounts.sh` | `03-accounts.txt` |
| 디렉토리·권한·ACL | `setup/04-directories.sh` | `04-permissions.txt` (접근 매트릭스) |
| 환경변수, 키 파일 | `setup/05-environment.sh`, `04-directories.sh` | `05-environment.txt` |
| 일반 계정 실행, Boot 5단계 OK, 0.0.0.0:15034 | `bin/run-agent.sh` | `06-boot.txt`, `06a-boot-foreground.txt` (TTY 기록) |
| monitor.sh 위치·소유·권한 | `setup/06-install-monitor.sh` | `07-monitor.txt` |
| Health Check 실패 시 exit 1 | `monitor.sh` | 테스트, `14-failure-cases.txt` |
| 방화벽 점검·임계값 경고(종료 안 함) | `monitor.sh` | `07-monitor.txt`, `14-failure-cases.txt`, 테스트 |
| 로그 포맷, 누적 | `monitor.sh` | `08-monitor-log.txt` |
| 10MB / 10개 유지 | `monitor.sh::rotate_log` | `10-log-capacity.txt` |
| agent-admin crontab 매분, 1~2분 내 누적 | `setup/07-cron.sh`, `config/crontab.agent-admin` | `09-cron.txt` |
| 수행 내역서 | [`docs/report.md`](docs/report.md) | |

## 선택(보너스) 과제 구현 내역

| 보너스 | 구현 | 확인 |
| --- | --- | --- |
| **보너스 1 — report.sh 요약 리포트** | CPU/MEM/DISK 평균·최대(시각)·최소(시각), 샘플 수. `--from/--to` 구간 분석, `--last N`, `--include-rotated`(순환 파일까지 시간순), 형식이 다른 줄 제외, 잘못된 입력 검증. monitor.sh 를 터미널에서 실행하면 자동으로 함께 출력 | `11-report.txt`, 테스트 12개 |
| **보너스 2 — 시간 기반 로그 보존** | `*.log`/`*.log.N` 중 7일 이상 → gzip → 무결성 검사 후 원본 삭제 → `/var/log/monitor/agent-app/archive/` 이동(원본 수정 시각 유지) → 30일 이상 아카이브 삭제. 디렉토리 없음·권한 부족·대상 0개 안전 처리, `--dry-run`, 매일 03:17 cron | `12-retention.txt`, 테스트 13개 |

## 수행 결과 (증빙)

systemd 로 부팅한 **Ubuntu 22.04.5 컨테이너**(sshd · UFW · cron 이 실제 서비스로 동작)에 `setup/run-all.sh` 를 실행하고, 제공 바이너리를 agent-admin 으로 띄운 뒤 증빙을 수집했습니다(2026-10-21). 미션 6장이 "컨테이너/VM" 실습 환경을 허용합니다.

| 확인한 것 | 결과 | 증빙 |
| --- | --- | --- |
| SSH | `sshd -T` → `port 20022`, `permitrootlogin no` / 바깥에서 agent-admin 접속 성공, root 는 키가 있어도 `Permission denied` | `01`, `13` |
| 방화벽 | UFW active, 허용 20022 · 15034 만 / 바깥에서 22 · 8080(LISTEN 중) 은 응답 없음(DROP) | `02`, `13` |
| 계정 · 권한 | 계정별 실제 접근 테스트 6개 항목이 기대값과 모두 일치 | `03`, `04` |
| 앱 | Boot 5단계 `[OK]` + `Agent READY`, `0.0.0.0:15034` / 명세값 그대로일 때의 실패 2가지도 재현 | `06`, `06a`, `06b` |
| monitor.sh · cron | 정상 exit 0, 매분 누적(70초 사이 증가), 방화벽 꺼짐 → 경고만, 앱 중지 → exit 1 + 기록 안 함 | `07`, `08`, `09`, `14` |
| 용량 · 보너스 | 순환 4개 유지 시연, report.sh 12 samples, 오래된 로그 압축 2 · 아카이브 삭제 1 | `10`, `11`, `15` |
| 피드백 보완 (2026-11-09) | setup 전후 포트, firewalld 서버, Boot 단계별, exit 1·2, cron 장애 2종 복구, 포트 원인 6가지 진단, fail2ban 차단·해제, nginx 전환·롤백, logrotate, 알림, `>` 실수 | `16` ~ `26` |

전체 목록과 재현 절차(Docker): [`docs/evidence/README.md`](docs/evidence/README.md) · 내역서: [`docs/report.md`](docs/report.md)

> 컨테이너는 호스트 커널을 함께 쓰므로 monitor.sh 의 CPU · MEM · DISK 는 호스트 전체 값입니다. 실제 VM 에서 같은 절차(`sudo bash setup/run-all.sh` → 앱 실행 → `sudo bash verify/collect-evidence.sh`)로 다시 수집할 수 있습니다.

## 프로젝트 구조

```
linux-server-ops/
├── bin/
│   ├── monitor.sh            # 관제 스크립트 (설치: $AGENT_HOME/bin, agent-dev:agent-core 750)
│   ├── report.sh             # [보너스 1] 요약 리포트
│   ├── log-retention.sh      # [보너스 2] 압축·아카이브·삭제
│   ├── run-agent.sh          # 앱 실행 도우미
│   ├── diagnose-port.sh      # 포트 미개방 원인 8단계 진단
│   └── alert.sh              # 경고 알림 훅 (ALERT_CMD)
├── setup/                    # 서버 구성 자동화 (sudo, 멱등, DRY_RUN=1)
├── config/
│   ├── sshd_config.d/00-agent-hardening.conf
│   ├── crontab.agent-admin
│   ├── profile.d/agent-app.sh
│   ├── logrotate.d/agent-app # (대안) logrotate 방식
│   ├── fail2ban/jail.d/      # (선택) SSH 무차별 대입 자동 차단
│   └── examples/monitor-nginx.env  # 관제 대상을 nginx 로 바꿀 때의 env
├── verify/
│   ├── collect-evidence.sh   # 서버 안에서 증빙 수집 → docs/evidence/
│   ├── remote-check.sh       # 다른 PC 에서 포트 · SSH 접속 확인
│   ├── check-cron.sh         # cron ↔ syslog ↔ monitor.log 연동 점검
│   └── container/Dockerfile  # 증빙 수집에 쓴 systemd Ubuntu 22.04 환경
├── tests/
│   ├── run-tests.sh          # 123개 항목 (root 로 실행하면 권한 테스트 2개 생략)
│   └── fake_agent_app.py     # 테스트용 가짜 앱 (포트 LISTEN)
└── docs/
    ├── report.md             # 요구사항 수행 내역서 (제출 문서)
    ├── design.md             # 설계 이유
    ├── checklist.md          # 체크리스트 답변서
    ├── feedback-checklist.md # 동료 평가 피드백 19항목 반영 체크리스트
    ├── operations.md         # 운영 매뉴얼 (진단 · 복구 · 알림 · 긴급 대응)
    ├── webserver-migration.md # 관제 대상을 웹서버(nginx)로 바꾸는 가이드 + 실측
    ├── verification.md       # 제공 바이너리로 실제 검증한 기록
    ├── evidence/             # 실제 수행 증빙 31개 + README(환경 · 재현 방법)
    └── presentation.html     # 동료 평가 발표 슬라이드
```

## 테스트

```bash
bash tests/run-tests.sh      # root 불필요, 임시 폴더와 가짜 앱 사용
```

monitor.sh(정상·실패·경고·순환·오류 입력·알림 훅), report.sh(통계·구간·순환 파일), log-retention.sh(7일·30일 경계, 무결성, dry-run, 디렉토리 없음), diagnose-port.sh(미개방·루프백·다른 포트·충돌·방화벽 규칙), check-cron.sh(오래된 기록·crontab 누락·cron.log 오류·syslog 형식·cron 환경 env 로드)와 모든 스크립트의 문법·ShellCheck 를 검사합니다. Ubuntu 22.04(`ss` 경로)와 24.04(`/proc/net/tcp` 경로)에서 모두 통과했고, GitHub Actions 가 push 마다 실행합니다.

## 문서

| 문서 | 내용 |
| --- | --- |
| [`docs/report.md`](docs/report.md) | **요구사항 수행 내역서**: 설정·명령어 기록·확인 방법·증빙 체크리스트 |
| [`docs/design.md`](docs/design.md) | 보안 설정의 위협 모델, 권한 모델, monitor.sh 내부 구조, 로그·cron 설계 |
| [`docs/checklist.md`](docs/checklist.md) | 미션 체크리스트 전 항목의 근거와 답변 |
| [`docs/verification.md`](docs/verification.md) | 제공 바이너리로 Boot·monitor·report 를 실제 실행한 기록 |
| [`docs/feedback-checklist.md`](docs/feedback-checklist.md) | **동료 평가 피드백 반영 체크리스트** — 19항목의 부족한 점·보완과 반영 근거, 보완하며 찾은 문제 |
| [`docs/operations.md`](docs/operations.md) | 운영 매뉴얼 — 환경별 기준, 로그 파싱, 순환 방식 선택, cron·권한·포트 장애 진단과 복구, 알림, 무차별 대입, firewalld, 긴급 대응, Boot 단계 |
| [`docs/webserver-migration.md`](docs/webserver-migration.md) | 관제 대상을 웹서버(nginx)로 바꿀 때의 체크포인트·절차·롤백, nginx 실측 결과 |
| [`docs/presentation.html`](docs/presentation.html) | 동료 평가 발표 슬라이드 77장 (65~71쪽 피드백 반영) (브라우저로 열기, ← → 넘기기 · N 발표자 노트 · 인쇄하면 PDF) |
