[Bug] Deadlock - 멀티스레드 환경에서 교착상태 발생으로 프로세스 무응답

## 1. Description (현상 설명)

`MULTI_THREAD_ENABLE=true`로 `agent-app`을 실행하면 약 7초 후 프로세스가
종료되지 않고 PID가 유지되나, CPU/메모리 변화가 전혀 없고 로그 출력도 완전히
멈추는 **무응답(Deadlock)** 상태가 지속된다.

- **발생 환경**: Ubuntu 24.04 LTS (Docker), `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=20`, `MULTI_THREAD_ENABLE=true`
- **발생 조건**: Worker-Thread-1과 Worker-Thread-2가 서로의 자원을 상호 대기
- **반복 여부**: `MULTI_THREAD_ENABLE=true` 설정 시 100% 재현

---

## 2. Evidence & Logs (증거 자료)

### PID 존재 확인 (ps -ef)

```bash
$ ps -ef | grep agent-app
agent-a+  761    1  0 15:53 ?  00:00:00 ./agent-app   ← PID 존재
agent-a+  763  761  0 15:53 ?  00:00:00 ./agent-app   ← 자식 스레드 프로세스
```

### CPU/MEM 변화 정체 확인 (top -H)

```
top - 15:55:40 up 1:15, 0 user, load average: 0.01, 0.01, 0.00
Threads: 1 total, 0 running, 1 sleeping, 0 stopped, 0 zombie

  PID  USER     PR NI  VIRT   RES  SHR S  %CPU  %MEM  TIME+    COMMAND
  761  agent-a+ 20  0  2896  2064 1844 S   0.0   0.0  0:00.08  agent-app
```

> **S (Sleeping)** 상태 — 실행 중이 아님.  
> `%CPU = 0.0`, `TIME+ = 0:00.08` — 30초 후에도 CPU 시간 증가 없음.

### ps -L (스레드 상태)

```bash
$ ps -L -p 761 -o pid,lwp,stat,time,comm
  PID   LWP STAT     TIME COMMAND
  761   761 S    00:00:00 agent-app    ← Sleep(대기) 상태
```

### monitor.sh 관제 로그 (30초 후에도 PID 유지 확인)

```
[monitor run 1] Checking process 'agent-app'... [OK] (PID: 761) ← 교착 직후
[monitor run 2] Checking process 'agent-app'... [OK] (PID: 761) ← 15초 후
CPU Usage: 100.0% (시스템 전체) / 앱 자체 CPU: 0.0%           ← 앱만 정체
```

### 프로그램 실행 로그 마지막 지점 (WAITING/BLOCKED)

```
2026-05-14 15:53:41 [INFO]    Agent READY
2026-05-14 15:53:43 [WARNING] [AgentWorker] Initializing concurrent transaction processors...
2026-05-14 15:53:43 [WARNING] [System] CAUTION: Strict resource locking is enabled.

2026-05-14 15:53:48 [INFO] [Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)
2026-05-14 15:53:48 [INFO] [Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)

2026-05-14 15:53:50 [INFO] [Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)
2026-05-14 15:53:50 [INFO] [Worker-Thread-1] WAITING for [Socket_Pool_B]...  (Status: BLOCKED)
```

> `15:53:50` 이후 **로그 출력 없음** (총 42줄에서 멈춤).  
> 30초 후에도 동일 상태 — 교착상태 지속 확인.

---

## 3. Root Cause Analysis (원인 분석)

**현상 분석**: 두 스레드가 서로 상대방이 보유한 자원을 무한히 기다리는
**순환 대기(Circular Wait)** 상태에 빠진다.

```
Worker-Thread-1: Shared_Memory_A 보유 → Socket_Pool_B 대기
Worker-Thread-2: Socket_Pool_B 보유 → Shared_Memory_A 대기
```

**교착상태 4대 조건 (모두 충족)**:

| 조건 | 충족 여부 | 근거 |
|------|----------|------|
| 상호 배제(Mutual Exclusion) | ✅ | `LOCK ACQUIRED` — 한 스레드만 락 보유 |
| 점유 대기(Hold and Wait) | ✅ | 락 보유한 채 다른 락 대기 중 |
| 비선점(No Preemption) | ✅ | 외부에서 강제로 락 해제 안 됨 |
| 순환 대기(Circular Wait) | ✅ | Thread-1 → B 대기, Thread-2 → A 대기 |

**OS 동작 원리**: 리눅스에서 `pthread_mutex_lock()` 등으로 획득한 락은
상대방이 해제하기 전까지 대기(BLOCKED) 상태가 지속된다. 이 앱은 데드락 감지
(Deadlock Detection) 또는 타임아웃 메커니즘 없이 무한 대기에 빠진다.

---

## 4. Workaround & Verification (조치 및 검증)

### 조치 내용

`MULTI_THREAD_ENABLE`을 `true`에서 `false`로 변경하여 멀티스레드 동시 실행을
비활성화했다.

```bash
# Before
export MULTI_THREAD_ENABLE=true

# After
export MULTI_THREAD_ENABLE=false
```

### Before & After 비교

| 항목 | Before (MULTI_THREAD_ENABLE=true) | After (MULTI_THREAD_ENABLE=false) |
|------|-----------------------------------|----------------------------------|
| 시나리오 | 멀티스레드 동시 트랜잭션 | 단일 스레드 순차 실행 |
| 부트 경고 | `POTENTIAL DEADLOCK IN CONCURRENT MODE` | `[OK]` |
| 프로세스 상태 | Sleeping (S), CPU 0%, 무응답 | Running, 로그 지속 출력 |
| 로그 멈춤 | `15:53:50` 이후 신규 로그 없음 | 지속적 로그 출력 |
| 생존/응답 | 교착 지속 (30초+ 무응답) | 30초+ 정상 실행 |

### 검증 결과

`MULTI_THREAD_ENABLE=false` 설정 후:
```
>>> Scenario Selected: [Healthy System Monitoring]
[Scheduler] Registered Tasks: ['Thread-A', 'Thread-B', 'Thread-C']
[Thread-A] Task Started. Calculating... (20%)
[Thread-A] Calculating... (40%)
[Thread-A] Preempted. Progress saved at (40%)
[Thread-B] Task Started. Calculating... (20%)
...
[Scheduler] All tasks completed.
```
스케줄러가 Thread-A/B/C를 순차적으로 교체(Round-Robin 방식)하며 정상 실행됨을 확인.
30초 후에도 PID 유지 + 로그 지속 출력.

### 근본적 해결을 위한 추가 제안 (선택)

`MULTI_THREAD_ENABLE=false`는 동시성을 포기하는 임시 조치다.
멀티스레드를 유지하면서 데드락을 방지하려면:
1. **락 순서 고정**: 모든 스레드가 동일한 순서로 자원 획득 (`A 먼저, B 나중`)
2. **타임아웃 락**: `pthread_mutex_timedlock()` 등으로 대기 시간 제한 후 재시도
3. **단일 뮤텍스 통합**: `Shared_Memory_A`와 `Socket_Pool_B`를 하나의 락으로 관리
