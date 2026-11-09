# 운영 매뉴얼

동료 평가에서 지적된 보완점(운영 환경 차이, 로그 포맷 활용, 리다이렉션 사고, 순환 방식 선택, cron·권한 장애 대응 등)을 **평가용 설명이 아니라 실제 운영 절차**로 다시 정리한 문서입니다. 왜 이렇게 만들었는지는 [`design.md`](design.md), 항목별 충족 근거는 [`checklist.md`](checklist.md) 에 있고, 이 문서는 "운영 중에 무엇을 어떻게 확인·복구하는가" 에 집중합니다. 각 절 끝에는 관련 증빙([`evidence/`](evidence/README.md)) 링크를 둡니다.

- [1. 운영 환경별 선택 기준 (컨테이너 / VM / 물리 서버)](#1-운영-환경별-선택-기준-컨테이너--vm--물리-서버)
- [2. monitor.log 포맷과 파싱 예시](#2-monitorlog-포맷과-파싱-예시)
- [3. 리다이렉션 실수 사례 (`>` 와 `>>`)](#3-리다이렉션-실수-사례--와-)
- [4. 로그 순환 방식 선택 지침 (내장 순환 vs logrotate)](#4-로그-순환-방식-선택-지침-내장-순환-vs-logrotate)
- [5. cron 장애 점검과 복구](#5-cron-장애-점검과-복구)
- [6. 권한 점검 · 복구 · 감사](#6-권한-점검--복구--감사)
- [7. 포트 미개방 진단 체크리스트](#7-포트-미개방-진단-체크리스트)
- [8. 경고 알림 연동](#8-경고-알림-연동)
- [9. SSH 무차별 대입 대응](#9-ssh-무차별-대입-대응)
- [10. firewalld 환경 적용](#10-firewalld-환경-적용)
- [11. 로그 급증 긴급 대응](#11-로그-급증-긴급-대응)
- [12. Boot Sequence 단계별 확인](#12-boot-sequence-단계별-확인)

---

## 1. 운영 환경별 선택 기준 (컨테이너 / VM / 물리 서버)

monitor.sh 는 세 환경에서 모두 돌지만, **값을 읽는 소스와 신뢰도가 다릅니다.** 컨테이너에서 `/proc/stat`·`/proc/meminfo` 를 읽으면 **컨테이너 자신이 아니라 호스트 전체**의 값이 나옵니다(증빙 `evidence/README.md` 에도 "컨테이너의 CPU/MEM 은 호스트 값" 이라고 적어 두었습니다). 이 한계를 모르고 숫자를 믿으면 "컨테이너는 한가한데 CPU 90%" 같은 오판이 생깁니다.

| 항목 | 컨테이너 | VM | 물리 서버 | 이 저장소의 선택 |
| --- | --- | --- | --- | --- |
| 프로세스 탐지 | `/proc/<pid>/cmdline` (PID 네임스페이스 안에서 그대로 보임) | 동일 | 동일 | `find_app_pids` — argv basename 정규식, 세 환경 공통 |
| 포트 확인 | 최소 이미지엔 iproute2(`ss`)가 없어 **`/proc/net/tcp`** 로 대체 | 보통 `ss` 사용 | `ss` 사용 | `port_listening` 이 `ss` 없으면 `/proc/net/tcp` 자동 대체 |
| CPU / MEM 값 | `/proc/stat`·`/proc/meminfo` 는 **호스트 값**. 컨테이너 몫은 cgroup v2 `/sys/fs/cgroup/cpu.stat`(usage_usec), `memory.current` / `memory.max` | VM 커널이 곧 경계라 `/proc` 값이 VM 자신의 값 | `/proc` 값이 하드웨어 전체 값 | 기본은 `/proc` (VM·물리 기준). 컨테이너 자신의 사용량이 필요하면 cgroup 파일을 읽도록 확장 |
| 디스크 | 컨테이너 레이어/마운트 기준 `df -P /` (오버레이FS) | 게스트 파일시스템 | 물리 파티션 | `disk_usage` = `df -P /` 공통 |
| 방화벽 | netns 안에만 룰이 걸리고 **보통 호스트/오케스트레이터가 담당** → 컨테이너 안에서는 unknown/none 이 정상 | VM 안에서 UFW/firewalld | 호스트 UFW/firewalld | `firewall_state` 가 없으면 경고만(종료 안 함) |
| 스케줄러 | 컨테이너엔 cron 데몬이 없는 경우가 많음 → **호스트 cron** 또는 **Kubernetes CronJob** | 게스트 cron | 호스트 cron | `config/crontab.agent-admin` (host/VM cron 기준) |
| 로그 수집 | **stdout 수집이 표준**(도커/쿠버가 수집) | 파일 로그 + journald | 파일 로그 + journald | monitor.log 파일 기록(파일 수집 전제) |

**선택 기준 요약**

- **컨테이너**: 리소스 수치는 cgroup 파일로 바꿔 읽고, 방화벽·cron 은 컨테이너가 아니라 호스트/오케스트레이터 책임으로 두며, 로그는 파일 대신 stdout 으로 내보내는 것을 우선합니다.
- **VM**: 과제 기본 구성 그대로가 가장 자연스럽습니다(`/proc` 값 = VM 값, 게스트에서 UFW·cron 운영).
- **물리 서버**: VM 과 동일하되 디스크 다중 파티션·하드웨어 센서(온도, SMART)까지 모니터링 대상을 넓힐 여지가 있습니다.

**포트 확인에 `ss` 를 쓰는 이유 (플랫폼별 가용성)** — `ss` 는 iproute2 패키지라 Ubuntu·Debian·RHEL/Rocky 기본 설치에 들어 있고, `netstat` 은 폐기 예정인 net-tools 패키지라 **Ubuntu 22.04 기본 설치에 없습니다**(실측: `dpkg -S /bin/ss` → `iproute2`, `netstat` 없음 — `27-feedback-round2.txt` ⑧). 최소 이미지 컨테이너처럼 둘 다 없는 곳에서는 커널이 직접 내보내는 `/proc/net/tcp` 를 읽습니다. 그래서 monitor.sh 는 `ss` → `/proc/net/tcp` 순서로 시도하고 `netstat` 에는 의존하지 않습니다.

📄 `evidence/16-ports.txt`(포트 탐지 경로), `evidence/README.md`(컨테이너에서 호스트 값이 보임을 명시)

## 2. monitor.log 포맷과 파싱 예시

**기본(basic) 포맷** — 한 줄 예시:

```
[2026-10-12 17:59:47] PID:15491 CPU:32.3% MEM:10.1% DISK_USED:32%
```

| 필드 | 예 | 의미 |
| --- | --- | --- |
| `[YYYY-MM-DD HH:MM:SS]` | `[2026-10-12 17:59:47]` | 기록 시각(**서버 로컬 시각**, 이 서버는 `Asia/Seoul` KST +0900). **문자열 정렬 = 시간 정렬**이라 구간 검색을 문자열 비교로 처리 |
| `PID:<n>` | `PID:15491` | 포트를 가진 실제 앱 PID. 값이 바뀐 줄 = 앱 재시작 시점 |
| `CPU:<f>%` | `CPU:32.3%` | 시스템 전체 CPU 사용률. `/proc/stat` 을 `CPU_SAMPLE_SEC`(기본 1초) 간격으로 두 번 읽어 `100 × (1 − Δidle/Δtotal)`, 소수 1자리 |
| `MEM:<f>%` | `MEM:10.1%` | `(MemTotal−MemAvailable)/MemTotal` |
| `DISK_USED:<n>%` | `DISK_USED:32%` | 루트 파티션 사용률(`df -P /`) |

**타임존** — 과제가 정한 `[YYYY-MM-DD HH:MM:SS]` 형식을 지키느라 줄에는 타임존을 쓰지 않습니다. 시각은 **서버 로컬 시각**이고, 이 서버의 타임존은 `timedatectl` 에서 `Asia/Seoul (KST, +0900)` 입니다. UTC 로 남는 다른 서버 로그와 맞춰 볼 때는 변환해서 비교합니다(실측 `27-feedback-round2.txt` ②):

```bash
timedatectl | grep 'Time zone'                                   # Time zone: Asia/Seoul (KST, +0900)
date -u -d 'TZ="Asia/Seoul" 2026-11-09 23:35:02' '+%F %T'         # → 2026-11-09 14:35:02 (UTC)
```

서버 타임존을 바꾸면(`timedatectl set-timezone`) 그 순간부터 같은 파일 안에서 시각 기준이 달라져 구간 검색이 틀어지므로, 바꿀 때는 monitor.log 를 순환한 뒤 바꿉니다.

**CPU 샘플링 간격** — `CPU_SAMPLE_SEC` 를 늘리면 그 구간의 평균이 되어 순간 급등이 묻히고 실행 시간도 그만큼 길어집니다(실측: 1초 → 1.29초, 3초 → 3.28초 — `27-feedback-round2.txt` ⑦). 매분 실행하는 cron 에서는 1초가 순간값에 가깝고 다음 실행과 겹치지 않는 값입니다.

**확장(extended) 포맷** — 환경변수 `MONITOR_LOG_FORMAT=extended` 를 주면 기본 필드 뒤에 프로세스 자원과 방화벽 상태가 덧붙습니다. 실제 서버에서 기록한 줄입니다([`evidence/19-exit-codes.txt`](evidence/19-exit-codes.txt) ⑥):

```
[2026-11-09 19:09:21] PID:2127 CPU:11.6% MEM:60.2% DISK_USED:29% P_CPU:46.0% P_MEM:0.5% RSS:89.3MB THREADS:1 FIREWALL:active
```

| 추가 필드 | 의미 |
| --- | --- |
| `P_CPU` | 앱 프로세스의 순간 CPU(측정 1초 동안 `/proc/<pid>/stat` utime+stime 차이, 코어 1개 = 100%) |
| `P_MEM` / `RSS` | 앱 프로세스의 메모리 비율 / 실제 사용 메모리(MB) — 누수 추적용 |
| `THREADS` | 스레드 수 — 스레드 폭증·교착 분석용 |
| `FIREWALL` | 그 순간의 방화벽 상태(active / inactive / unknown) |

**report.sh 와의 호환** (실측: 같은 증빙 ⑥ 에서 extended 줄을 report.sh 가 정상 집계): report.sh 의 매칭 정규식은 줄의 **앞부분**(`^\[...\] PID:... CPU:...% MEM:...% DISK_USED:...%`)만 고정으로 요구하고 그 뒤에 확장 필드가 더 있어도 그대로 받아들입니다(코드 주석 "뒤에 확장 필드가 있어도 됨"). 즉 **extended 줄도 report.sh 가 정상 처리**하며, 추가된 `P_CPU`·`RSS` 등은 무시하고 기본 3개 값(CPU/MEM/DISK)만 통계에 씁니다. 그래서 basic 과 extended 를 섞어 기록해도 report.sh 통계는 깨지지 않습니다.

**파싱 예시** (아래 출력은 모두 "예시" 값입니다)

① 평균 CPU (awk):

```bash
awk -F'CPU:|%' '/CPU:/ { sum += $2; n++ } END { printf "avg CPU %.1f%%\n", sum/n }' monitor.log
# 예시: avg CPU 24.7%
```

② 최대 MEM 과 그 시각:

```bash
awk 'match($0, /MEM:[0-9.]+/) { v = substr($0, RSTART + 4, RLENGTH - 4) + 0; if (v > m) { m = v; t = substr($1, 2) " " substr($2, 1, 8) } } END { printf "max MEM %.1f%% at %s\n", m, t }' monitor.log
# 예시: max MEM 60.0% at 2026-11-09 19:08:30
# (첫 번째 "MEM:" 이 시스템 MEM 이라 extended 줄의 P_MEM 과 섞이지 않음)
```

③ 특정 시간대만 뽑기 (grep, 문자열 접두사):

```bash
grep '^\[2026-10-21 00:5' monitor.log
# 예시: 2026-10-21 00:50:00 ~ 00:59:59 의 줄만 출력
```

④ CPU 값만 추출 (sed):

```bash
sed -n 's/.* CPU:\([0-9.]*\)%.*/\1/p' monitor.log
# 예시: 32.3 / 12.4 / 9.1 ... (한 줄에 한 값)
# CPU 앞의 공백이 중요: '.*CPU:' 로 쓰면 extended 줄에서 뒤쪽 P_CPU 값이 잡힌다(실제로 확인한 실수)
```

⑤ PID 가 바뀐 지점(앱 재시작) 찾기 (awk):

```bash
awk 'match($0,/PID:[0-9]+/) { p=substr($0,RSTART+4,RLENGTH-4); if (p!=prev && NR>1) print "restart:", $1, $2, prev"->"p; prev=p }' monitor.log
# 예시: restart: [2026-10-21 04:00:11] 15491->20733
```

⑥ extended 포맷의 RSS 추이:

```bash
grep -o 'RSS:[0-9.]*MB' monitor.log | sed 's/RSS://'
# 예시: 48.6MB / 49.0MB / 51.2MB ... (메모리 누수 의심 시 증가 추세 확인)
```

위 6개 명령은 basic 3줄 + extended 1줄을 섞은 파일로 실행해 결과를 확인했습니다.

📄 `evidence/08-monitor-log.txt`(기본 포맷 누적), `evidence/11-report.txt`(report.sh 집계), `evidence/19-exit-codes.txt`(extended 포맷)

## 3. 리다이렉션 실수 사례 (`>` 와 `>>`)

`>` 는 파일을 **비우고(truncate)** 처음부터 쓰고, `>>` 는 **끝에 덧붙입니다(append)**. 로그 누적에서 둘을 바꿔 쓰면 조용히 데이터가 사라집니다.

**(a) crontab 에서 `> cron.log` 로 잘못 씀 — 매분 파일이 비워져 직전 `[ERROR]` 가 사라짐**

| | 내용 |
| --- | --- |
| 잘못된 줄 | `* * * * * /home/agent-admin/agent-app/bin/monitor.sh > /var/log/agent-app/cron.log 2>&1` |
| 증상 | 장애가 나도 cron.log 에는 **마지막 1분치**만 남고, 그 사이 발생한 `[ERROR]` 가 다음 분 실행에 덮여 사라짐 |
| 확인 | `wc -l /var/log/agent-app/cron.log` 가 매분 작아지거나 1~2줄을 넘지 못함 |
| 올바른 줄 | `* * * * * /home/agent-admin/agent-app/bin/monitor.sh >> /var/log/agent-app/cron.log 2>&1` |

**(b) monitor.sh 가 `>` 로 기록 — monitor.log 가 항상 1줄 → report.sh 통계 무의미**

| | 내용 |
| --- | --- |
| 잘못된 줄 | `printf '%s\n' "$line" > "$MONITOR_LOG"` |
| 증상 | monitor.log 가 언제 봐도 1줄. 추이가 없으니 report.sh 의 평균·최대·최소가 항상 같은 값(샘플 1개) |
| 확인 | `wc -l /var/log/agent-app/monitor.log` 가 1 에서 늘지 않음 |
| 올바른 줄 | `printf '%s\n' "$line" >> "$MONITOR_LOG"` (현재 monitor.sh 는 `>>` 사용) |

**(c) `2>&1 >> file` 순서 실수 — stderr 가 파일로 안 감**

리다이렉션은 **왼쪽부터** 적용됩니다. `2>&1` 을 먼저 쓰면 그 시점의 stdout(=터미널)로 stderr 를 복제한 뒤, 그다음 stdout 만 파일로 바꾸므로 stderr 는 터미널에 남고 파일엔 안 들어갑니다.

| | 내용 |
| --- | --- |
| 잘못된 줄 | `monitor.sh 2>&1 >> /var/log/agent-app/cron.log` |
| 증상 | 정상 출력은 파일에 쌓이는데 `[ERROR]`(stderr)만 파일에서 빠짐 → 장애 원인이 안 남음 |
| 확인 | 앱을 멈춘 뒤 실행해도 cron.log 에 에러 줄이 없음 |
| 올바른 줄 | `monitor.sh >> /var/log/agent-app/cron.log 2>&1` (먼저 stdout 을 파일로, 그다음 stderr 를 stdout 과 같은 곳으로) |

**재현 (임시 파일로 3번 실행 후 줄 수 비교)**

```bash
cd "$(mktemp -d)"
for i in 1 2 3; do echo "line $i" >  trunc.log; done   # > : 매번 비움
for i in 1 2 3; do echo "line $i" >> append.log; done   # >> : 덧붙임
wc -l trunc.log append.log
# 예시: trunc.log=1  append.log=3  → '>' 는 1줄만 남는다
```

**실제 서버 재현 결과** ([`evidence/26-redirect.txt`](evidence/26-redirect.txt))

| 재현 | `>` (잘못) | `>>` (올바름) |
| --- | --- | --- |
| 같은 줄 3번 기록 | 1줄 (`run 3` 만) | 3줄 |
| monitor.sh 를 cron 처럼 3번 실행(경고 2줄씩) | 2줄 — 마지막 실행분만 | 6줄 — 3번 모두 |
| `--bogus` 로 오류 유도 | `2>&1 >> 파일`: 파일 0바이트, 오류는 터미널로 | `>> 파일 2>&1`: 오류가 파일에 기록 |

**동시 실행과 잠금** — cron 실행과 수동 실행이 같은 순간 겹쳐도 안전한 이유는 두 가지입니다. ① `>>` 는 파일을 `O_APPEND` 로 열어 한 번의 짧은 `printf` 쓰기는 끝에 통째로 붙으므로 줄이 섞이지 않습니다. ② 위험한 것은 **로그 순환**(두 프로세스가 동시에 `mv monitor.log monitor.log.1` 을 하면 한 쪽 기록이 사라짐)인데, monitor.sh 는 기록 전체를 `flock` 잠금(`$AGENT_LOG_DIR/.monitor.lock`, 최대 10초 대기)으로 감싸 한 번에 하나만 순환·기록합니다. 실측(`27-feedback-round2.txt` ⑥): 동시에 2번 실행 → 2줄이 온전히 추가, 다른 프로세스가 잠금을 12초 쥐고 있으면 → `[ERROR] 다른 monitor.sh 가 실행 중입니다` 로 exit 2 (로그는 건드리지 않음). 직접 쓰는 다른 스크립트도 같은 파일을 만진다면 `flock /var/log/agent-app/.monitor.lock <명령>` 한 줄로 같은 잠금을 공유합니다.

## 4. 로그 순환 방식 선택 지침 (내장 순환 vs logrotate)

monitor.log 용량 관리는 **monitor.sh 내장 순환(기본)** 과 **logrotate(대안)** 두 가지가 있고, **둘을 동시에 쓰면 안 됩니다.**

| 비교 | 내장 순환(`rotate_log`) | logrotate |
| --- | --- | --- |
| 확인 시점 | **기록할 때마다(매분)** | 기본 하루 1회(`logrotate.timer`) — 설정만으로는 최대 하루 늦게 확인 |
| 정확도 | 10MB 상한을 분 단위로 지킴 | 폭증 시 다음 실행까지 상한 초과 가능 |
| 권한 | 추가 권한 불필요(agent-core 가 로그 디렉토리에 씀) | 보통 root 의 systemd timer 가 실행(`su agent-admin agent-core` 로 권한 위임) |
| 의존성 | 없음(순수 bash) | `logrotate` 패키지 |
| 설정 위치 | `bin/monitor.sh` 의 `MAX_LOG_SIZE_BYTES` / `MAX_LOG_FILES` | `/etc/logrotate.d/agent-app` |

**`config/logrotate.d/agent-app` 줄 단위 해설**

```
/var/log/agent-app/monitor.log {
    size 10M                              # 10MB 이상일 때만 순환(시간이 아니라 용량 기준) — 내장 순환과 같은 기준
    rotate 9                              # .1 ~ .9 까지 9개 보관 → 현재 파일 + 9개 = 10개(과제 요구 10개와 일치)
    missingok                             # 파일이 아직 없어도 에러 없이 건너뜀(첫 실행·앱 미기동 대비)
    notifempty                            # 비어 있으면 순환하지 않음(빈 .1~.9 로 슬롯 낭비 방지)
    nocompress                            # 압축 안 함 → report.sh 가 .1~.9 를 바로 읽을 수 있음(gz 면 못 읽음)
    create 0660 agent-admin agent-core    # 순환 후 새 monitor.log 를 이 소유/권한으로 생성(agent-core 그룹 쓰기 가능)
    su agent-admin agent-core             # 이 로그 디렉토리 권한으로 순환 작업 수행(root 가 돌려도 올바른 소유권 유지)
}
```

> **⚠ 동시 사용 금지** — 같은 `monitor.log` 를 내장 순환과 logrotate 가 **각자 기준으로** 밀면 ① 같은 시점에 두 번 밀려 가장 오래된 `.9` 가 예상보다 빨리 버려지고(보관량이 줄어듦) ② 언제 누가 순환했는지 추적할 수 없으며 ③ 새 파일의 권한을 정하는 곳이 두 군데(`create 0660 …` 과 monitor.sh 의 `chmod 0660`)가 되어 한쪽만 바뀌면 어긋납니다. 반드시 **하나만** 활성화합니다.

> **`su` 지시어가 꼭 필요한 이유 (실측)** — `/var/log/agent-app` 은 agent-core 그룹 쓰기 가능(2770)이라, `su` 없이 돌리면 logrotate 가 `skipping … because parent directory has insecure permissions` 로 **순환을 거부**합니다. `su agent-admin agent-core` 를 넣은 사본으로는 실제로 `.1 → .2 → .3` 순환이 일어남을 확인했습니다(`24-logrotate.txt` ④⑤).

**운영 지침**

- **기본은 내장 순환**입니다. 그대로 두면 됩니다.
- **logrotate 로 전환** 하려면:
  1. 내장 순환을 끕니다 — env 파일에 `MAX_LOG_SIZE_BYTES=999999999999`(사실상 순환 안 함)를 넣습니다.
  2. 설정을 설치합니다 — `sudo install -m 0644 -o root -g root config/logrotate.d/agent-app /etc/logrotate.d/agent-app`
     **`cp` 로 그대로 복사하면 안 됩니다**: 저장소에서 받은 파일은 umask 에 따라 `0664` 일 수 있는데, logrotate 는 그룹·기타 쓰기가 가능한 설정 파일을 `error: Ignoring … because it is writable by group or others` 로 **조용히 무시**합니다(실측, `24-logrotate.txt` ②).
  3. 미리 보기로 검증 — `sudo logrotate -d /etc/logrotate.d/agent-app`(`-d` 는 실제로 돌리지 않고 무엇을 할지만 출력)
  4. 10MB 를 빨리 넘는 환경이면 하루 1회를 **시간 단위**로 — `sudo systemctl edit logrotate.timer` 후 아래를 넣습니다:

     ```ini
     [Timer]
     OnCalendar=
     OnCalendar=hourly
     ```
     (첫 `OnCalendar=` 빈 줄은 기존 하루 1회 설정을 지우는 의미입니다.)
- **되돌리기**: `sudo rm /etc/logrotate.d/agent-app`, env 의 `MAX_LOG_SIZE_BYTES` 를 원래 값(`10485760`)으로, timer override 는 `sudo systemctl revert logrotate.timer` 로 제거합니다.
- **둘 다 켜져 있지 않은지 확인** (2줄):

  ```bash
  grep -E '^MAX_LOG_SIZE_BYTES=' /etc/agent-app/agent-app.env   # 큰 값이면 내장 순환 꺼짐
  ls /etc/logrotate.d/agent-app 2>/dev/null && echo "logrotate 활성" || echo "logrotate 없음"
  ```
  내장 순환이 켜져 있으면(`MAX_LOG_SIZE_BYTES` 가 10MB) logrotate 설정이 **없어야** 정상입니다.

📄 `evidence/24-logrotate.txt`, `evidence/10-log-capacity.txt`

## 5. cron 장애 점검과 복구

"수동으로는 되는데 cron 에서는 monitor.log 가 안 늘어난다" 류의 장애를 한 번에 진단하는 도구가 `verify/check-cron.sh` 입니다.

**사용법**

```bash
sudo bash verify/check-cron.sh --user agent-admin --max-age 2
```

7단계를 순서대로 점검합니다: ① crontab 등록 여부 → ② cron 서비스 활성 → ③ monitor.sh 실행 권한 → ④ syslog 의 `CRON` 기록과 마지막 실행 경과 시간(syslog 가 없으면 `journalctl -u cron`) → ⑤ monitor.log 마지막 기록 시각 → ⑥ cron.log 최근 오류 → ⑦ **cron 과 같은 최소 환경에서 env 파일 로드**. 각 단계는 `[OK]`/`[WARN]`/`[FAIL]`/`[SKIP]` 로 표시되고, 실패한 단계마다 `→ 복구:` 뒤에 바로 실행할 명령을 제시합니다. 종료 코드는 **0 FAIL 없음 / 1 FAIL 1개 이상 / 2 사용법 오류**이고, `--max-age`(기본 3분)보다 오래된 CRON 기록·monitor.log 기록은 FAIL 로 봅니다. root 가 아니면 3단계(실행 권한)는 SKIP 됩니다.

**7단계 — cron 환경에서 env 파일이 실제로 읽히는가** — cron 은 로그인 셸이 아니라 `/etc/profile.d/agent-app.sh` 를 읽지 않고 `PATH=/usr/bin:/bin`·`HOME` 정도만 넘깁니다. 그래서 monitor.sh 는 `AGENT_ENV_FILE`(기본 `/etc/agent-app/agent-app.env`)을 스스로 `source` 합니다. 문제는 이 파일을 **못 읽어도 monitor.sh 는 오류 없이 스크립트 기본값으로 돈다**는 점입니다(포트를 바꿔 둔 서버라면 엉뚱한 포트를 관제). 7단계는 실행 계정(`sudo -u agent-admin`)으로 `env -i` 로 환경을 비운 셸을 띄워 그 파일을 `source` 하고, 읽힌 `AGENT_PORT`·`AGENT_LOG_DIR` 를 출력합니다. 읽기 불가·문법 오류·점검 셸과 값이 다름은 FAIL, 파일 없음·`AGENT_PORT` 없음은 WARN 입니다. 실측(`27-feedback-round2.txt` ③): env 파일을 `0600` 으로 바꾸자 `[7/7] … [FAIL] agent-admin 가 … 을 읽을 수 없습니다 (기본값으로 조용히 실행됨)`, `setup/05-environment.sh` 재실행으로 복구.

**cron 실행 계정으로 직접 실행해 보기** — 권한 확인(`test -x`)만으로는 실제 실행까지 보장하지 못하므로, cron 과 같은 계정·같은 빈 환경으로 한 번 돌려 종료 코드와 기록을 확인합니다(실측 `27` ③: `exit=0`, monitor.log 에 새 줄):

```bash
sudo -u agent-admin env -i HOME=/home/agent-admin PATH=/usr/bin:/bin SHELL=/bin/sh \
    /home/agent-admin/agent-app/bin/monitor.sh --no-stats --quiet; echo "exit=$?"
tail -n 1 /var/log/agent-app/monitor.log
```

**주기적 검증** — 점검 자체를 root crontab 에 걸어 두면 env·권한이 바뀐 것을 사람이 보기 전에 syslog(또는 알림)로 알 수 있습니다:

```cron
# sudo crontab -e  (매시 17분, 실패하면 syslog 에 agent-monitor 태그로 남김)
17 * * * * bash /srv/linux-server-ops/verify/check-cron.sh >/dev/null 2>&1 || logger -t agent-monitor "check-cron FAIL"
```

알림 훅(§8)을 쓰면 `logger` 대신 `/home/agent-admin/agent-app/bin/alert.sh CRITICAL "check-cron FAIL"` 로 바꿉니다.

**증상 → 원인 → 확인 → 복구**

| 증상 | 원인 | 확인 | 복구 |
| --- | --- | --- | --- |
| cron 이 아예 안 돎 | crontab 미등록 | `sudo crontab -u agent-admin -l` 비어 있음 | `sudo bash setup/07-cron.sh` (멱등) |
| 분마다 실행 안 됨 | cron 서비스 중지 | `systemctl is-active cron` | `sudo systemctl enable --now cron` |
| 수동은 되나 cron 만 실패 | cron 의 짧은 `PATH`(`/usr/bin:/bin`) | cron.log 에 `command not found` | crontab 상단 `PATH=` 지정(`config/crontab.agent-admin`) |
| 실행 자체가 거부 | monitor.sh 실행 권한/소유 변경 | `sudo -u agent-admin test -x …/bin/monitor.sh; echo $?` | `sudo bash setup/06-install-monitor.sh` 로 `agent-dev:agent-core 0750` 복원 |
| exit 2 로 끝남 | 로그 디렉토리 권한 | `sudo -u agent-admin test -w /var/log/agent-app; echo $?` | `sudo bash setup/04-directories.sh` 로 `2770 + ACL` 복원 |
| env 값이 안 먹음 | env 파일 권한/부재 | `sudo -u agent-admin cat /etc/agent-app/agent-app.env` | `sudo bash setup/05-environment.sh` (0644 재생성) |
| crontab 줄이 깨짐 | `%` 문자(cron 에서 개행으로 해석) | `crontab -l` 에 `%` 가 이스케이프 안 됨 | 명령 안의 `%` 를 `\%` 로 이스케이프 |
| "No such file" 류 | CRLF 줄바꿈(윈도우에서 편집) | `file config/crontab.agent-admin` 에 `CRLF` | `sed -i 's/\r$//'` 후 재등록 |
| 매분 exit 1 | 앱이 중지됨(정상적인 실패) | cron.log 에 `앱 프로세스가 실행 중이 아닙니다` | 앱 재기동(`bin/run-agent.sh`) — cron 문제가 아님 |

**syslog / journal 확인**

```bash
grep CRON /var/log/syslog | tail                     # syslog 환경
journalctl -u cron --since "-10min"                  # systemd-journald 환경
```

**복구 후 확인 순서**: 복구 명령 실행 → `sudo bash verify/check-cron.sh --user agent-admin` 재실행으로 전 단계 `[OK]` 확인 → 1분 기다렸다가 `wc -l /var/log/agent-app/monitor.log` 가 **늘어나는지** 두 번 비교.

📄 `evidence/09-cron.txt`, `evidence/14-failure-cases.txt`, `evidence/20-cron-check.txt`

## 6. 권한 점검 · 복구 · 감사

cron 실행자는 **agent-admin** 입니다. monitor.sh 가 매분 돌려면 경로마다 아래 권한이 **딱 필요한 만큼** 있어야 합니다(최소 권한).

**agent-admin 권한 매트릭스**

| 경로 | 필요한 권한 | 실제 부여 방식 (setup 스크립트 기준) |
| --- | --- | --- |
| `/home/agent-admin` | `x` (통과) | `agent-admin:agent-admin 750` — agent-admin 이 **소유자**라 rwx (`04-directories.sh`) |
| `…/agent-app` (`$AGENT_HOME`) | `x` (통과) | `agent-admin:agent-common 0750` — 소유자 agent-admin → rwx |
| `…/agent-app/bin` | `x` (통과) | `agent-dev:agent-core 2750` — agent-admin 은 **agent-core 그룹**이라 r-x |
| `…/bin/monitor.sh` | `r` + `x` | `install -o agent-dev -g agent-core -m 0750` (`06-install-monitor.sh`) — 그룹 agent-core 로 r-x. **ACL 아님, 순수 소유/그룹** |
| `/var/log/agent-app` | `w` + `x` | `agent-admin:agent-core 2770` + **default ACL** `g:agent-core:rwx` (`04-directories.sh`) — 소유자 agent-admin → rwx |
| `/var/log/agent-app/monitor.log` | `w` | `install -o agent-admin -g agent-core -m 0660` (`06-install-monitor.sh`) — 소유자 쓰기 |
| `/etc/agent-app/agent-app.env` | `r` | `root:root 0644` (`05-environment.sh`) — **other 읽기**로 누구나 읽음(경로만 담겨 비밀값 없음) |

즉 부여 방식은 **세 가지**입니다: ① 홈·agent-app·로그 디렉토리·monitor.log 는 agent-admin 이 **소유자**, ② bin·monitor.sh 는 agent-admin 이 **agent-core 그룹 소속**, ③ env 파일은 **world-readable**. monitor.sh 자체엔 ACL 을 걸지 않고(소유/그룹만), ACL 은 디렉토리의 **default ACL**(새 파일에 그룹 rwx 자동 부여)에만 씁니다.

**점검 명령**

```bash
namei -l /var/log/agent-app/monitor.log            # 경로 각 단계의 소유/권한을 한눈에
sudo -u agent-admin test -x …/bin/monitor.sh; echo $?   # 실행 가능하면 0
sudo -u agent-admin test -w /var/log/agent-app;  echo $?   # 쓰기 가능하면 0
getfacl -p /var/log/agent-app                      # setgid·default ACL 확인
id agent-admin                                     # agent-core·agent-common 소속 확인
```

**설치 중 권한 오류 체크**: setup 실행 **직후** 기대값과 실제값을 비교합니다.

```bash
stat -c '%U:%G %a' …/bin/monitor.sh          # 기대: agent-dev:agent-core 750
stat -c '%U:%G %a' /var/log/agent-app        # 기대: agent-admin:agent-core 2770
stat -c '%U:%G %a' /var/log/agent-app/monitor.log   # 기대: agent-admin:agent-core 660
```

**복구**: setup 스크립트는 **멱등**이라 다시 돌리면 올바른 소유/권한/ACL 로 되돌립니다.

```bash
sudo bash setup/04-directories.sh        # 디렉토리·ACL
sudo bash setup/06-install-monitor.sh    # 스크립트 소유·권한
# 수동으로 한 항목만 고칠 때:
sudo chown agent-dev:agent-core …/bin/monitor.sh && sudo chmod 0750 …/bin/monitor.sh
```

**롤백**: 변경 전에 ACL 을 백업해 두면 그대로 되돌릴 수 있습니다.

```bash
getfacl -R -p /var/log/agent-app …/agent-app/api_keys > acl-backup.txt   # 변경 전 백업
setfacl --restore=acl-backup.txt                                          # 되돌리기
```

**감사**: 민감 파일 접근은 auditd 로 남깁니다. 그룹 변경은 **재로그인 후** 반영됩니다(이미 열린 세션엔 적용 안 됨).

```bash
sudo auditctl -w /home/agent-admin/agent-app/api_keys -p rwa -k agent-keys   # 읽기·쓰기·속성변경 감시
sudo ausearch -k agent-keys                                                  # 기록 조회
```

**계정 잠금 · 비밀번호 정책 상태** — `setup/03-accounts.sh` 는 비밀번호를 설정하지 않으므로 세 계정은 **잠긴 상태(L)** 로 만들어집니다. 사람은 자기 계정으로 들어와 `sudo -iu agent-admin` 으로 전환합니다(누가 전환했는지 auth.log 에 남음).

| 항목 | 확인 명령 | 현재 값 (실측 `27-feedback-round2.txt` ①) | 의미 / 운영 지침 |
| --- | --- | --- | --- |
| 잠금 상태 | `passwd -S agent-admin` | `agent-admin L …` (dev·test 도 L) | 비밀번호 로그인 불가. 풀려면 `sudo passwd <계정>`, 다시 잠그려면 `sudo passwd -l <계정>` |
| 비밀번호 만료 | `chage -l agent-admin` | `Password expires: never` (최대 99999일) | 비밀번호를 쓰게 되면 `sudo chage -M 90 -W 7 <계정>` 처럼 만료를 정함 |
| 시스템 기본값 | `grep ^PASS_ /etc/login.defs` | `PASS_MAX_DAYS 99999`, `PASS_MIN_DAYS 0`, `PASS_WARN_AGE 7` | 새로 만드는 계정에 적용되는 기본값 |
| SSH 인증 | `sshd -T \| grep -E 'passwordauth\|pubkeyauth'` | `passwordauthentication yes`, `pubkeyauthentication yes`, `permitemptypasswords no` | 계정이 잠겨 있어 비밀번호로는 못 들어옴. **키 접속을 확인한 뒤에는** `PasswordAuthentication no` 를 추가하는 것을 권장(키를 등록하기 전에 끄면 원격 접속이 끊김) |

**보안 모듈(SELinux / AppArmor)의 영향** — 권한 판단은 **소유/그룹/ACL(DAC) 을 통과한 뒤 보안 모듈(MAC)도 통과해야** 허용됩니다. Ubuntu 22.04 는 SELinux 가 아니라 AppArmor 를 쓰고, agent-app·monitor.sh 에는 프로파일이 없어 `unconfined` 로 돕니다(실측 `27` ⑨). 그래서 이 서버에서는 위 표의 소유/그룹/ACL 만으로 접근이 결정됩니다. RHEL·Rocky 처럼 **SELinux Enforcing** 인 서버로 옮기면 `ls -l`·`getfacl` 이 맞는데도 `Permission denied` 가 날 수 있습니다. 그때는 `sudo ausearch -m avc -ts recent` 로 거부 기록을 보고, 파일을 `mv` 로 옮겨 원래 위치의 보안 문맥(라벨)이 따라온 경우가 많으므로 `sudo restorecon -Rv /var/log/agent-app` 으로 라벨을 그 경로의 기본값으로 되돌립니다(SSH 포트 라벨은 §10).

📄 `evidence/04-permissions.txt`(계정별 접근 매트릭스), `evidence/07-monitor.txt`, `evidence/27-feedback-round2.txt` ①⑨

## 7. 포트 미개방 진단 체크리스트

"앱은 떠 있는데 포트로 접속이 안 된다" 는 원인이 여럿(바인딩 주소·포트 오타·충돌·권한·멈춤·방화벽)이라, 한 번에 순서대로 짚어 주는 도구가 `bin/diagnose-port.sh` 입니다.

**사용법**

```bash
sudo bash bin/diagnose-port.sh                 # PORT 생략 시 AGENT_PORT(기본 15034)
sudo bash bin/diagnose-port.sh 80 --process '^nginx([: ].*)?$'   # 다른 대상
```

8단계를 `[i/8] … [OK|WARN|FAIL|SKIP]` 형식으로 출력하고 마지막 줄에 `결론:` 을 냅니다. 종료 코드는 **0 FAIL 없음(WARN 은 있을 수 있음) / 1 FAIL 1개 이상 / 2 사용법 오류**입니다. 일반 계정으로 실행하면 다른 계정 프로세스의 소켓·환경변수를 볼 수 없어 3·4·5단계가 SKIP 되고 8단계(ufw 규칙)도 확인할 수 없으므로, 정확한 진단은 `sudo` 로 합니다.

| 단계 | 무엇을 보나 | FAIL/WARN 일 때 원인 | 수동 확인 명령 | 조치 |
| --- | --- | --- | --- | --- |
| 1/8 | 앱 프로세스 실행 여부 | FAIL: 앱이 안 떠 있음 → 포트가 없는 게 당연 | `pgrep -af agent-app` | 앱 재기동(`bin/run-agent.sh`). 3·5·6·7단계는 SKIP(2·4·8 은 계속 점검) |
| 2/8 | 포트 LISTEN 여부 | WARN: `127.0.0.1`(루프백)에만 바인딩 → 로컬만 접속됨 / FAIL: 아무 데도 LISTEN 안 함 | `ss -ltnp 'sport = :15034'` | 바인딩 주소를 `0.0.0.0`(또는 서버 IP)으로 변경 |
| 3/8 | 앱이 **실제로** 연 포트 | FAIL: 기대 포트가 아닌 **다른 포트**를 열고 있음(설정 오타) | `ss -ltnp \| grep "pid=<PID>"` | 앱 설정/`AGENT_PORT` 값을 기대 포트로 교정 |
| 4/8 | 포트 충돌 | FAIL: 그 포트를 **다른 프로세스**가 선점 | `ss -ltnp 'sport = :15034'` 의 PID 확인 | 선점 프로세스 종료 또는 앱 포트 변경 |
| 5/8 | `/proc/<PID>/environ` 의 `AGENT_PORT` | FAIL: 값이 진단 포트와 다름 / WARN: 변수가 없음(nginx 처럼 설정 파일로 포트를 정하는 서비스는 정상) | `tr '\0' '\n' < /proc/<PID>/environ \| grep AGENT_PORT` | env 파일/실행 환경의 `AGENT_PORT` 교정 후 재기동 |
| 6/8 | 1024 미만 포트 권한 | WARN: 특권 포트인데 앱이 root 가 아님 → bind 거부 가능 | `getcap $(readlink -f /proc/<PID>/exe)` | 1024 이상 포트 사용, 또는 `setcap cap_net_bind_service=+ep`. **SELinux/AppArmor** 가 바인딩을 막을 수도 있음(해당 환경이면 정책 확인) |
| 7/8 | 프로세스 State / Threads | WARN: 상태가 `D`(디스크 대기)·`T`(정지) → 멈춰서 응답 못 함 | `cat /proc/<PID>/status \| grep -E 'State\|Threads'` | `D` 는 I/O·스토리지 점검, `T` 는 `kill -CONT <PID>` 또는 재기동 |
| 8/8 | 방화벽 허용 규칙 | WARN: 포트 허용 규칙이 **없음**(방화벽은 LISTEN 을 막지 않으므로 FAIL 이 아니라 WARN) | `sudo ufw status \| grep 15034` | 허용 규칙 추가(`sudo ufw allow 15034/tcp`). 로컬은 되는데 바깥에서만 막히는 전형적 원인 |

**원인별 정리**

- **바인딩 주소(`127.0.0.1`)** — 로컬에서 `curl localhost:15034` 는 되는데 다른 PC 에서 안 되면 루프백 전용 바인딩입니다(2단계 WARN). `0.0.0.0` 으로 바꿉니다.
- **다른 포트 / 오타** — 앱이 뜬 포트와 기대 포트가 다름(3단계 FAIL). `AGENT_PORT` 설정을 확인합니다.
- **포트 충돌** — 다른 프로세스가 먼저 그 포트를 잡음(4단계 FAIL).
- **권한(1024 미만)** — 특권 포트를 일반 계정이 열려다 실패(6단계 WARN). 가능하면 1024 이상을 쓰고, 꼭 필요하면 `cap_net_bind_service` 를 부여합니다. **SELinux/AppArmor** 가 켜진 환경에서는 포트 라벨/프로파일이 바인딩을 막을 수 있으니 이것도 의심합니다(언급만).
- **멈춤(`D`/`T` 상태)** — 프로세스는 있는데 응답을 못 함(7단계 WARN).
- **방화벽** — 로컬에서는 LISTEN 이 보이는데 바깥에서만 실패하면 방화벽 허용 규칙 부재입니다(8단계 WARN). 서버 안에서만 보면 판단이 안 되므로, **바깥에서** 확인합니다:

  ```bash
  bash verify/remote-check.sh <서버 주소> [접속 계정] [--blocked-port N]
  # 예) bash verify/remote-check.sh 192.168.56.10 agent-admin --blocked-port 8080
  ```

  `remote-check.sh` 는 서버 밖에서 20022·15034 는 open, 22 는 닫힘인지, `--blocked-port` 로 허용 목록 밖 포트가 timeout(DROP)으로 막히는지까지 봅니다. `open` 이면 방화벽 문제가 아니고, `timeout` 이면 방화벽이 막는 것입니다.

**판단 흐름**

```
앱 프로세스 있나? ──아니오──▶ 앱 재기동 (bin/run-agent.sh)
   │ 예
   ▼
포트 LISTEN 중인가? ──아니오──▶ 바인딩 실패: 포트 오타 / 권한(1024 미만) / 멈춤 확인
   │ 예
   ▼
127.0.0.1(루프백)에만? ──예──▶ 0.0.0.0 으로 바인딩 주소 변경
   │ 아니오
   ▼
그 포트 주인이 앱인가? ──아니오──▶ 다른 프로세스 선점(충돌) 또는 앱이 다른 포트
   │ 예
   ▼
바깥에서 접속되나? ──아니오──▶ 방화벽 허용 규칙 추가 (remote-check.sh 로 확인)
   │ 예
   ▼
정상
```

**실제 서버에서 원인을 하나씩 만들어 본 결과** ([`evidence/21-port-diagnosis.txt`](evidence/21-port-diagnosis.txt))

| 만든 상황 | 진단 결과 | exit | 바깥(다른 컨테이너)에서 |
| --- | --- | --- | --- |
| 정상 | 8단계 모두 OK, `결론: 포트 정상` | 0 | — |
| ufw 에서 15034 규칙 삭제 | 8단계 WARN `ufw 에 15034 허용 규칙 없음` | 0 | 접속 불가(timeout) |
| LISTEN 안 하는 같은 이름 프로세스 | 2단계 FAIL, 3단계 WARN | 1 | — |
| 127.0.0.1 에만 바인딩 | 2단계 WARN `루프백에만 바인딩` | 0 | Connection refused |
| 다른 프로그램이 15034 선점 | 4단계 FAIL `다른 프로세스(PID …, python3)가 포트 사용 중` | 1 | — |
| 15999 로 진단(포트 오타) | 2·3·5단계 FAIL — 3단계가 `앱은 15034 포트로 열려 있음` 으로 실제 포트 지목 | 1 | — |

**바인딩 실패 원인(stderr·앱 로그) 수집 절차** — 포트가 안 열린 이유는 대부분 **앱이 기동할 때 stderr 에 이미 적어 두었습니다.** monitor.sh 도 포트 FAIL 때 `[HINT]` 줄로 이 순서를 안내합니다.

1. **앱 출력 파일** — `run-agent.sh --background` 는 앱의 stdout·stderr 를 `$AGENT_LOG_DIR/agent-app.out` 에 모읍니다.
   `grep -iE 'already in use|permission denied|bind|fail' /var/log/agent-app/agent-app.out | tail`
2. **그 순간의 포트 주인** — 충돌이면 상대 PID·프로그램이 보입니다. `sudo ss -Hltnp 'sport = :15034'`
3. **포그라운드 재실행** — 같은 계정·같은 환경으로 터미널에서 띄우면 stderr 가 바로 보입니다. `sudo -iu agent-admin timeout 10 …/bin/run-agent.sh`
4. **서비스로 띄웠다면** — `journalctl -u <서비스> -n 50 --no-pager` (systemd 가 stderr 를 journal 로 모음)
5. **커널·보안 모듈이 막았다면** — `sudo dmesg | tail`, SELinux 환경이면 `sudo ausearch -m avc -ts recent`
6. **보존** — 원인 줄을 장애 기록에 붙여 둡니다. 다음 기동 때 `agent-app.out` 은 새로 쓰이므로(`>`) 먼저 복사: `cp /var/log/agent-app/agent-app.out ~/incident-$(date +%F-%H%M).out`

실측(`27-feedback-round2.txt` ⑤): 다른 프로그램이 15034 를 먼저 잡은 상태에서 앱을 띄우자 앱은 바로 종료됐고, 1번에서 `[4/5] Checking Port Availability [FAIL]` / `>>> Port 15034 is already in use.`, 2번에서 상대가 `python3, pid=…` 임을 확인했습니다. 상대를 끄고 다시 띄우니 LISTEN 이 돌아왔습니다.

📄 `evidence/21-port-diagnosis.txt`(8단계 진단), `evidence/13-remote-check.txt`(바깥에서 본 결과), `evidence/14-failure-cases.txt`, `evidence/27-feedback-round2.txt` ④⑤

## 8. 경고 알림 연동

monitor.sh 의 임계값 경고·방화벽 경고는 **종료 코드 0** 으로 끝납니다(경고는 정상 범위). 그래서 cron 만 돌려서는 **아무도 모릅니다** — cron.log 에 `[WARNING]` 한 줄이 쌓일 뿐, 누가 들여다보지 않으면 놓칩니다. 경고가 생긴 순간 외부로 밀어 주는 고리가 `ALERT_CMD` + `bin/alert.sh` 입니다.

**왜 경고는 종료(exit 1)가 아닌가** — 종료 코드는 "지금 서비스가 안 된다 → 사람이 바로 손대야 한다" 는 신호로만 씁니다. 프로세스가 없거나 포트가 닫히면 요청을 못 받으니 exit 1(CRITICAL)입니다. 반면 CPU 32% 같은 임계값 초과는 **서비스는 응답 중**이고 순간 급등일 수도 있습니다. 이것까지 exit 1 로 만들면 예컨대 배치 작업이 도는 5분 동안 매분 "장애" 가 5번 쌓이고, 종료 코드를 보고 앱을 자동 재기동하는 구성이라면 멀쩡한 앱을 다섯 번 재시작하게 됩니다. 그래서 임계값은 기록하고 알리기만 하고(WARNING), 판단은 추세(report.sh)로 합니다. 대신 경고가 묻히지 않도록 아래 알림으로 바깥에 알립니다.

**설정** — `/etc/agent-app/agent-app.env` 에 다음을 추가합니다:

```bash
ALERT_CMD=/home/agent-admin/agent-app/bin/alert.sh
# 선택: Slack/Webhook 로도 보내려면
ALERT_WEBHOOK_URL=https://hooks.example.com/...
```

> **⚠ Webhook URL 은 비밀**입니다. `ALERT_WEBHOOK_URL` 을 넣으려면 env 파일 권한을 **`0640 root:agent-core`** 로 유지해(agent-core 만 읽음) 토큰이 world-readable 이 되지 않게 하고, 저장소에는 **넣지 않습니다**. (URL 이 없으면 로컬 `logger` 기록만 하므로 env 를 world-readable 로 두어도 무방합니다.)

**동작 순서**

1. monitor.sh 는 경고가 생길 때마다 `ALERT_CMD WARNING "<메시지>"` 를, Health Check 실패(프로세스·포트) 시 `ALERT_CMD CRITICAL "<메시지>"` 를 호출합니다. 알림 호출은 **10초 timeout** 이고 **결과(종료 코드)에는 영향을 주지 않습니다** — 알림이 느리거나 실패해도 관제 자체는 그대로 진행됩니다.
2. `alert.sh LEVEL MESSAGE` 는 **같은 env 파일을 직접 읽은 뒤**(monitor.sh 는 env 를 source 만 하고 export 하지 않아 자식 프로세스에 값이 전달되지 않기 때문 — 증빙 수집 중 웹훅이 안 가는 것을 보고 고친 부분) `logger -t agent-monitor` 로 syslog 에 남기고(WARNING→`user.warning`, CRITICAL→`user.crit`), `ALERT_WEBHOOK_URL` 이 있으면 `curl` 로 `{"text":…}` JSON 을 POST 하며, `ALERT_LOG_FILE` 이 있으면 거기에도 덧붙입니다.
3. **쿨다운** — 숫자를 제외해 같다고 보는 메시지는 `ALERT_COOLDOWN_SEC`(기본 600초) 동안 **한 번만** 보냅니다. 상태는 `ALERT_STATE_DIR`(기본 `/var/log/agent-app/.alert-state`)에 둡니다. **매분** 도는 cron 이 같은 경고를 반복할 때 알림이 폭주하는 것을 막기 위함입니다("CPU 21%", "CPU 23%" 처럼 숫자만 달라도 같은 경고로 묶임).

**확인**

```bash
grep agent-monitor /var/log/syslog        # syslog 환경
journalctl -t agent-monitor               # systemd-journald 환경
```

**알림 등급**

| 등급 | 호출 시점 | 예 |
| --- | --- | --- |
| WARNING | 상태 점검 경고(계속 진행, exit 0) | 방화벽 비활성, CPU/MEM/DISK 임계값 초과 |
| CRITICAL | Health Check 실패(exit 1) | 앱 프로세스 없음, 포트 LISTEN 안 됨 |

**대안(알림 스크립트 없이)**

- **crontab `MAILTO`** — crontab 상단에 `MAILTO=admin@example.com` 를 두면 cron 작업이 **stdout/stderr 출력을 낼 때** 그 내용을 메일로 보냅니다. 단 monitor.sh 는 경고도 정상 출력이라, 메일을 받으려면 평소 출력을 줄이고(`--quiet`) 경고만 남게 조정해야 합니다.
- **cron.log 감시** — 별도 1분 cron 으로 `grep -c WARNING /var/log/agent-app/cron.log` 가 늘어나면 통지하는 간단한 감시를 둘 수 있습니다(파일 기반이라 쿨다운·등급 구분은 직접 구현해야 함).

**실측 결과** ([`evidence/25-alert.txt`](evidence/25-alert.txt)) — 시험용 웹훅 수신기를 다른 컨테이너(ops-laptop:9000)에 띄워 확인했습니다.

| 상황 | monitor.sh | syslog (`agent-monitor`) | 웹훅 수신 |
| --- | --- | --- | --- |
| MEM 임계값 초과 | exit 0 | `[WARNING] … MEM threshold exceeded (57.8% > 10%)` (user.warning) | `{"text":"… [WARNING] …"}` |
| 곧바로 다시 실행 | exit 0 | 늘지 않음(쿨다운) | 없음 |
| 앱 중지 | exit 1 | `[CRITICAL] … 앱 프로세스가 실행 중이 아닙니다` (user.crit, `journalctl -p crit` 로도 조회) | `{"text":"… [CRITICAL] …"}` |
| 이후 cron 이 매분 같은 경고 | exit 0 | 늘지 않음(10분 쿨다운) | 없음 |

📄 `evidence/25-alert.txt`

## 9. SSH 무차별 대입 대응

SSH 포트를 22→20022 로 바꾼 것은 **은닉(스캔 노이즈 감소)** 일 뿐, 포트를 찾아낸 봇의 비밀번호 대입을 막지는 못합니다. 실제 방어는 **탐지 → 자동 차단**입니다.

**로그 기준 탐지** — 실패 로그를 IP 별로 집계합니다:

```bash
# 실패/존재하지 않는 계정 시도를 IP 별로 많은 순 집계
awk '/Failed password|Invalid user/ { for (i=1;i<=NF;i++) if ($i=="from") print $(i+1) }' \
    /var/log/auth.log | sort | uniq -c | sort -rn | head

# 최근 10분 실패 건수
journalctl -u ssh --since "10 min ago" | grep -c 'Failed password'
# 또는 auth.log 기반: grep 'Failed password' /var/log/auth.log | ...
```

**정상 오타 vs 봇 판단 기준**

| 관찰 | 정상(사용자 오타) | 봇/공격 |
| --- | --- | --- |
| 출처 IP 수 | 1~2개(본인·관리망) | 여러 IP, 해외 대역 |
| 대상 계정 | 실재 계정 1개 | `root`, `admin`, `test`, `oracle` 등 존재하지 않는 계정 다수 |
| 빈도 | 몇 분에 몇 회 | 초·분당 수십~수백 회 |
| 시간대 | 업무 시간 | 무차별·야간 지속 |

**자동 차단 — fail2ban** (`config/fail2ban/jail.d/agent-sshd.local`, 주석을 뺀 값)

```ini
[sshd]
enabled   = true
port      = 20022
maxretry  = 5
findtime  = 10m
bantime   = 1h
banaction = ufw
ignoreip  = 127.0.0.1/8 ::1
```

| 값 | 근거 |
| --- | --- |
| `port = 20022` | 01-ssh.sh 로 옮긴 SSH 포트를 감시(기본 22 가 아님) |
| `maxretry = 5`, `findtime = 10m` | 10분 안에 5회 실패하면 차단 — 사람의 오타(몇 분에 몇 회)는 넘기고 봇의 연속 시도만 잡는 선 |
| `bantime = 1h` | 영구 차단은 관리자가 자기 IP 를 영원히 막는 사고 위험 → 1시간 뒤 자동 해제 |
| `banaction = ufw` | iptables 직접이 아니라 UFW 규칙으로 차단 → `ufw status` 에서 눈으로 확인, 방화벽을 한 곳에서 관리 |
| `ignoreip` | 로컬은 제외. 관리자 고정 IP 를 추가하면 자기 잠김 방지 |

> **⚠ 값 뒤에 `# 주석` 을 붙이지 않습니다 (실측)** — fail2ban 설정은 같은 줄의 `#` 뒤도 값으로 읽습니다. 처음 만든 설정에서 `maxretry = 5   # …` 가 무효 처리되고 `banaction = ufw   # …` 가 `action '#'` 로 읽혀 **sshd jail 전체가 조용히 꺼졌습니다**(데몬은 시작 실패). 그래서 주석은 값 위의 별도 줄에 두고, `setup/08-fail2ban.sh` 는 재시작 전에 `fail2ban-client -t` 로 설정을 검사해 실패하면 중단합니다.

**설치 / 확인 / 해제**

```bash
sudo bash setup/08-fail2ban.sh            # 선택 설치(run-all 에는 포함되지 않음)
sudo fail2ban-client status sshd          # 감시·현재 차단 IP 확인
sudo fail2ban-client set sshd unbanip <IP>  # 특정 IP 수동 해제
sudo ufw status | grep -i deny            # banaction=ufw 라 차단 규칙이 UFW 에 보임
```

**운영 주의**

- **관리자 IP 는 반드시 `ignoreip` 에** 넣습니다. 그러지 않으면 본인 오타로 자기 IP 가 차단될 수 있습니다.
- 더 근본적으로는 **키 인증 전환 + `PasswordAuthentication no`** 가 권장됩니다(비밀번호 대입 자체가 무력화). 단 **키를 모든 관리자에게 배포·접속 확인한 뒤** 적용해야 합니다 — 키 없이 끄면 즉시 잠깁니다.

📄 `evidence/22-fail2ban.txt`

## 10. firewalld 환경 적용

RHEL/Rocky 계열처럼 UFW 대신 **firewalld** 를 쓰는 서버에서는 `setup/02-firewall-firewalld.sh` 로 동일한 정책(20022·15034 만 허용)을 적용합니다.

**사용법**

```bash
sudo bash setup/02-firewall-firewalld.sh
# 기본 zone 의 기존 서비스/포트를 모두 제거하고 SSH_PORT·AGENT_PORT 만 연 뒤 reload.
# SELinux Enforcing 이면 sshd 포트 라벨(ssh_port_t)도 20022 로 추가.
```

**확인**

```bash
firewall-cmd --state                      # running 이어야 함
firewall-cmd --list-all                   # zone 전체(서비스·포트) 요약
firewall-cmd --list-ports                 # 현재(runtime) 열린 포트: 20022/tcp 15034/tcp
firewall-cmd --permanent --list-ports     # 재부팅 후에도 유지될(permanent) 포트
```

> **runtime vs permanent** — firewalld 는 **현재 적용값(runtime)** 과 **영구 설정(permanent)** 이 분리돼 있습니다. `--permanent` 없이 바꾼 규칙은 재부팅/`reload` 시 사라지고, `--permanent` 로만 바꾼 규칙은 `--reload` 전까지 runtime 에 반영되지 않습니다. 스크립트는 `--permanent` 로 설정한 뒤 `--reload` 로 둘을 일치시킵니다. 둘이 다르면 `--list-ports` 와 `--permanent --list-ports` 결과가 어긋나므로 양쪽을 함께 확인합니다.

> **⚠ UFW 와 동시 사용 금지** — UFW 와 firewalld 는 둘 다 netfilter 를 조작하므로 한 서버에서 **함께 켜면 규칙이 충돌**합니다. firewalld 서버에서는 UFW 를 설치/활성화하지 않습니다.

**실측에서 확인한 차이** ([`evidence/17-firewalld.txt`](evidence/17-firewalld.txt))

- 허용 목록 밖 포트(서버에서 LISTEN 중인 8080)는 바깥에서 **`No route to host`** 로 즉시 거부됩니다. firewalld 기본 zone(public)은 ICMP host-prohibited 로 **REJECT** 하고, UFW 기본 정책은 응답 없이 **DROP**(timeout) 합니다. 바깥에서 본 증상이 다르므로 `remote-check.sh` 결과를 읽을 때 구분합니다.
- 컨테이너처럼 인터페이스가 zone 에 명시되지 않으면 `--get-active-zones` 가 비어 있어도 **기본 zone(public)** 이 적용됩니다.
- `--list-ports` 와 `--permanent --list-ports` 가 모두 `15034/tcp 20022/tcp` 로 일치, 기본 서비스(ssh, dhcpv6-client)는 제거되어 22 도 거부됩니다.

**monitor.sh 연동** — monitor.sh 의 방화벽 점검은 `FIREWALL` 환경변수로 제어합니다. 기본 `auto` 는 **`ufw` 가 설치돼 있으면 UFW 를 우선**하므로, firewalld 서버라도 ufw 패키지가 남아 있으면 엉뚱하게 UFW 를 봅니다. 따라서 firewalld 서버에서는 env 파일에 **`FIREWALL=firewalld` 를 명시**하는 것을 권장합니다(그러면 `systemctl is-active firewalld` 로 판단).

📄 `evidence/17-firewalld.txt`

## 11. 로그 급증 긴급 대응

> **⚠ `truncate`·`rm`·retention 실행은 되돌릴 수 없습니다. 스냅샷/백업이 없으면 복구 불가** — 지운 로그는 포렌식·감사·장애 원인 추적의 유일한 증거일 수 있습니다. 공간이 급해도 **먼저 보존**한 뒤 지웁니다.

**우선순위 한눈에 — 임시 확보 → 회전 → 모니터링** (위에서 아래 순서, 앞 단계가 끝나야 다음 단계)

- [ ] **0. 확인·보존** — 무엇이 커졌는지 특정, 보안·감사 로그면 삭제 금지, 지울 파일은 다른 디스크로 압축 사본 (아래 1·2단계)
- [ ] **1. 임시 확보** — 디스크가 꽉 차 서비스가 멈추기 직전이면 **열린 파일은 `: >` 로 내용만 비움**(삭제 아님, 아래 3단계). 가장 빠르지만 되돌릴 수 없으므로 0번 보존 뒤에만
- [ ] **2. 회전** — 다시 차지 않도록 순환·보존 정책을 적용: 내장 순환 상한 확인(`MAX_LOG_SIZE_BYTES`), `bin/log-retention.sh --dry-run` → 적용 (아래 4단계)
- [ ] **3. 원인 제거** — 로그를 쏟아내는 원인(디버그 레벨, 무한 재시도)을 멈춤 (아래 5단계)
- [ ] **4. 모니터링 재개 확인** — `df -h` 로 여유 확인, 다음 분 monitor.log 의 `DISK_USED` 가 내려갔는지, `verify/check-cron.sh` 로 관제가 다시 도는지
- [ ] **5. 기록** — 무엇을 왜 지웠고 얼마를 확보했는지 (아래 6단계)

**자동화 범위(안전 기준)** — 자동으로 지우는 것은 `log-retention.sh` 가 **30일 지난 `archive/*.gz`** 를 지우는 것 하나뿐입니다. 쓰는 중인 로그, 보안·감사 로그, 7일이 안 된 로그는 자동 삭제하지 않습니다. `DISK_USED > 80%` 는 경고·알림만 하고(§8), 비우기(`: >`)는 사람이 위 0번을 확인한 뒤에만 합니다. 급증 때 자동 삭제가 증거와 원인을 함께 지우는 것을 막기 위해서입니다.

**실행 전 체크리스트**

- [ ] **원인 파일 확인** — 어떤 파일이 커졌는지 특정(아래 1단계).
- [ ] **보안·감사 로그인가** — `auth.log`, `audit/audit.log` 등은 **삭제 금지**(법적 보존·침해 추적 대상). 커졌다면 원인(공격·오작동)부터 조사.
- [ ] **증거 보존 필요 시** 압축 사본을 **다른 디스크**로 옮긴 뒤 처리.
- [ ] **작업자·승인자 기록** — 누가 언제 무엇을 지웠는지 남김.
- [ ] **쓰는 중인 파일인지** `lsof` 로 확인(열려 있으면 `rm` 해도 공간이 안 돌아옴).

**단계별 절차**

1. **확인** — 어디가 찼고 무엇이 큰지:

   ```bash
   df -h                                        # 어느 파티션이 찼나
   du -xh --max-depth=1 /var/log | sort -h      # /var/log 안에서 큰 디렉토리
   sudo find /var/log -type f -size +100M       # 100MB 넘는 파일
   ```

2. **보존** — 지우기 전에 다른 디스크로 압축 사본:

   ```bash
   gzip -c /var/log/agent-app/big.log > /mnt/backup/big-$(date +%F).log.gz
   ```

3. **공간 확보** — **열린 파일은 `rm` 하면 fd 때문에 공간이 반환되지 않습니다.** 내용만 비웁니다:

   ```bash
   : > /var/log/agent-app/big.log          # 또는 truncate -s 0 (파일은 유지, 내용만 0)
   sudo lsof +L1                            # 이미 unlink 됐지만 열려 있어 공간을 쥔 파일 확인
   ```

4. **retention 정리** — `bin/log-retention.sh` 는 반드시 **`--dry-run` 먼저**:

   ```bash
   bin/log-retention.sh --dry-run          # 무엇을 지울지 먼저 확인
   bin/log-retention.sh                    # 확인 후 실제 적용
   ```

5. **원인 제거** — 로그 레벨을 낮추거나(디버그 로그 폭주), 루프에 빠진 프로세스를 재시작해 **급증 자체**를 멈춥니다.

6. **사후 기록** — 무엇을 왜 지웠고 얼마를 확보했는지 기록(체크리스트의 작업자·승인자 포함).

**단계별 필요 권한**

- `df`, `du`, `find`, `gzip` 조회·agent-app 로그 디렉토리 내 작업(`: >`, `log-retention.sh`)은 **agent-core** 그룹이면 됩니다.
- `/var/log` 전체 탐색, 다른 서비스 로그 truncate, `lsof +L1`, systemd journal 정리는 **root** 가 필요합니다.

**하지 말 것**

- `rm -rf /var/log/*` — 모든 서비스 로그·감사 기록을 날리고, 열린 파일은 공간도 안 돌려줍니다.
- **journal 파일 직접 삭제** — `/var/log/journal/*` 를 `rm` 하지 말고 전용 명령을 씁니다:

  ```bash
  sudo journalctl --vacuum-size=500M       # 500MB 까지 줄임
  sudo journalctl --vacuum-time=7d         # 7일 넘은 기록 제거
  ```

📄 `evidence/12-retention.txt`, `evidence/15-retention-demo.txt`

## 12. Boot Sequence 단계별 확인

run-agent.sh(앱)는 기동 시 5단계를 순서대로 확인하고, **앞 단계가 실패하면 뒤 단계는 SKIP** 한 뒤 종료합니다(exit 1). 각 단계를 **직접** 확인하는 명령과 실패 메시지를 아래에 정리합니다.

| 단계 | 앱이 확인하는 것 | 직접 확인하는 명령 | 실패 메시지 예 | 조치 |
| --- | --- | --- | --- | --- |
| 1/5 User Account | 서비스 계정(agent-admin)으로 실행 중인가(root 거부) | `sudo -iu agent-admin id` (uid ≠ 0) | `run-agent.sh` 가 앱 실행 전에 먼저 막음: `[ERROR] root 로 실행하지 마세요. 예: sudo -iu agent-admin …/bin/run-agent.sh` | `sudo -iu agent-admin …/bin/run-agent.sh` 로 실행 |
| 2/5 Environment Variables | 필수 환경변수·키 경로가 맞는가 | `sudo -u agent-admin env \| grep AGENT_` | `[2/5] … [FAIL]` / `>>> Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys` | 키 경로를 **디렉토리**(`…/api_keys`)로 지정(파일 경로 아님) |
| 3/5 Required Files | `secret.key` 존재 여부 | `ls -l …/api_keys/secret.key` | `[3/5] … [FAIL]` / `>>> Missing File: secret.key` / `>>>    (Expected location: …/api_keys/secret.key)` | `secret.key → t_secret.key` 심볼릭 링크 복원 |
| 4/5 Port Availability | 포트가 비어 있는가 | `ss -ltnp 'sport = :15034'` (출력이 비어야 함) | `[4/5] … [FAIL]` / `>>> Port 15034 is already in use.` (이때 5/5 는 `>>> Skipped due to previous critical failure.`) | 선점 프로세스 종료 또는 포트 변경(→ 7절) |
| 5/5 Log Permission | 로그 디렉토리에 쓸 수 있는가 | `sudo -iu agent-admin bash -c 'test -w "$AGENT_LOG_DIR" && echo writable'` | `[5/5] … [FAIL]` / `>>> Permission Denied: User 'agent-admin' cannot write to /var/log/agent-app` | `sudo bash setup/04-directories.sh` 로 권한 복원(→ 6절) |

모두 통과하면 `All Boot Checks Passed!` → `Agent READY` 가 뜨고 포트 LISTEN 이 시작됩니다. 실패하면 `System Boot Failed. Process Terminated.` 로 끝납니다(exit 1).

실측(`18-boot-stages.txt`)에서는 실행 전에 위 "직접 확인하는 명령" 5개를 먼저 돌려 모두 기대값임을 확인한 뒤 앱을 띄웠고, 줄마다 수신 시각을 붙여 보니 5단계 점검부터 `Agent READY` 까지 **약 40ms** 안에 끝났습니다(점검 자체는 매우 빠르고, 실패하면 그 자리에서 종료). 4·5단계 실패는 포트 선점 · 로그 디렉토리 쓰기 권한 회수로 직접 만들어 위 메시지를 확인했고, 1~3단계 실패는 `06b` 에 있습니다.

**포그라운드 캡처 위치** — 앱을 터미널(포그라운드)로 띄워 `>>> Starting Agent Boot Sequence...` 부터 `All Boot Checks Passed!` → `Agent READY` 까지 받은 원본 출력은 `06a-boot-foreground.txt` 이고, 같은 출력에 줄마다 수신 시각을 붙인 것이 `18-boot-stages.txt` 입니다. 백그라운드로 띄울 때도 같은 출력이 `/var/log/agent-app/agent-app.out` 에 남습니다.

📄 `evidence/06a-boot-foreground.txt`(5단계 전부 [OK] → Agent READY), `evidence/06b-boot-troubleshooting.txt`(실패 재현·조치), `evidence/18-boot-stages.txt`
