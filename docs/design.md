# 설계 문서

서버 구성(권한·보안)과 관제 스크립트(monitor.sh)를 **왜 이렇게 만들었는지** 정리합니다. 무엇을 설정했는지는 [`report.md`](report.md) 에 있습니다.

- [1. 보안 기본 설정](#1-보안-기본-설정)
- [2. 권한 모델](#2-권한-모델)
- [3. monitor.sh 내부 구조](#3-monitorsh-내부-구조)
- [4. 로그 설계](#4-로그-설계)
- [5. cron 실행 환경](#5-cron-실행-환경)
- [6. 자동화 스크립트 설계 원칙](#6-자동화-스크립트-설계-원칙)
- [7. 테스트](#7-테스트)

---

## 1. 보안 기본 설정

| 설정 | 막는 위협 | 한계와 보완 |
| --- | --- | --- |
| SSH 포트 22 → 20022 | 인터넷 전체를 22번으로 훑는 **자동화 스캐너·봇의 무차별 대입**. 실제로 22번 포트 로그는 대부분 이런 봇이다 | 포트 스캔을 하면 결국 찾는다(은닉일 뿐 인증 강화가 아님). 그래서 아래 설정과 함께 쓴다 |
| `PermitRootLogin no` | 모든 서버에 있는 계정 이름 `root` 를 노린 비밀번호 추측. root 가 뚫리면 즉시 전체 권한 | 일반 계정으로 접속 → `sudo` 로 권한 상승. 누가 무엇을 했는지 `auth.log` 에 남고, 공격자는 계정 이름까지 맞혀야 한다 |
| 방화벽 allowlist (20022, 15034 만) | 실수로 띄운 서비스(DB, 디버그 서버)가 외부에 노출되는 것 | 허용 목록 방식이라 새 서비스는 **명시적으로 열어야만** 외부에서 접근된다 |

추가로 권장하는 것: 비밀번호 대신 키 인증(`PasswordAuthentication no`), fail2ban. 과제 범위 밖이라 적용하지 않았습니다.

**잠김(lockout) 방지 순서**: 방화벽에 20022 를 먼저 연다 → sshd 설정 → `sshd -t` 문법 검사 → 재시작 → 새 세션으로 접속 확인 → 기존 세션 종료. `01-ssh.sh` 는 방화벽에 20022 가 없으면 진행하지 않습니다.

## 2. 권한 모델

**원칙: 역할(그룹) 단위로 권한을 주고, 디렉토리를 민감도에 따라 나눈다.**

```
                agent-common (admin, dev, test)      agent-core (admin, dev)
                ┌───────────────────────┐            ┌─────────────────────────────┐
  공유 영역      │ upload_files  rwx      │   보안 영역 │ api_keys        rwx         │
                └───────────────────────┘            │ /var/log/agent-app rwx       │
                                                     │ bin/monitor.sh  r-x (dev rwx)│
                                                     └─────────────────────────────┘
```

| 결정 | 이유 |
| --- | --- |
| 사용자별이 아니라 **그룹별** 권한 | 사람이 바뀌어도 그룹 소속만 바꾸면 된다. 개별 ACL 을 사람마다 걸면 퇴사자 권한이 남는 사고가 생긴다 |
| api_keys 와 로그를 **agent-core 로만** | 최소 권한 원칙: QA(agent-test)는 업로드 파일만 있으면 일을 할 수 있다. 키가 유출되면 서비스 사칭이, 로그가 유출되면 내부 구조·사용자 정보가 노출된다. **필요 없는 권한은 사고의 범위만 넓힌다** |
| 디렉토리에 **setgid(2xxx)** | 새 파일이 디렉토리 그룹을 상속 → dev 가 만든 파일을 admin 이 고칠 수 있다 |
| **default ACL** `g:<그룹>:rwx` | 각자 umask(022) 때문에 새 파일이 `rw-r--r--` 로 만들어져 그룹이 못 쓰는 문제를 막는다 |
| 홈 디렉토리에 `g:agent-common:--x` | Ubuntu 22.04 홈은 750. 홈 전체를 열면 admin 의 다른 파일까지 보인다. **통과(x)만** 주면 아는 경로로만 들어갈 수 있고 목록은 볼 수 없다 |
| monitor.sh `agent-dev:agent-core 750` | 작성자(dev)만 수정, 실행자(admin)는 읽기·실행만. 실행자가 스크립트를 바꿀 수 없으니 cron 이 실행하는 코드가 몰래 바뀌지 않는다 |

검증은 "권한 비트를 눈으로 보는 것" 이 아니라 **각 계정으로 실제로 읽기/쓰기를 시도**해서 합니다(`verify/collect-evidence.sh` 의 접근 매트릭스). ACL·setgid·홈 디렉토리 권한이 겹치면 비트만 보고는 실제 결과를 틀리기 쉽기 때문입니다.

## 3. monitor.sh 내부 구조

```
main
 ├─ 0. 로그 디렉토리 존재·쓰기 확인 (없으면 exit 2) → flock 잠금
 ├─ 1. find_app_pids  ── 실패 → exit 1
 ├─ 2. port_listening ── 실패 → exit 1
 ├─ 3. firewall_state ── 비활성/불명 → 경고만
 ├─ 4. cpu_usage · mem_usage · disk_usage · proc_stats → 임계값 비교 → 경고만
 └─ 5. rotate_log → printf … >> monitor.log
```

### 프로세스 식별

| 방법 | 문제 |
| --- | --- |
| `pgrep -f agent-app` | 명령줄 전체를 검색해서 **monitor.sh 자기 자신**(`/home/agent-admin/agent-app/bin/monitor.sh`), 편집기, `tail -f …/agent-app.log` 까지 잡힌다 |
| `pgrep -x agent-app-linux-x86` | 프로세스 이름(comm)은 15자로 잘려 `agent-app-linu` 가 된다. Python 스크립트 실행(`python3 agent_app.py`)은 comm 이 `python3` |
| **채택**: `/proc/<pid>/cmdline` 의 argv[0] (또는 python 이면 argv[1]) **basename** 을 정규식 `^agent[_-]app([._-].*)?$` 과 비교, `*.sh` 제외 | 바이너리·Python 스크립트 모두 정확히 잡고 자기 자신은 제외 |

제공 앱은 PyInstaller 형식이라 **부모(부트로더)와 자식(실제 앱)** 이 같은 이름으로 2개 뜹니다. 그중 **포트를 가진 프로세스**(`ss -ltnp` 의 `pid=`, 없으면 `/proc/net/tcp` 의 소켓 inode 를 `/proc/<pid>/fd` 에서 찾음)를 고르고, 그것도 모르면 부모가 후보에 있는 자식을 고릅니다. 부모를 고르면 RSS 가 2MB 처럼 실제 앱과 전혀 다른 값이 기록됩니다(실제로 겪은 문제).

### 포트 확인

`ss -Hltn "sport = :15034"` — LISTEN 소켓만(`-l`), TCP 만(`-t`), 이름 변환 없이(`-n`), 머리글 없이(`-H`) 필터로 직접 조회합니다. `netstat` 은 deprecated 이고 grep 으로 `15034` 를 찾으면 `115034` 같은 다른 포트나 원격 주소까지 걸립니다. `ss` 가 없는 최소 환경에서는 `/proc/net/tcp` 의 `local_address` 끝 4자리(16진수 포트)와 상태 `0A`(LISTEN)를 비교합니다.

### 자원 수집

| 항목 | 방법 | `top`/`free` 를 파싱하지 않은 이유 |
| --- | --- | --- |
| CPU | `/proc/stat` 첫 줄을 1초 간격으로 두 번 읽어 `100 × (1 − Δidle / Δtotal)` (idle = idle + iowait) | `top -bn1` 의 첫 화면은 부팅 이후 평균이라 "지금" 사용률이 아니다. 출력 형식도 버전·로케일마다 다르다 |
| MEM | `/proc/meminfo` 의 `(MemTotal − MemAvailable) / MemTotal` | `MemFree` 로 계산하면 페이지 캐시(필요하면 바로 반환되는 메모리)까지 '사용 중' 으로 세서 항상 높게 나온다 |
| DISK | `df -P /` 의 Use% | `-P`(POSIX)는 장치 이름이 길어도 한 줄로 고정돼 열 번호가 밀리지 않는다 |
| 프로세스 CPU | `/proc/<pid>/stat` 의 utime+stime 을 시스템 CPU 와 **같은 1초 구간**에서 두 번 읽은 차이 | `ps -o %cpu` 는 "프로세스 시작 이후 평균" 이라 오래 돈 프로세스의 급등이 묻힌다 |
| 프로세스 MEM | `ps -o %mem=,rss=,nlwp= -p PID` | 콘솔 표시와 B4-2 확장 로그(RSS 추이)용 |

모든 계산은 `LC_ALL=C` 에서 `awk` 로 합니다. bash 는 소수 연산을 못 하고, 로케일에 따라 소수점이 `,` 가 되는 것을 막기 위해서입니다.

### 경고와 종료를 나눈 이유

| 종류 | 처리 | 이유 |
| --- | --- | --- |
| 프로세스 없음, 포트 미오픈 | **exit 1** | 서비스가 **죽은 상태**. 이 상태의 CPU/MEM 은 의미가 없고, 종료 코드로 알려야 cron·상위 모니터링이 장애로 인식한다 |
| 방화벽 비활성 | 경고, 계속 | 서비스는 동작 중. 관제를 멈추면 오히려 **기록이 끊겨** 원인 분석 데이터가 사라진다 |
| CPU/MEM/DISK 임계값 초과 | 경고, 계속 | 장애의 **전조**. 바로 이 순간의 수치가 나중에 가장 필요한 데이터다 |

방화벽 상태는 root 없이 확인해야 합니다(cron 실행자는 agent-admin). `ufw status` 는 root 전용이라 ① root 면 `ufw status` ② `sudo -n ufw status`(sudoers 에 그 명령만 허용한 경우) ③ 누구나 읽을 수 있는 `/etc/ufw/ufw.conf` 의 `ENABLED=yes` 순으로 확인합니다.

## 4. 로그 설계

**포맷을 고정한 이유**: `[YYYY-MM-DD HH:MM:SS] PID:… CPU:…% MEM:…% DISK_USED:…%`

- `key:value` 고정 순서 → `awk`, `grep 'CPU:[3-9][0-9]'` 로 바로 분석 (report.sh 가 이 포맷만 믿고 동작)
- `YYYY-MM-DD HH:MM:SS` → **문자열 정렬 = 시간 정렬**. report.sh 의 `--from/--to` 를 날짜 변환 없이 문자열 비교로 처리
- PID 기록 → PID 가 바뀐 시점 = 앱이 재시작된 시점 (장애 추적의 단서)
- 실패한 Health Check 는 monitor.log 에 쓰지 않고 stderr → `cron.log` 로 보냄. monitor.log 는 "정상 동작 중 수치" 만 담아 통계가 오염되지 않게 하고, 장애 기록은 cron.log 에서 찾는다

**`>>` 를 쓰는 이유**: `>` 는 파일을 **비우고** 쓰기 때문에 매분 이전 기록이 지워져 추이를 볼 수 없습니다. `>>` 는 끝에 덧붙입니다(append). 덧붙이기는 `O_APPEND` 로 열려서 여러 프로세스가 동시에 써도 줄이 겹쳐 쓰이지 않습니다.

**용량 관리 두 겹**

| 장치 | 기준 | 목적 |
| --- | --- | --- |
| monitor.sh 내장 순환 (필수) | **용량** 10MB, 최대 10개 | 갑자기 로그가 폭증해도 디스크를 다 쓰지 않게 상한을 건다 |
| log-retention.sh (보너스 2) | **시간** 7일 압축, 30일 삭제 | 오래된 로그를 싸게(압축) 보관하다가 보존 기간이 지나면 지운다 |

내장 순환을 logrotate 대신 기본으로 쓴 이유: logrotate 는 보통 **하루 한 번** 실행되어 `size 10M` 조건이 하루 늦게 확인됩니다. monitor.sh 는 기록할 때마다(매분) 확인합니다. logrotate 설정은 대안으로 `config/logrotate.d/agent-app` 에 두었습니다.

## 5. cron 실행 환경

cron 은 **로그인 셸이 아닙니다.** `~/.bashrc`, `/etc/profile.d/*` 를 읽지 않고 `PATH=/usr/bin:/bin` 정도만 있습니다. "직접 실행하면 되는데 cron 에서는 안 된다" 의 대부분이 이 차이입니다.

| 대응 | 위치 |
| --- | --- |
| crontab 맨 위에 `SHELL`, `PATH`, `AGENT_ENV_FILE` 지정 | `config/crontab.agent-admin` |
| 스크립트가 환경 파일을 직접 `source` + 모든 변수에 기본값 | `bin/monitor.sh` |
| 절대 경로로 실행, 출력은 `>> cron.log 2>&1` | 실패해도 원인이 남는다 |
| `flock` 잠금 | 이전 실행이 길어져도 다음 분의 실행과 겹치지 않는다 |

## 6. 자동화 스크립트 설계 원칙

| 원칙 | 적용 |
| --- | --- |
| 멱등성 | `setup/*.sh` 는 여러 번 실행해도 결과가 같다 (있으면 건너뛰고 상태만 맞춤) |
| 미리 보기 | `DRY_RUN=1` 이면 실행할 명령만 출력 |
| 되돌릴 수 있게 | 설정 파일 수정 전 `.bak.<시각>` 백업, sshd 는 문법 검사 실패 시 자동 복구 |
| 실패를 숨기지 않음 | `set -euo pipefail`(setup), 종료 코드 구분(monitor 0/1/2) |
| 정적 분석 | ShellCheck 경고 0 (CI 에서 검사) |

## 7. 테스트

`bash tests/run-tests.sh` — root 나 실제 서버 설정 없이 임시 폴더와 가짜 앱으로 71개 항목을 검사합니다(일반 계정 기준. root 로 실행하면 "쓰기 불가" 테스트 1개는 건너뜀). Ubuntu 22.04(VM, `ss` 경로)와 Ubuntu 24.04(컨테이너, `/proc/net/tcp` 경로) 양쪽에서 모두 통과를 확인했습니다.

| 영역 | 확인 내용 |
| --- | --- |
| monitor.sh | 정상/프로세스 없음/포트 없음(exit 1), 프로세스 순간 CPU(바쁜 프로세스 ≥ 50%), 이름에 agent-app 이 들어간 `*.sh` 오탐 없음, 임계값 경고(종료 안 함), 방화벽 비활성 경고, 로그 포맷 정규식, `>>` 누적, 순환 후 파일 수 상한, 실행 환경 오류(exit 2) |
| report.sh | 평균·최대·최소·시각, 구간 필터, `--last`, 순환 파일 포함, 형식 다른 줄 제외, 잘못된 입력 |
| log-retention.sh | 7일 경계(6일은 유지), 30일 경계(29일은 유지), 무결성, 수정 시각 보존, dry-run, 디렉토리 없음 |
| 전체 | `bash -n` 문법, ShellCheck(있으면) |
