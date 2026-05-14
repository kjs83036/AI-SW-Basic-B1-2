[Bug] OOM Crash - 메모리 누수로 인한 MemoryGuard 강제 종료

## 1. Description (현상 설명)

`agent-app` 실행 후 약 9초 경과 시 터미널에서 프로세스가 예고 없이 종료된다.
애플리케이션 내부의 메모리 보호 정책(MemoryGuard)이 `MEMORY_LIMIT`에 도달하자
즉시 `SIGKILL`로 프로세스를 강제 종료하는 현상이 반복된다.

- **발생 환경**: Ubuntu 24.04 LTS (Docker), agent-admin 계정, `MEMORY_LIMIT=100`
- **발생 조건**: 앱 시작 후 MemoryWorker가 25MB씩 메모리를 할당하다 상한 도달 시
- **반복 여부**: 동일 환경 변수로 재실행할 때마다 100% 재현

---

## 2. Evidence & Logs (증거 자료)

### monitor.sh 관제 로그 (MEM% 추이)

```
[2026-05-14 15:38:33] PID:32  CPU:0.2%   MEM:5.1%  DISK_USED:3%   ← 시작 직후 정상
[2026-05-14 15:38:37] PID:32  CPU:100.0% MEM:5.3%  DISK_USED:3%   ← MemoryWorker 활성
[2026-05-14 15:38:40] PID:32  CPU:0.4%   MEM:5.6%  DISK_USED:3%   ← 메모리 상승 관측
[monitor run 4] Checking process 'agent-app'... [FAIL] (process not running)  ← 종료 확인
```

> MEM% 수치는 Docker 호스트 전체 메모리(16GB) 대비 비율이므로 절대값이 낮으나,
> 앱 내부 Heap 사용량은 아래 프로그램 로그에서 선형 증가 패턴 확인.

### 프로그램 실행 로그 (종료 직전/직후)

```
2026-05-14 15:38:34 [INFO]     [MemoryWorker] Current Heap: 25MB
2026-05-14 15:38:37 [INFO]     [MemoryWorker] Current Heap: 50MB
2026-05-14 15:38:40 [INFO]     [MemoryWorker] Current Heap: 75MB
2026-05-14 15:38:43 [INFO]     [MemoryWorker] Current Heap: 100MB
2026-05-14 15:38:43 [CRITICAL] [MemoryGuard]  Memory limit exceeded (100MB >= 100MB) / (Recommend Over 256MB)
2026-05-14 15:38:43 [CRITICAL] [MemoryGuard]  Self-terminating process 34 to prevent system instability.
```

### 시스템 도구 출력

```bash
# 종료 직후 ps 결과
$ ps aux | grep agent-app
(출력 없음 — PID 34 사라짐)

# 포트 확인
$ ss -tln 'sport = :15034'
(출력 없음 — 포트 비활성)
```

---

## 3. Root Cause Analysis (원인 분석)

**현상 분석**: 애플리케이션 로직 내부에서 MemoryWorker가 Heap 메모리를 3초마다
25MB씩 지속적으로 할당하되 해제하지 않아 메모리 누수(Memory Leak)가 발생한다.

**OS 동작 원리**: 리눅스에서 프로세스는 `malloc()`/`mmap()` 등으로 힙을 확장하지만
`free()`로 반환하지 않으면 RSS(Resident Set Size)가 단조 증가한다. 이 앱은 누수를
방치하는 대신 내부 MemoryGuard 정책이 `MEMORY_LIMIT`을 상한으로 설정하고,
도달 즉시 `SIGKILL`로 자기 종료(Self-termination)하여 시스템 전체 불안정을 방지한다.

**수집된 증거 기반 결론**:
- Heap 25 → 50 → 75 → 100MB (3초 간격 선형 상승) — 해제 없는 연속 할당 패턴
- `MEMORY_LIMIT=100MB` 도달 순간 즉각 SIGKILL — MemoryGuard 트리거 확인
- CPU 사용률은 안정적(0.2~0.4%) — 메모리 누수 외 다른 원인 없음

---

## 4. Workaround & Verification (조치 및 검증)

### 조치 내용

`.bash_profile` 또는 `/etc/profile.d/agent-env.sh` 내 `MEMORY_LIMIT` 값을
기존 `100MB`에서 `512MB`로 상향 조정하여 임시로 가용 메모리를 확보했다.

```bash
# Before
export MEMORY_LIMIT=100

# After
export MEMORY_LIMIT=512
```

### Before & After 비교

| 항목 | Before (MEMORY_LIMIT=100) | After (MEMORY_LIMIT=512) |
|------|--------------------------|--------------------------|
| 종료 원인 | MemoryGuard (메모리 한계 초과) | MemoryGuard 미발생 |
| 생존 시간 | **약 9초** | 30초+ (다른 제한에 도달할 때까지) |
| 종료 로그 | `Memory limit exceeded (100MB >= 100MB)` | 해당 없음 |
| 프로세스 상태 | 즉시 종료 | 지속 실행 확인 |

### 검증 결과

`MEMORY_LIMIT=512` 설정 후 재실행 시 100MB를 넘어서도 MemoryGuard가 트리거되지 않았으며
`Current Heap: 125MB → 150MB → ... → 500MB+` 로 계속 동작함을 확인.

### 근본적 해결을 위한 추가 제안 (선택)

임시 조치(MEMORY_LIMIT 상향)는 종료 시점을 미룰 뿐 누수 자체를 해결하지 않는다.
소스 코드 내 MemoryWorker의 Heap 할당 로직에서 `del` 또는 `pop`으로 불필요한
데이터를 주기적으로 삭제하는 리팩토링이 필요하다.
