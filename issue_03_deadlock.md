# [Bug] agent-app-leak 멀티스레드 교착상태(Deadlock)로 작업 정지

> 장애 분석 리포트 — Deadlock Case (PDF §4.4, §8)
> 아래 로그는 컨테이너 실측 채집본. 재검증: `verify2.sh deadlock` / `MANUAL_VERIFICATION.md` §3

## 1. Description (현상 설명)

`MULTI_THREAD_ENABLE=true` 로 앱을 실행하면 `Worker-Thread-1` 과 `Worker-Thread-2` 가
서로가 점유한 락을 기다리는 교착이 발생한다. 프로세스(PID)는 계속 살아있으나
작업이 더 이상 진행되지 않고 두 스레드가 `Status: BLOCKED` 에서 멈춘다.
메모리·CPU 케이스와 달리 **자가 종료가 일어나지 않아** 외형상 "정상"으로 보이는 점이 위험.

## 2. Evidence & Logs (증거 자료 — 실측)

### 2-1. 부팅 시 환경 경고
```
 [ THREAD ] Concurrency: True 		[ WARNING ]
 >>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.
```

### 2-2. Application Log — 상호 락 점유 후 순환 대기
```
[Worker-Thread-1] Process Started. Attempting to lock [Shared_Memory_A]...
[Worker-Thread-2] Process Started. Attempting to lock [Socket_Pool_B]...
[Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
[Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)
[Worker-Thread-1] Need resource [Socket_Pool_B] to finish job.
[Worker-Thread-2] Need resource [Shared_Memory_A] to write logs.
[Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)
[Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
```
이후 진행(Progress) 로그가 더 이상 출력되지 않음.

### 2-3. 프로세스 상태
```
컨테이너 상태: Up (계속 생존)   # 종료 코드 없음 - 죽지 않고 멈춤
```

### 2-4. PID 존재 증거 — `ps -ef | grep agent-app-leak` (실측)
```
UID        PID  PPID C STIME TTY          TIME CMD
root         7     1 0 04:48 ?        00:00:00 su agent-admin -c ... ./agent-app-leak
agent-adm    9     7 0 04:48 ?        00:00:00 ./agent-app-leak
agent-adm   10     9 0 04:48 ?        00:00:00 ./agent-app-leak
```
BLOCKED 로그 출력 이후에도 PID 9·10 이 계속 존재 → 프로세스 생존·작업 정지 확인.

### 2-5. 스레드별 CPU/MEM — `ps -L` + `top -H` (실측)
```
# ps -L -p 10 -o pid,lwp,stat,%cpu,%mem,comm
  PID   LWP STAT %CPU %MEM COMMAND
   10    10 SNl   0.2  0.1 agent-app-leak   ← 메인 스레드
   10    11 SNl   0.0  0.1 agent-app-leak   ← Worker-Thread-1 (BLOCKED)
   10    12 SNl   0.0  0.1 agent-app-leak   ← Worker-Thread-2 (BLOCKED)

# top -bH -n1 (스레드 모드)
  PID USER      PR  NI    VIRT    RES    SHR S  %CPU  %MEM     TIME+ COMMAND
    9 agent-a+  20   0    2896   2040   1820 S   0.0   0.0   0:00.07 agent-a+
   10 agent-a+  30  10  174584  21132  11520 S   0.0   0.1   0:00.04 agent-a+
   11 agent-a+  30  10  174584  21132  11520 S   0.0   0.1   0:00.00 agent-a+
   12 agent-a+  30  10  174584  21132  11520 S   0.0   0.1   0:00.00 agent-a+
```
LWP 11·12 (Worker 스레드) 모두 `STAT=S, %CPU=0.0` → 락 대기 상태로 진행 없음.

## 3. Root Cause Analysis (원인 분석)

- `Worker-Thread-1` 은 `Shared_Memory_A` 를, `Worker-Thread-2` 는 `Socket_Pool_B` 를 점유한
  채 서로 상대의 락을 요구 → **순환 대기(circular wait)** 성립.
- 교착 4대 조건(상호배제·점유와 대기·비선점·순환대기)이 모두 충족된 전형적 데드락.
- 프로세스는 살아있으나 작업 스레드 전부 BLOCKED → CPU/MEM 변동 없이 진행 정지.
- 헬스체크(PID/포트)만으로는 [OK] 로 보여 탐지 불가 → **자원 사용량 정지**가 핵심 식별 신호.
- PDF §6 제약(리버싱 금지) → 앱 로그·`ps -L` 외부 관찰로 규명.

## 4. Workaround & Verification (조치 및 검증)

### 우회 조치
- 단기: `MULTI_THREAD_ENABLE=false` 로 단일 스레드 실행 → 순환 대기 경로 자체가 사라짐.
- 운영: `monitor.sh` 가 PID 만으로 [OK] 를 내므로, CPU/MEM 장기 정지를 별도 경보로 보강 권장.

### Before / After (실측)

| 구분 | MULTI_THREAD_ENABLE | 결과 |
|------|---------------------|------|
| Before | true  | 스레드 순환 대기 → `Status: BLOCKED` → 작업 정지, 프로세스는 생존 |
| After  | false | 단일 스레드 처리, 교착 없이 작업 정상 완료 |

### 검증 방법
```bash
verify2.sh deadlock   # 자동: 프로세스 생존 + BLOCKED/WAITING 신호 → PASS
# 수동: MANUAL_VERIFICATION.md §3 (진행 정지 + 신호 로그 + false 해소 확인)
```
실측 자동 검증 결과: **PASS** (`POTENTIAL DEADLOCK` + `Status: BLOCKED` 포착, 프로세스 생존).
