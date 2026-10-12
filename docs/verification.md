# 검증 기록 — 제공 바이너리로 실제 실행

스크립트를 제출하기 전에 **제공 바이너리 `agent-app-linux-x86`** 을 격리된 Ubuntu 환경에서 실제로 실행해, Boot Sequence 통과 → monitor.sh → monitor.log 누적 → report.sh → Health Check 실패까지 확인한 기록입니다.

> 이 기록은 **스크립트 검증용**입니다. 과제의 공식 증빙(SSH·방화벽·cron 포함)은 실제 서버(VM)에서 `sudo bash verify/collect-evidence.sh` 로 만든 `docs/evidence/` 입니다.
> 검증 환경은 컨테이너라 sshd·UFW·cron 데몬이 없습니다. 그래서 방화벽은 `unknown` 경고가 나오고, cron 대신 60초 간격 반복 실행으로 누적을 확인했습니다.

| 항목 | 값 |
| --- | --- |
| 환경 | Ubuntu 24.04 (격리 컨테이너, root 로 setup 실행 후 agent-admin 으로 앱·스크립트 실행) |
| 바이너리 | `agent-app-linux-x86` (ELF 64-bit, sha256 `cdbae8c0…de0ff5a`) |
| 사용 스크립트 | `setup/03·04·05·06` → `bin/run-agent.sh` → `bin/monitor.sh`, `bin/report.sh` |
| 추가 검증 | `tests/run-tests.sh` 68개 통과 (Ubuntu 22.04 VM: `ss` 경로 / Ubuntu 24.04: `/proc/net/tcp` 경로) |

## 1. Boot Sequence — 명세대로 설정했을 때 실패 → 원인 확인 → 통과

**① 과제 문서의 값 `AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys/t_secret.key`**

```
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
   ... Running as service user 'agent-admin' (uid=30033)
[2/5] Verifying Environment Variables     [FAIL]
   >>> Key Path Mismatch. Expected: /home/agent-admin/agent-app/api_keys
[3/5] Checking Required Files             [FAIL]
   >>> Skipped due to previous critical failure.
[4/5] Checking Port Availability          [FAIL]
   >>> Skipped due to previous critical failure.
[5/5] Verifying Log Permission            [FAIL]
   >>> Skipped due to previous critical failure.
--------------------------------------------------
System Boot Failed. Process Terminated.
```

**② `AGENT_KEY_PATH=/home/agent-admin/agent-app/api_keys` 로 수정**

```
[2/5] Verifying Environment Variables     [OK]
   ... All required Envs correct
[3/5] Checking Required Files             [FAIL]
   >>> Missing File: secret.key
   >>>    (Expected location: /home/agent-admin/agent-app/api_keys/secret.key)
```

**③ `secret.key → t_secret.key` 심볼릭 링크 추가** (명세의 파일을 원본으로 유지)

```
>>> Starting Agent Boot Sequence...
[1/5] Checking User Account               [OK]
   ... Running as service user 'agent-admin' (uid=30033)
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
2026-10-12 17:58:48,580 [INFO] [SafetyGuard] Process priority lowered (nice=10).
2026-10-12 17:58:48,580 [INFO] Agent listening at port 15034
2026-10-12 17:58:48,580 [INFO] === Agent Worker Started ===
2026-10-12 17:58:48,581 [INFO]    > Cycle: 0 -> 256MB/Lv10 -> 0
2026-10-12 17:58:48,581 [INFO] --- Step Info: Mode=UP, CPU Lv=1, Mem=0MB ---
2026-10-12 17:58:48,596 [INFO] [Memory] Increasing... (+25 MB) Total: 25 MB
2026-10-12 17:58:48,596 [INFO] [CPU] Occupy core for 1s (Level 1)
```

이 두 가지는 `setup/04-directories.sh`(링크), `setup/05-environment.sh`(디렉토리 경로)에 반영했습니다.

## 2. 프로세스 구조 — PyInstaller 부모/자식

```console
$ ps -eo user,pid,ppid,nlwp,comm,args | grep [a]gent-app
agent-a+ 15489     1    1 agent-app-linux /home/agent-admin/agent-app/agent-app-linux-x86
agent-a+ 15491 15489    1 agent-app-linux /home/agent-admin/agent-app/agent-app-linux-x86
```

처음 버전의 monitor.sh 는 첫 번째 PID(15489, 부트로더)를 골라 **RSS 2.2MB** 를 기록했습니다. 실제 앱은 자식(15491)이라, 포트를 가진 프로세스를 찾고 그것도 모르면 자식을 고르도록 고쳤습니다. 수정 후에는 RSS 가 **189.4MB** 로 앱의 실제 메모리를 반영합니다(30초 뒤 측정).

| | 수정 전 | 수정 후 |
| --- | --- | --- |
| 선택된 PID | 15489 (부모) | **15491 (포트 주인)** |
| Process 줄 | `CPU 1.4% MEM 0.0% RSS 2.2MB` | `CPU 19.6% MEM 2.3% RSS 189.4MB` |

