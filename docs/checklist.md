# 체크리스트 답변서

미션 체크리스트의 모든 항목에 대해 **충족 근거(설정·스크립트·증빙)** 와 **설명 답변**을 정리했습니다.

> 표기: 📂 파일 위치 · 🧪 자동 테스트(`bash tests/run-tests.sh`) · ▶️ 확인 명령 · 📄 증빙([`docs/evidence/`](evidence/README.md) — Ubuntu 22.04 컨테이너에서 실제 수행, 2026-10-21)

- [항목 1. 기능 동작](#항목-1-기능-동작)
- [항목 2. 구현 방식](#항목-2-구현-방식)
- [항목 3. 원리 이해](#항목-3-원리-이해)
- [항목 4. 확장 질문](#항목-4-확장-질문)

---

## 항목 1. 기능 동작

### 1-1. SSH 포트가 20022 로 바뀌었고 Root 원격 접속이 차단되는가 ✅

- 📂 `config/sshd_config.d/00-agent-hardening.conf`, `setup/01-ssh.sh` · 📄 `01-ssh.txt`, `13-remote-check.txt`(다른 호스트에서 agent-admin 접속 성공, root 는 키가 있어도 거부, 22 응답 없음)
- ▶️ `sudo sshd -T | grep -Ei '^(port|permitrootlogin) '` → `port 20022`, `permitrootlogin no` / `ss -tulnp | grep sshd` → `0.0.0.0:20022`
- 설정 파일을 직접 보는 대신 **`sshd -T`(모든 설정 조각을 합친 최종 값)** 로 확인합니다. 다른 조각 파일이 같은 키를 덮어쓰는 경우까지 걸러내기 위해서입니다.

### 1-2. 방화벽이 활성화되어 있고 20022/tcp 와 15034/tcp 만 허용되는가 ✅ (UFW)

- 📂 `setup/02-firewall.sh` · 📄 `02-firewall.txt`, `13-remote-check.txt`(바깥에서 20022 · 15034 만 open, LISTEN 중인 8080 도 DROP)
- ▶️ `sudo ufw status verbose` → `Status: active`, `Default: deny (incoming)`, 허용 규칙은 20022/tcp, 15034/tcp 와 각각의 `(v6)` 뿐
- `ufw --force reset` 으로 기존 규칙을 지운 뒤 기본 거부 + 허용 목록 2개만 넣었습니다.

### 1-3. 계정과 그룹이 요구사항대로 구성되어 있는가 ✅

- 📂 `setup/03-accounts.sh` · 📄 `03-accounts.txt`
- ▶️ `id agent-admin` → agent-common, agent-core / `id agent-dev` → agent-common, agent-core / `id agent-test` → agent-common 만

### 1-4. 앱이 Boot Sequence 5단계 [OK] 를 통과하고 "Agent READY" 가 출력되는가 ✅

- 📂 `bin/run-agent.sh` (root 실행 거부, 환경 파일 로드, CPU 에 맞는 바이너리 선택) · 📄 `06-boot.txt`, `06a-boot-foreground.txt`(포그라운드 실행 TTY 기록), `06b-boot-troubleshooting.txt`(명세값 그대로일 때의 실패 재현)
- 제공 바이너리로 실제 실행해 확인했습니다. 과제 문서의 `AGENT_KEY_PATH=…/t_secret.key` 그대로는 실패해서, Boot 메시지를 근거로 **키 디렉토리 경로 + `secret.key` 링크**로 맞췄습니다 → [`report.md` 5-1](report.md#5-1-명세와-실제-동작의-차이)

### 1-5. monitor.sh 가 프로세스/포트를 점검하고 비정상이면 exit 1 로 끝나는가 ✅

- 📂 `bin/monitor.sh` (`find_app_pids`, `port_listening`) · 🧪 `프로세스 없음 → 종료 코드 1`, `프로세스는 있는데 포트 없음 → 종료 코드 1`
- ▶️ 앱을 끄고 `monitor.sh; echo $?` → `Checking process 'agent-app'... [FAIL]`, `1` · 📄 `14-failure-cases.txt` (실제 서버에서 앱 중지 → exit 1, monitor.log 기록 안 함, cron.log 에 원인)

### 1-6. /var/log/agent-app/monitor.log 가 지정 포맷으로 누적되는가 ✅

- 🧪 `로그 포맷 [YYYY-MM-DD HH:MM:SS] PID CPU MEM DISK_USED` (정규식 검사), `두 번째 실행은 덧붙이기(>>)로 2줄` · 📄 `08-monitor-log.txt`

```
[2026-10-12 17:59:47] PID:15491 CPU:32.3% MEM:10.1% DISK_USED:32%
```

### 1-7. cron 매분 실행으로 monitor.log 가 자동으로 늘어나는가 ✅

- 📂 `config/crontab.agent-admin`, `setup/07-cron.sh` · 📄 `09-cron.txt` (등록 내용 + 70초 전후 줄 수 비교)
- ▶️ `sudo crontab -u agent-admin -l`, `wc -l /var/log/agent-app/monitor.log` 를 1분 간격으로 두 번

### 1-8. monitor.log 용량 관리(10MB/10개)가 설정되어 있고 동작을 설명할 수 있는가 ✅

- 📂 `bin/monitor.sh::rotate_log` (`MAX_LOG_SIZE_BYTES=10485760`, `MAX_LOG_FILES=10`) · 🧪 `파일 수 상한 유지`, `가장 오래된 파일은 삭제됨` · 📄 `10-log-capacity.txt`
- **동작**: 기록 직전에 크기를 보고 10MB 이상이면 `.8→.9, …, .1→.2, monitor.log→.1` 로 한 칸씩 밀고 원래 `.9` 는 버린 뒤 새 파일을 만듭니다. 그래서 항상 **현재 + 9개 = 10개 이하**입니다. cron 과 수동 실행이 겹쳐도 `flock` 잠금으로 순환이 꼬이지 않습니다.

---

## 항목 2. 구현 방식

### 2-1. 프로세스 식별과 포트 확인에 쓴 명령, 그리고 선택 이유

**프로세스**: `/proc/<pid>/cmdline` 의 실행 파일 이름(argv[0], python 이면 argv[1])을 정규식으로 비교합니다.
- `pgrep -f agent-app` 은 명령줄 **전체**를 검색해 `…/agent-app/bin/monitor.sh` (자기 자신), `tail -f …/agent-app.log` 까지 잡습니다. 테스트 `이름에 agent-app 이 들어간 다른 프로세스(*.sh)는 앱으로 보지 않음` 이 이 오탐을 검사합니다.
- `pgrep -x` 는 프로세스 이름이 15자에서 잘려(`agent-app-linu`) 정확히 맞출 수 없습니다.
- 제공 앱은 PyInstaller 라 같은 이름의 프로세스가 2개(부모 부트로더 + 자식 실제 앱) 뜹니다. **포트를 가진 PID** 를 골라야 실제 앱의 PID 와 자원이 기록됩니다(부모를 고르면 RSS 2MB 로 잘못 기록되는 것을 실제로 확인).

**포트**: `ss -Hltn "sport = :15034"`.
- `-l` LISTEN 만, `-t` TCP 만, `-n` 숫자 그대로(DNS·서비스 이름 변환 없음 → 빠르고 정확), `-H` 머리글 없음 → 결과가 비었는지만 보면 됩니다.
- `netstat` 은 net-tools 가 기본 설치되지 않는 배포판이 많고, `grep 15034` 는 `115034` 나 원격 주소에도 걸립니다. `ss` 필터는 로컬 포트만 정확히 비교합니다.
- `ss` 가 없는 최소 환경에서는 `/proc/net/tcp` 를 직접 읽습니다(로컬 주소 끝 16진수 포트 + 상태 `0A`=LISTEN).

### 2-2. CPU/MEM/DISK 를 어떻게 추출·파싱했고, 로그 포맷을 왜 그렇게 고정했는가

| 값 | 추출 | 이유 |
| --- | --- | --- |
| CPU | `/proc/stat` 를 1초 간격 2회 → `100×(1−Δidle/Δtotal)` | `top -bn1` 의 첫 값은 부팅 후 평균이라 '지금' 이 아님 |
| MEM | `(MemTotal−MemAvailable)/MemTotal` | `MemFree` 는 캐시를 사용 중으로 세서 과대평가 |
| DISK | `df -P /` 의 5번째 열 | `-P` 는 한 줄 고정 형식이라 열이 안 밀림 |

포맷 `[YYYY-MM-DD HH:MM:SS] PID:… CPU:…% MEM:…% DISK_USED:…%` 은 ① `key:value` 고정 순서라 `awk`/`grep` 으로 바로 분석되고(report.sh 가 이 포맷에 의존) ② 시각 형식이 **문자열 순서 = 시간 순서**라 구간 검색을 문자열 비교로 할 수 있으며 ③ PID 가 바뀐 줄 = 앱 재시작 시점이라 장애 추적에 쓰입니다. 소수 계산은 `LC_ALL=C` + `awk` 로 해서 로케일에 따라 `25,3` 처럼 바뀌지 않게 했습니다.

### 2-3. 소유자(agent-dev)와 실행자(agent-admin, cron) 권한 정책을 어떻게 만족시켰는가

`install -o agent-dev -g agent-core -m 0750` (`setup/06-install-monitor.sh`)

| 계정 | 해당 권한 | 결과 |
| --- | --- | --- |
| agent-dev (소유자) | `rwx` | 수정·실행 |
| agent-admin (agent-core 그룹) | `r-x` | **읽고 실행 가능, 수정 불가** → cron 실행자 |
| agent-test (그 외) | `---` | 내용도 볼 수 없음 |

실행자가 스크립트를 수정할 수 없으니, cron 이 매분 실행하는 코드를 운영 계정이 몰래 바꿀 수 없습니다. 디렉토리 `bin/` 도 `agent-dev:agent-core 2750` 이라 admin 은 새 파일을 넣을 수도 없습니다. 📄 `04-permissions.txt` 의 접근 매트릭스에서 `monitor.sh (execute)` O O X, `monitor.sh (modify)` X O X 로 확인합니다.

### 2-4. 용량 기반 로그 관리(10MB/10개)를 어떤 방식으로 구현했는가

**스크립트 내장 방식**을 택했습니다(`rotate_log`). logrotate 는 보통 하루 한 번 실행돼 `size 10M` 조건을 최대 하루 늦게 확인하지만, 내장 방식은 **기록할 때마다(매분)** 확인해 상한을 정확히 지킵니다. 추가 패키지·root 권한도 필요 없습니다(agent-core 가 로그 디렉토리에 쓸 수 있으므로). logrotate 를 쓰는 대안 설정도 `config/logrotate.d/agent-app`(`size 10M`, `rotate 9`)에 두었고, 두 방식을 동시에 쓰면 이중으로 순환되므로 하나만 쓰도록 안내했습니다.

---

## 항목 3. 원리 이해

### 3-1. SSH 포트 변경과 Root 접속 차단이 왜 보안에 효과적인가 (위협 모델 관점)

| 위협 | 대응 | 효과 |
| --- | --- | --- |
| 인터넷 전체를 22번으로 훑는 **자동화 봇의 무차별 대입** | 포트 20022 | 대부분의 봇은 22번만 시도 → 공격 시도·로그 소음이 크게 줄어듦 |
| 어디에나 있는 계정 `root` 의 비밀번호 추측 | `PermitRootLogin no` | 공격자가 **계정 이름부터 알아야** 함. 뚫려도 일반 권한이라 피해가 제한됨 |
| 권한 남용 추적 불가 | 일반 계정 → `sudo` | 누가 언제 무엇을 했는지 `auth.log` 에 남음 |

포트 변경은 **은닉**이라 포트 스캔으로 결국 찾을 수 있습니다. 그래서 root 차단, 방화벽, (권장) 키 인증과 **겹쳐서** 쓰는 것이 핵심입니다(심층 방어).

### 3-2. api_keys 와 로그 디렉토리를 agent-core 로 제한한 이유 (최소 권한 원칙)

최소 권한 원칙은 "업무에 꼭 필요한 권한만 준다" 입니다. QA(agent-test)의 업무는 업로드 파일 확인이라 키와 로그는 필요 없습니다.
- **API 키**가 유출되면 외부에서 이 서비스를 사칭할 수 있습니다.
- **로그**에는 내부 경로, 사용자 정보, 오류 상세가 담겨 공격자에게 지도가 됩니다. 로그를 **수정**할 수 있으면 흔적을 지울 수도 있습니다.

권한을 가진 사람이 적을수록 실수·계정 탈취가 생겼을 때 피해 범위(blast radius)가 줄어듭니다. 그래서 공유 영역(upload_files: agent-common)과 보안 영역(api_keys, 로그: agent-core)을 디렉토리 단위로 분리했습니다.

### 3-3. "경고만 하고 종료하지 않는 항목" 을 분리한 운영상의 이유

- **종료(exit 1)** 하는 것은 프로세스·포트 = 서비스가 **이미 죽은 상태**입니다. 이때는 종료 코드로 즉시 알려야 상위 모니터링이 장애로 인식하고, 죽은 서비스의 자원 수치는 의미가 없습니다.
- **경고만** 하는 것(방화벽 비활성, 임계값 초과)은 서비스는 살아 있지만 위험한 **상태**입니다. 여기서 스크립트를 멈추면 **바로 그 순간의 데이터 기록이 끊깁니다.** CPU 가 치솟는 장면이야말로 나중에 원인 분석에 가장 필요한 데이터이기 때문에, 경고를 남기면서 수집은 계속합니다.

### 3-4. 리다이렉션 `>` 와 `>>` 의 차이, 로그 누적에 `>>` 가 필요한 이유

| 기호 | 동작 |
| --- | --- |
| `>` | 파일을 **비우고(truncate)** 처음부터 쓴다 |
| `>>` | 파일 **끝에 덧붙인다(append)** |

monitor.sh 가 매분 `>` 로 쓰면 항상 마지막 한 줄만 남아 추이(누적 기록)를 볼 수 없습니다. `>>` 는 `O_APPEND` 로 열려서 커널이 매번 파일 끝으로 이동한 뒤 쓰므로, cron 실행과 수동 실행이 겹쳐도 한 줄짜리 기록끼리 덮어쓰지 않습니다. crontab 의 `>> cron.log 2>&1` 도 같은 이유로 `>>` 를 씁니다(`2>&1` 은 stderr 를 stdout 과 같은 곳으로).

---

## 항목 4. 확장 질문

### 4-1. 모니터링 대상이 Nginx 로 바뀐다면 monitor.sh 에서 바꿀 핵심 포인트는

| 포인트 | 현재 (agent-app) | Nginx 로 바꾸면 |
| --- | --- | --- |
| 프로세스 | 실행 파일 이름 `^agent[_-]app` | `APP_PROCESS_REGEX='^nginx$'`. master 1개 + worker N개 → **master 존재** + worker 수 ≥ 1 확인. `systemctl is-active nginx` 를 함께 보면 좋다 |
| 포트 | 15034 | `AGENT_PORT=80` (+ HTTPS 면 443 을 추가로 검사) |
| 응답 확인 | LISTEN 여부 | 포트가 열려도 502 를 낼 수 있으므로 `curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/health` 가 200 인지 확인 (L7 health check) |
| 로그 | 앱 로그 | `/var/log/nginx/access.log` 의 최근 1분 **5xx 비율**, `error.log` 의 `upstream timed out`·`connect() failed` 건수 |
| 임계값 | CPU 20% / MEM 10% | 웹 서버는 CPU 보다 **활성 연결 수**(`stub_status`), 응답 시간, 5xx 비율이 더 중요. `worker_connections` 대비 사용률 |

스크립트는 대상 값이 모두 환경변수라 프로세스 정규식·포트·라벨은 코드 수정 없이 바꿀 수 있고, HTTP 상태 검사와 로그 집계만 함수로 추가하면 됩니다.

### 4-2. "프로세스는 살아 있는데 포트가 안 열리는" 상황의 원인 후보와 확인 순서

1. **아직 기동 중**인가 — 초기화(설정 로드, DB 연결) 단계. → 앱 로그 마지막 줄, 몇 초 뒤 재확인
2. **다른 주소·포트로 열었나** — `127.0.0.1` 만 바인딩, 환경변수 오타로 다른 포트. → `ss -ltnp | grep <PID>` 로 그 PID 가 실제로 연 포트 확인, `cat /proc/<PID>/environ | tr '\0' '\n' | grep PORT`
3. **포트 충돌** — 이미 다른 프로세스가 사용(`Address already in use`). → `ss -ltnp 'sport = :15034'` 로 주인 PID 확인
4. **권한** — 1024 미만 포트를 일반 계정으로(이 앱은 15034 라 해당 없음), SELinux 포트 라벨. → 앱 로그의 `Permission denied`, `ausearch -m avc`
5. **프로세스가 멈춤** — Deadlock 등으로 listen 전에 정지. → `top -H -p <PID>` CPU 0%, `cat /proc/<PID>/status` 의 State, 스레드 상태(`ps -L`)
6. **방화벽 문제와 구분** — 방화벽은 LISTEN 자체를 막지 않는다. 로컬에서 LISTEN 인데 외부에서만 안 되면 방화벽, 로컬에서도 LISTEN 이 없으면 앱 문제

확인은 **싼 것부터, 범위가 좁은 것부터**: 로그 → `ss` → 환경변수 → 충돌 → 권한 → 스레드 상태 순서입니다.

### 4-3. 로그가 급증해 디스크가 찰 위험이 있다면 운영자의 단기/중기 대응

**단기 (지금 디스크를 살린다)**
- `df -h`, `du -sh /var/log/* | sort -h` 로 원인 파일 확인
- 급증한 로그를 **지우지 말고 비운다**: `: > big.log` 또는 `truncate -s 0`. 쓰고 있는 파일을 `rm` 하면 프로세스가 파일을 계속 잡고 있어 **공간이 반환되지 않는다**(`lsof +L1` 로 확인 가능)
- 필요한 부분만 남기고 압축: `gzip` 후 다른 디스크로 이동
- 원인 프로세스의 로그 레벨을 낮추거나(DEBUG → INFO) 재시작

**중기 (재발 방지)**
- 용량 상한: monitor.sh 내장 순환(10MB×10), 앱 로그도 logrotate `size` + `maxsize`
- 시간 기반 보존: log-retention.sh(7일 압축, 30일 삭제)
- `/var/log` 를 **별도 파티션**으로 분리해 로그가 차도 루트 파티션(서비스)이 멈추지 않게
- journald `SystemMaxUse=` 설정, 디스크 사용률 경고(현재 80%)를 단계별(80/90/95%)로
- 장기적으로 중앙 로그 수집(Loki, ELK)으로 서버에는 짧게만 보관
