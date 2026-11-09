# 동료 평가 피드백 반영 체크리스트

동료 평가 19개 항목(PASS 18 · FAIL 1)에서 받은 **부족한 점**과 **보완 요청**을 하나도 빼지 않고 반영했습니다. 문서만 쓰고 끝내지 않고, 절차·스크립트는 **Ubuntu 22.04 서버(증빙 컨테이너)에서 실제로 실행**해 결과를 [`evidence/`](evidence/README.md) 에 남겼습니다(2026-11-09).

- 운영 절차 → [`operations.md`](operations.md) (운영 매뉴얼, 12개 절)
- FAIL 항목 #17 → [`webserver-migration.md`](webserver-migration.md) (웹서버 전환 가이드 + nginx 실측)
- 새 도구 → `bin/diagnose-port.sh`(포트 미개방 진단), `verify/check-cron.sh`(cron 연동 점검), `bin/alert.sh` + `monitor.sh` 의 `ALERT_CMD`(경고 알림), `setup/08-fail2ban.sh`(무차별 대입 자동 차단)
- 새 증빙 11개 → `16` ~ `26`
- **2차 평가(19개, FAIL 1)** 보완 → [아래 2차 표](#2차-평가-반영) · 증빙 [`27`](evidence/27-feedback-round2.txt) · `check-cron.sh` 7단계(cron 환경 env 로드) · `monitor.sh` 실패 시 `[HINT]` 복구 안내

## 한눈에 보기

| # | 판정 | 보완 요청 (요약) | 반영 | 근거 | 상태 |
| --- | --- | --- | --- | --- | :---: |
| 1 | PASS | `ss -tuln` 실행 캡처 | setup **전후** `ss -tulnp`·`ss -tlnp` 전체 출력 비교, 증빙 수집 스크립트에도 전체 출력 추가 | [`16`](evidence/16-ports.txt), `verify/collect-evidence.sh` | ✅ |
| 2 | PASS | firewalld 환경 증빙 | firewalld 서버를 따로 띄워 `02-firewall-firewalld.sh` 실행, `firewall-cmd` 출력·바깥 접속·monitor 연동 | [`17`](evidence/17-firewalld.txt), [운영 §10](operations.md#10-firewalld-환경-적용) | ✅ |
| 3 | PASS | 해당 없음 | (유지) | [`03`](evidence/03-accounts.txt) | — |
| 4 | PASS | Boot 단계별 기록 | 단계마다 사전 점검 명령 → 줄별 시각 기록 → 4·5단계 실패 재현 | [`18`](evidence/18-boot-stages.txt), [운영 §12](operations.md#12-boot-sequence-단계별-확인) | ✅ |
| 5 | PASS | exit 1 실제 캡처 | 프로세스 없음·포트 없음·설정 오류 → exit 1, 실행 환경 오류 3종 → exit 2 | [`19`](evidence/19-exit-codes.txt), [`14`](evidence/14-failure-cases.txt) | ✅ |
| 6 | PASS | extended 포맷 예시 | 실제 서버에서 기록한 extended 줄 + 필드 설명 + report.sh 호환 실측 | [운영 §2](operations.md#2-monitorlog-포맷과-파싱-예시), [`19`](evidence/19-exit-codes.txt) ⑥ | ✅ |
| 7 | PASS | cron 실패·권한 오류 복구, syslog·monitor.log 연동 확인 스크립트 | `verify/check-cron.sh`(6단계 → 2차에서 env 로드 7단계 추가, 실패마다 복구 명령) + 증상별 복구 표 + 실제 장애 2종 재현·복구 | [`20`](evidence/20-cron-check.txt), [운영 §5](operations.md#5-cron-장애-점검과-복구) | ✅ |
| 8 | PASS | logrotate 충돌 방지·선택 지침 | 비교표, 동시 사용 금지 이유, 전환·되돌리기 절차, 둘 다 켜졌는지 점검 명령 | [운영 §4](operations.md#4-로그-순환-방식-선택-지침-내장-순환-vs-logrotate), [`24`](evidence/24-logrotate.txt) | ✅ |
| 9 | PASS | 환경별(컨테이너/VM) 선택 기준 표 | 7개 항목 × 컨테이너 / VM / 물리 서버 + 이 저장소의 선택 | [운영 §1](operations.md#1-운영-환경별-선택-기준-컨테이너--vm--물리-서버) | ✅ |
| 10 | PASS | 샘플 로그 + awk/sed 파싱 예시 | 파싱 예시 6개(실행해서 검증, extended 줄에서 틀리는 함정 포함) | [운영 §2](operations.md#2-monitorlog-포맷과-파싱-예시) | ✅ |
| 11 | PASS | cron 실행자 권한 매트릭스, 권한 오류 체크 절차 | 경로별 필요 권한·부여 방식 표, 설치 직후 `stat` 비교, 실행 권한 장애 재현 → 복구 | [운영 §6](operations.md#6-권한-점검--복구--감사), [`20`](evidence/20-cron-check.txt) ③ | ✅ |
| 12 | PASS | logrotate 설정 본문 검토, 운영 지침 | 설정 줄 단위 해설 + 실측(0664 설정 파일은 무시됨, `su` 없으면 순환 거부) | [운영 §4](operations.md#4-로그-순환-방식-선택-지침-내장-순환-vs-logrotate), [`24`](evidence/24-logrotate.txt) | ✅ |
| 13 | PASS | 무차별 대입 탐지·자동 차단 권장 설정 | 로그 기준 탐지 명령 + fail2ban jail(5회/10분 → 1시간, UFW 로 차단) + 선택 설치 스크립트, 실제 차단·해제 | [`22`](evidence/22-fail2ban.txt), [운영 §9](operations.md#9-ssh-무차별-대입-대응) | ✅ |
| 14 | PASS | 권한 오류 점검·복구 명령, 롤백·감사 | 점검 명령, 멱등 setup 재실행, ACL 백업/복원, auditd 규칙 | [운영 §6](operations.md#6-권한-점검--복구--감사) | ✅ |
| 15 | PASS | 경고 알림 예시 | `monitor.sh` `ALERT_CMD` 훅 + `bin/alert.sh`(syslog · 웹훅 · 10분 쿨다운), 실제 웹훅 수신 | [`25`](evidence/25-alert.txt), [운영 §8](operations.md#8-경고-알림-연동) | ✅ |
| 16 | PASS | `>` 덮어쓰기 실패 사례 | 실수 3가지(crontab `>`, 스크립트 `>`, `2>&1` 순서)를 실제 서버에서 재현 | [`26`](evidence/26-redirect.txt), [운영 §3](operations.md#3-리다이렉션-실수-사례--와-) | ✅ |
| **17** | **FAIL** | **웹서버 전환 체크포인트 가이드가 없음** | **별도 가이드 작성 + nginx 를 실제로 설치해 전환 → 검증 → 롤백까지 실행** | [`webserver-migration.md`](webserver-migration.md), [`23`](evidence/23-nginx-migration.txt) | ✅ |
| 18 | PASS | 포트 미개방 원인별 진단 자동화·체크리스트 | `bin/diagnose-port.sh`(8단계) + 원인 6가지를 실제로 만들어 진단 | [`21`](evidence/21-port-diagnosis.txt), [운영 §7](operations.md#7-포트-미개방-진단-체크리스트) | ✅ |
| 19 | PASS | 긴급 대응 절차, 복구 불가 경고 | 경고 박스 + 실행 전 체크리스트 + 6단계 절차 + 단계별 필요 권한 + 하지 말 것 | [운영 §11](operations.md#11-로그-급증-긴급-대응) | ✅ |

## 항목별 상세

### #1 SSH 포트 변경 적용 — `ss` 실행 캡처

- [x] 새 서버에서 setup **전** `ss -tulnp` (sshd `0.0.0.0:22`) → setup **후** (sshd `0.0.0.0:20022`, agent-app `0.0.0.0:15034`, 22 없음)를 같은 파일에 나란히 기록
- [x] `ss -tlnp` 전체 출력, `sshd -T` 최종값(`port 22 / permitrootlogin without-password` → `port 20022 / permitrootlogin no`) 전후 비교
- [x] 외부에서 LISTEN 하는 포트가 20022 · 15034 뿐이고 방화벽 허용 규칙과 일치함을 정리
- [x] `verify/collect-evidence.sh` 의 SSH 증빙에 grep 없는 `ss -tulnp` 추가 → 다음 수집부터 자동 포함

### #2 방화벽 — firewalld 환경 증빙

- [x] 같은 Ubuntu 22.04 이미지로 별도 서버(`fw-server`)를 띄워 UFW 를 지우고 firewalld 설치 → `setup/02-firewall-firewalld.sh` 실행
- [x] `firewall-cmd --state / --list-all / --list-ports / --permanent --list-ports / --list-services` — runtime 과 permanent 가 `15034/tcp 20022/tcp` 로 일치, 기본 서비스(ssh, dhcpv6-client) 제거
- [x] 바깥에서 접속: 20022 · 15034 open, LISTEN 중인 8080 과 22 는 `No route to host`(firewalld 는 REJECT, UFW 는 DROP 이라 증상이 다름을 문서화)
- [x] `monitor.sh` `FIREWALL=firewalld` 점검(active → OK, 중지 → 경고만), `diagnose-port.sh` 8단계가 firewalld 규칙 확인

### #4 Boot Sequence — 단계별 실행 로그

- [x] 1/5 ~ 5/5 각 단계가 확인하는 조건을 앱 실행 **전에** 직접 점검(`id`, `env`, 키 파일, `ss`, `test -w`)
- [x] `script` 로 받은 TTY 출력에 줄마다 수신 시각을 붙여 기록(점검 시작부터 `Agent READY` 까지 약 40ms)
- [x] 4/5(포트 선점) · 5/5(로그 디렉토리 쓰기 권한 회수) 실패를 실제로 만들어 앱의 실패 메시지 기록 — 1~3단계 실패는 기존 `06b`
- [x] 운영 매뉴얼 §12 에 단계별 확인 명령 · 실제 실패 메시지 · 조치 표

### #5 Health Check 실패 — exit 1 실제 캡처

- [x] 앱 중지 → `Checking process 'agent-app'... [FAIL]`, exit 1, monitor.log 줄 수 변화 없음
- [x] 같은 이름의 프로세스는 있는데 LISTEN 안 함 → `Checking port 15034... [FAIL]`, exit 1
- [x] 설정 오류(AGENT_PORT=15999) → 포트 FAIL, exit 1
- [x] exit 2 세 가지: 로그 디렉토리 쓰기 불가, 잘못된 옵션, 숫자가 아닌 임계값
- [x] 기존 `14-failure-cases.txt`(cron 실행 중 앱 중지 → cron.log 에 원인)와 연결

### #6 · #10 로그 포맷 — extended 예시, 파싱 예시

- [x] `MONITOR_LOG_FORMAT=extended` 로 실제 기록한 줄과 추가 필드(P_CPU · P_MEM · RSS · THREADS · FIREWALL) 설명
- [x] report.sh 가 extended 줄도 정상 집계함을 실측
- [x] awk/sed 파싱 예시 6개(평균, 최대와 시각, 시간대, 값 추출, 재시작 지점, RSS 추이)를 basic + extended 혼합 파일로 실행해 검증
- [x] 검증 중 발견: `sed 's/.*CPU:…'` 는 extended 줄에서 `P_CPU` 를 잡음 → `' CPU:'` 로 고친 예시와 함정을 문서화

### #7 · #11 cron — 실패·권한 오류 복구, 연동 확인 스크립트

- [x] `verify/check-cron.sh`: crontab 등록 → cron 서비스 → 실행 권한(`sudo -u agent-admin test -x/-w`) → syslog CRON 기록과 경과 시간(없으면 journalctl) → monitor.log 마지막 기록 → cron.log 최근 오류, 실패마다 `→ 복구:` 명령
- [x] 자동 테스트 추가(정상, 오래된 기록, crontab 누락, cron.log 오류, RFC3339 syslog, 잘못된 인자)
- [x] 실제 장애 재현: cron 서비스 중지 → 점검 FAIL → 제시된 명령으로 복구 → OK / monitor.sh 권한 0700 → cron.log `Permission denied` → `setup/06-install-monitor.sh` 재실행 → OK
- [x] 운영 매뉴얼 §5 증상 → 원인 → 확인 → 복구 표(9가지), §6 cron 실행자 권한 매트릭스와 설치 직후 점검 절차
- [x] `verify/collect-evidence.sh` 의 cron 증빙에 check-cron 결과 포함

### #8 · #12 로그 순환 — 방식 선택, logrotate 본문 검토

- [x] 내장 순환 vs logrotate 비교표, 동시 사용 금지 이유 3가지, 전환·되돌리기 절차, 둘 다 켜졌는지 점검 명령
- [x] `config/logrotate.d/agent-app` 줄 단위 해설
- [x] 실측 1: 저장소에서 받은 설정 파일(0664)은 logrotate 가 **조용히 무시** → 설치 명령을 `install -m 0644 -o root` 로 정정
- [x] 실측 2: `su` 지시어가 없으면 그룹 쓰기 가능 디렉토리라 순환 거부, 넣으면 `.1 → .2 → .3` 순환 확인

### #9 운영 환경별 선택 기준

- [x] 프로세스 탐지 · 포트 확인 · CPU/MEM · 디스크 · 방화벽 · 스케줄러 · 로그 수집 × 컨테이너 / VM / 물리 서버 표 + 선택 기준 요약

### #13 SSH 무차별 대입

- [x] 로그 기준 탐지 명령(IP 별 실패 집계, 최근 10분 건수), 정상 오타 vs 봇 판단 기준표
- [x] `config/fail2ban/jail.d/agent-sshd.local` + `setup/08-fail2ban.sh`(선택 단계, `DRY_RUN` 지원)
- [x] 검증 중 발견: fail2ban 은 값 뒤의 `# 주석` 까지 값으로 읽어 jail 이 꺼짐 → 주석을 별도 줄로, 설치 스크립트가 `fail2ban-client -t` 로 검사 후에만 재시작
- [x] 실제로 다른 호스트에서 비밀번호 대입 → 차단(`ufw status` 에 규칙) → 차단 중 접속 불가 → 해제

### #14 권한 — 점검·복구·롤백·감사

- [x] 점검 명령 목록(`namei -l`, `sudo -u … test`, `getfacl`, `id`), 멱등 setup 재실행, `getfacl -R` 백업 / `setfacl --restore`, auditd 규칙

### #15 경고 알림

- [x] `monitor.sh` 에 `ALERT_CMD` 훅(경고 → WARNING, Health Check 실패 → CRITICAL, 10초 timeout, 결과에 영향 없음)
- [x] `bin/alert.sh`: syslog(`logger -t agent-monitor`) · 웹훅(JSON) · 파일, 숫자만 다른 같은 경고는 10분에 1번
- [x] 자동 테스트 추가, 실제 서버에서 다른 호스트의 웹훅 수신기가 JSON 2건(경고·장애)만 받음을 확인
- [x] 검증 중 발견: monitor.sh 는 env 를 export 하지 않아 웹훅 주소가 alert.sh 에 전달되지 않음 → alert.sh 가 env 를 직접 읽도록 수정

### #16 리다이렉션 실수 사례

- [x] crontab 의 `>`(마지막 실행분만 남음), 스크립트의 `>`(항상 1줄), `2>&1 >>` 순서(오류가 파일에 안 남음)를 실제로 재현

### #17 (FAIL) 웹서버 전환 가이드

- [x] [`webserver-migration.md`](webserver-migration.md): 바꿀 값 표 → 전환 전 체크포인트 → 프로세스 · 포트 · 로그 · 임계값 체크포인트 → 전환 절차 7단계 → 롤백 → 전환 후 검증 체크리스트
- [x] [`config/examples/monitor-nginx.env`](../config/examples/monitor-nginx.env): 공용 env 는 그대로 두고 관제 대상만 바꾸는 별도 파일
- [x] nginx 1.18 을 실제로 설치해 가이드 순서대로 전환 → 검증 → 롤백
- [x] 실측으로 찾은 함정 2가지 문서화: **포트만 80 으로 바꾸면 거짓 OK**, `^nginx$` 는 nginx 가 명령줄을 바꿔서 **하나도 못 찾음**
- [x] 기존 체크리스트 답변·발표 자료의 `APP_PROCESS_REGEX='^nginx$'` 를 실측에 맞게 `^nginx([: ].*)?$` 로 정정

### #18 포트 미개방 진단

- [x] `bin/diagnose-port.sh` 8단계: 프로세스 → LISTEN(루프백만이면 WARN) → 앱이 실제로 연 포트 → 충돌 → 환경변수 → 1024 미만 권한 → 프로세스 상태 → 방화벽 규칙
- [x] 자동 테스트 13개(정상, 규칙 없음, 미개방, 루프백, 다른 포트, 충돌, 잘못된 인자)
- [x] 실제 서버에서 원인 6가지를 만들어 진단 + 바깥에서 접속 결과 대조
- [x] 운영 매뉴얼 §7 단계별 표와 판단 흐름도

### #19 로그 급증 긴급 대응

- [x] 복구 불가 경고 박스, 실행 전 체크리스트(보안·감사 로그 삭제 금지, 증거 보존, 작업자·승인자 기록, `lsof`)
- [x] 확인 → 보존 → 공간 확보(`rm` 대신 truncate 이유) → retention `--dry-run` 먼저 → 원인 제거 → 사후 기록, 단계별 필요 권한, 하지 말 것

## 보완하며 실제로 찾은 문제

문서를 쓰고 끝냈다면 남았을 문제들입니다. 모두 고치고 증빙에 기록했습니다.

| 발견 | 어디서 | 조치 |
| --- | --- | --- |
| `APP_PROCESS_REGEX='^nginx$'` 는 nginx 를 하나도 못 찾음 | nginx 실측(`23`) | 정규식 `^nginx([: ].*)?$`, 기존 답변·슬라이드 정정 |
| 포트만 바꾸면 다른 앱 PID 로 **거짓 OK** | nginx 실측(`23`) | 프로세스·포트를 한 env 파일로 묶어 함께 바꾸도록 가이드 |
| 웹훅 주소가 alert.sh 에 전달되지 않음(export 안 됨) | 알림 실측(`25`) | alert.sh 가 env 파일을 직접 읽도록 수정 |
| 저장소의 logrotate 설정(0664)은 logrotate 가 무시 | logrotate 실측(`24`) | 설치 명령을 `install -m 0644 -o root` 로 |
| `sed 's/.*CPU:…'` 가 extended 줄에서 P_CPU 를 잡음 | 파싱 예시 검증 | `' CPU:'` 로 고친 예시 + 함정 설명 |
| 경고만 있어도 진단 결론이 "포트 정상" | 포트 진단 실측(`21`) | 결론에 확인 필요 건수와 첫 WARN 표시 |
| fail2ban 설정의 값 뒤 `# 주석` 까지 값으로 읽혀 jail 이 꺼짐 | fail2ban 실측(`22`) | 주석을 별도 줄로, `08-fail2ban.sh` 가 `fail2ban-client -t` 통과 후에만 재시작 |

## 2차 평가 반영

2차 평가의 19개 항목은 대부분 "한 줄 보강" 요청이었고, 그중 상당수는 1차 보완에서 이미 들어갔지만 **커밋 전이라 평가자가 보지 못한 것**이었습니다(16~26번 증빙, `flock` 잠금 등). 그런 항목은 위치를 명시했고, 실제로 빠져 있던 것(계정 잠금 상태, 로그 타임존, cron 환경 env 로드 검증, 헬스체크 실패 안내, latency 지표 등)은 새로 넣은 뒤 **같은 Ubuntu 22.04 서버에서 다시 실측**해 [`evidence/27-feedback-round2.txt`](evidence/27-feedback-round2.txt) 한 파일에 항목 번호(①~⑩)로 모았습니다.

| # | 판정 | 보완 요청 | 반영 | 근거 | 상태 |
| --- | --- | --- | --- | --- | :---: |
| 1 | PASS | `ss -tuln` 출력 캡처 | (1차에서 반영) setup 전후 `ss -tulnp` 전체 출력 | [`16`](evidence/16-ports.txt), [`01`](evidence/01-ssh.txt) | ✅ |
| 2 | PASS | firewalld 환경 출력 | (1차에서 반영) firewalld 서버 실측 | [`17`](evidence/17-firewalld.txt), [운영 §10](operations.md#10-firewalld-환경-적용) | ✅ |
| 3 | PASS | 계정 잠금·비밀번호 정책 상태 | `passwd -S`(세 계정 모두 L 잠김), `chage -l`, `login.defs`, `sshd -T` 인증 방식 + 운영 지침(키 확인 후 `PasswordAuthentication no` 권장), 증빙 수집 스크립트에도 추가 | [`27`](evidence/27-feedback-round2.txt) ①, [운영 §6](operations.md#6-권한-점검--복구--감사) | ✅ |
| **4** | **FAIL** | **Boot Sequence · `Agent READY` 포그라운드 캡처** | 이미 있던 포그라운드 캡처(`06a`)와 줄별 시각 기록(`18`)의 위치를 체크리스트·운영 매뉴얼·증빙 목록에 명시. 백그라운드 실행 시 같은 출력이 남는 `agent-app.out` 도 안내 | [`06a`](evidence/06a-boot-foreground.txt), [`18`](evidence/18-boot-stages.txt), [운영 §12](operations.md#12-boot-sequence-단계별-확인) | ✅ |
| 5 | PASS | 헬스체크 실패 시 확인 절차 | `monitor.sh` 가 `[ERROR]` 다음에 `[HINT]` 로 앱 출력 파일·재기동 명령(프로세스 없음), `diagnose-port.sh`·바인딩 오류 grep(포트 없음)을 안내. 자동 테스트 2개 | [`27`](evidence/27-feedback-round2.txt) ④, `bin/monitor.sh` 307·320행 | ✅ |
| 6 | PASS | 로그 타임존 표기 | 형식(과제 지정)은 유지하고 헤더 주석·운영 매뉴얼에 "서버 로컬 시각(KST +0900)" 명시, UTC 변환 명령 실측 | [`27`](evidence/27-feedback-round2.txt) ②, [운영 §2](operations.md#2-monitorlog-포맷과-파싱-예시) | ✅ |
| 7 | PASS | cron 환경의 env 로드 성공 여부를 주기적으로 검증 | `check-cron.sh` **7단계** 추가 — 실행 계정으로 `env -i` 빈 환경에서 env 파일을 source 해 `AGENT_PORT` 등을 출력, 읽기 불가·문법 오류·값 불일치는 FAIL. root crontab 매시 점검 한 줄 제공. 자동 테스트 7개 | [`27`](evidence/27-feedback-round2.txt) ③, [운영 §5](operations.md#5-cron-장애-점검과-복구) | ✅ |
| 8 | PASS | logrotate 충돌 방지 지침 | (1차에서 반영) 동시 사용 금지 이유, 전환 시 내장 순환 끄기 → 설치 → 되돌리기, 둘 다 켜졌는지 점검 | [운영 §4](operations.md#4-로그-순환-방식-선택-지침-내장-순환-vs-logrotate), [`24`](evidence/24-logrotate.txt) | ✅ |
| 9 | PASS | ss vs netstat 플랫폼별 가용성 | `monitor.sh` 주석 + 운영 매뉴얼: ss 는 iproute2(기본 설치), netstat 은 net-tools(22.04 미설치) 실측 | [`27`](evidence/27-feedback-round2.txt) ⑧, [운영 §1](operations.md#1-운영-환경별-선택-기준-컨테이너--vm--물리-서버) | ✅ |
| 10 | PASS | CPU 샘플링 간격·계산 방식 | `CPU_SAMPLE_SEC` 줄에 간격·계산·정밀도 주석, 운영 매뉴얼에 공식과 간격별 실행 시간 실측(1초→1.29초, 3초→3.28초) | [`27`](evidence/27-feedback-round2.txt) ⑦, [운영 §2](operations.md#2-monitorlog-포맷과-파싱-예시) | ✅ |
| 11 | PASS | cron 계정으로 실제 실행 검증 로그 | agent-admin 으로 cron 과 같은 빈 환경(`env -i`)에서 monitor.sh 실행 → exit 0, 새 줄 기록 | [`27`](evidence/27-feedback-round2.txt) ③, [`20`](evidence/20-cron-check.txt) ③ | ✅ |
| 12 | PASS | logrotate 전환 설정 파일·비활성화 절차 | (1차에서 반영) `config/logrotate.d/agent-app` 줄 단위 해설, `install -m 0644` 설치, 내장 순환 끄기, 되돌리기 | [운영 §4](operations.md#4-로그-순환-방식-선택-지침-내장-순환-vs-logrotate), [`24`](evidence/24-logrotate.txt) | ✅ |
| 13 | PASS | 브루트포스 방어 적용 여부 | (1차에서 반영) fail2ban jail + 선택 설치 스크립트, 실제 차단·해제 | [`22`](evidence/22-fail2ban.txt), [운영 §9](operations.md#9-ssh-무차별-대입-대응) | ✅ |
| 14 | PASS | SELinux 환경 권한 영향 | 운영 매뉴얼에 DAC(소유·ACL) 다음 MAC 도 통과해야 함, Ubuntu 는 AppArmor·agent-app 은 unconfined 실측, SELinux 서버에서는 `ausearch -m avc`·`restorecon` | [`27`](evidence/27-feedback-round2.txt) ⑨, [운영 §6](operations.md#6-권한-점검--복구--감사) | ✅ |
| 15 | PASS | 경고·종료 분리의 운영상 이유 | 헤더 주석에 "서비스 불가 = 즉시 조치 / 동작 중 = 추세 관찰", 운영 매뉴얼에 오탐 재기동 예시 | `bin/monitor.sh` 9·12행, [운영 §8](operations.md#8-경고-알림-연동) | ✅ |
| 16 | PASS | 동시 실행 안전성(잠금) | 이미 있던 `flock` 잠금을 주석·운영 매뉴얼로 설명(`O_APPEND` + 순환 잠금), 동시 2회 실행·잠금 점유 시 exit 2 실측 | [`27`](evidence/27-feedback-round2.txt) ⑥, [운영 §3](operations.md#3-리다이렉션-실수-사례--와-) | ✅ |
| 17 | PASS | 웹서버 핵심 지표(latency) 예시 | 전환 가이드 임계값 표에 p95 응답시간(시작값 200ms), curl·`$request_time` 측정과 판정 명령을 nginx 에서 실측 | [`27`](evidence/27-feedback-round2.txt) ⑩, [전환 가이드 §5](webserver-migration.md#5-임계값-전환) | ✅ |
| 18 | PASS | 바인딩 실패 로그(stderr) 수집 절차 | 운영 매뉴얼 §7 에 6단계 수집 절차(앱 출력 파일 → 포트 주인 → 포그라운드 재실행 → journal → dmesg/avc → 보존), 포트 선점 상태에서 실측 | [`27`](evidence/27-feedback-round2.txt) ⑤, [운영 §7](operations.md#7-포트-미개방-진단-체크리스트) | ✅ |
| 19 | PASS | 급증 시 우선순위 체크리스트 | 운영 매뉴얼 §11 맨 앞에 "확인·보존 → 임시 확보 → 회전 → 원인 제거 → 모니터링 재개 → 기록" 체크리스트, 자동 삭제 범위(30일 지난 압축본만) 명시 | [운영 §11](operations.md#11-로그-급증-긴급-대응) | ✅ |

**2차 보완 중 실제로 찾은 문제**

| 발견 | 어디서 | 조치 |
| --- | --- | --- |
| env 파일을 실행 계정이 못 읽어도 monitor.sh 는 오류 없이 기본값으로 돈다 | cron 환경 실측(`27` ③) | `check-cron.sh` 7단계가 FAIL 로 잡고 복구 명령 제시 |
| 처음 만든 `[HINT]` 의 grep 패턴(`address already in use`)이 앱의 실제 메시지(`Port 15034 is already in use.`)와 안 맞음 | 바인딩 실패 실측(`27` ⑤) | 패턴을 `already in use\|permission denied\|bind\|fail` 로 |
| 문법이 깨진 env 파일을 source 하면 check-cron.sh 자체가 깨짐 | 7단계 자동 테스트 | source 전에 `bash -n` 으로 문법 확인, 깨진 파일은 7단계에서 FAIL 로 보고 |
| `PasswordAuthentication yes` 가 켜져 있음(계정이 잠겨 있어 당장은 비밀번호 로그인 불가) | 계정 정책 실측(`27` ①) | 키 접속 확인 후 끄도록 운영 지침에 명시(먼저 끄면 원격 접속이 끊길 수 있어 자동 변경은 하지 않음) |

## 검증

```bash
bash tests/run-tests.sh      # 117개 = 기존 71 + diagnose-port 13 + check-cron 10 + 알림 훅 9 + 새 스크립트 4개 문법 검사
                             #        + 2차: check-cron 7단계 7 · cron.log [HINT] 1 · monitor [HINT] 2 (root 로 실행하면 '읽기 불가' 1개는 건너뜀)
```

새 스크립트 4개(`diagnose-port.sh`, `check-cron.sh`, `alert.sh`, `08-fail2ban.sh`) 포함 모든 스크립트가 ShellCheck 경고 0 입니다.