## 3. monitor.sh 실행 결과 (agent-admin)

```
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app'... [OK] (PID: 15491)
Checking port 15034... [OK]
Checking firewall... [WARN] (unknown)

[RESOURCE MONITORING]
CPU Usage : 13.4%
MEM Usage : 7.7%
DISK Used : 32%
Process   : PID 15491 CPU 19.1% MEM 1.1% RSS 89.4MB Threads 1

[WARNING] Firewall status unknown: UFW/firewalld 를 찾지 못했습니다

====== STATISTICS REPORT ======
Period  : 2026-10-12 17:59:47 ~ 2026-10-12 18:02:31
[CPU]
  Average : 17.1%
  Maximum : 32.3% at 2026-10-12 17:59:47
  Minimum : 8.0% at 2026-10-12 18:01:50
[Memory]
  Average : 8.7%
  Maximum : 10.1% at 2026-10-12 17:59:47
  Minimum : 7.5% at 2026-10-12 18:00:49
[Disk]
  Average : 32.0%
  Maximum : 32.0% at 2026-10-12 17:59:47
  Minimum : 32.0% at 2026-10-12 17:59:47
[Samples]
  Data Points: 4 samples

[INFO] Log appended: /var/log/agent-app/monitor.log
(exit code: 0)
```

방화벽 경고는 검증 환경에 UFW 가 없어서 나온 것으로, **경고가 있어도 종료 코드는 0** 이고 기록은 계속된다는 요구사항이 그대로 확인됩니다.

## 4. monitor.log 누적 (60초 간격 반복 실행)

```
[2026-10-12 17:59:47] PID:15491 CPU:32.3% MEM:10.1% DISK_USED:32%
[2026-10-12 18:00:49] PID:15491 CPU:14.9% MEM:7.5% DISK_USED:32%
[2026-10-12 18:01:50] PID:15491 CPU:8.0% MEM:9.3% DISK_USED:32%
[2026-10-12 18:02:31] PID:15491 CPU:13.4% MEM:7.7% DISK_USED:32%    ← 수동 실행
[2026-10-12 18:02:51] PID:15491 CPU:8.0% MEM:8.7% DISK_USED:32%
[2026-10-12 18:03:52] PID:15491 CPU:12.7% MEM:8.1% DISK_USED:32%
[2026-10-12 18:04:53] PID:15491 CPU:12.1% MEM:9.6% DISK_USED:32%
```

같은 시간 `cron.log` 에는 경고만 남았습니다(정상 수치는 monitor.log, 경고·오류는 cron.log):

```
[WARNING] CPU threshold exceeded (32.3% > 20%)
[WARNING] MEM threshold exceeded (10.1% > 10%)
```

앱이 메모리 0 → 256MB → 0, CPU Level 1 → 10 을 오르내리기 때문에 CPU 가 8~32% 사이에서 움직이는 것이 보입니다.

## 5. report.sh 구간 분석 (보너스 1)

```console
$ report.sh --file /var/log/agent-app/monitor.log --from "2026-10-12 18:00:00" --to "2026-10-12 18:05:00"
====== STATISTICS REPORT ======
Range   : 2026-10-12 18:00:00 ~ 2026-10-12 18:05:00
Period  : 2026-10-12 18:00:49 ~ 2026-10-12 18:04:53
[CPU]
  Average : 11.5%
  Maximum : 14.9% at 2026-10-12 18:00:49
  Minimum : 8.0% at 2026-10-12 18:01:50
[Memory]
  Average : 8.5%
  Maximum : 9.6% at 2026-10-12 18:04:53
  Minimum : 7.5% at 2026-10-12 18:00:49
[Disk]
  Average : 32.0%
  Maximum : 32.0% at 2026-10-12 18:00:49
  Minimum : 32.0% at 2026-10-12 18:00:49
[Samples]
  Data Points: 6 samples
```

## 6. Health Check 실패 — 앱 종료 후

```console
$ run-agent.sh --stop
[INFO] 종료 신호를 보냈습니다 (PID 15489)
$ monitor.sh --no-stats; echo "(exit code: $?)"
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app'... [FAIL]
[ERROR] 앱 프로세스가 실행 중이 아닙니다 (패턴: ^agent[_-]app([._-].*)?$)
(exit code: 1)
```

실패한 실행은 monitor.log 에 줄을 추가하지 않습니다(통계가 오염되지 않도록). 원인은 stderr → cron 환경에서는 `cron.log` 에 남습니다.

## 7. 권한

| 확인 | 결과 |
| --- | --- |
| `agent-test` 로 `cat api_keys/t_secret.key` | `Permission denied` |
| `agent-test` 로 `monitor.sh` 실행 | `Permission denied` |
| `ls -l bin/` | `-rwxr-x--- agent-dev agent-core monitor.sh` |

검증 환경에는 ACL 도구가 없어 `setfacl` 단계는 실행하지 못했습니다. ACL 을 포함한 계정별 접근 매트릭스는 실제 서버에서 `verify/collect-evidence.sh` 의 `04-permissions.txt` 로 확인합니다.
