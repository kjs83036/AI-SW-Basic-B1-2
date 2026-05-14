[Bug] CPU Spike - CpuWorker 과점유로 인한 보호 정책 강제 종료

## 1. Description (현상 설명)

`agent-app`을 `CPU_MAX_OCCUPY=80` 이상으로 실행하면 일정 시간 경과 후
CpuWorker가 CPU 부하를 점진적으로 높이다 내부 안전 임계치(약 50%)를 초과하는
순간 `[CRITICAL] CPU Threshold Violated!` 메시지와 함께 프로세스가 종료된다.

- **발생 환경**: Ubuntu 24.04 LTS (Docker), `MEMORY_LIMIT=512`, `CPU_MAX_OCCUPY=80`
- **발생 조건**: CpuWorker가 CPU 부하를 점진적으로 증가시키다 ~50% 도달 시
- **반복 여부**: `CPU_MAX_OCCUPY >= 80` 설정 시 100% 재현 (~30초 내)

---

## 2. Evidence & Logs (증거 자료)

### monitor.sh 관제 로그 (CPU% 급상승 구간)

```
[2026-05-14 15:47:41] PID:457 CPU:100.0% MEM:5.2% DISK_USED:3%   ← CPU 급상승 [WARNING]
[2026-05-14 15:47:46] PID:457 CPU:0.2%   MEM:5.2% DISK_USED:3%
[2026-05-14 15:47:50] PID:457 CPU:100.0% MEM:5.2% DISK_USED:3%   ← CPU spike 반복
[2026-05-14 15:47:55] PID:457 CPU:0.2%   MEM:5.2% DISK_USED:3%
[2026-05-14 15:47:59] PID:457 CPU:100.0% MEM:5.2% DISK_USED:3%   ← 지속적 spike
[2026-05-14 15:48:04] PID:457 CPU:0.8%   MEM:5.2% DISK_USED:3%
[2026-05-14 15:48:09] PID:457 CPU:0.2%   MEM:5.2% DISK_USED:3%
monitor run 9: Checking process 'agent-app'... [FAIL] (process not running) ← 종료
```

### 프로그램 실행 로그 (CPU 점진 상승 → 임계 초과)

```
2026-05-14 15:47:42 [INFO]     [CpuWorker] Started. Maximum CPU Limit: 80%
2026-05-14 15:47:42 [INFO]     [CpuWorker] Current Load: 5.00%
2026-05-14 15:47:45 [INFO]     [CpuWorker] Current Load: 6.22%
2026-05-14 15:47:48 [INFO]     [CpuWorker] Current Load: 15.55%
2026-05-14 15:47:51 [INFO]     [CpuWorker] Current Load: 20.70%
2026-05-14 15:47:54 [INFO]     [CpuWorker] Current Load: 26.46%
2026-05-14 15:47:57 [INFO]     [CpuWorker] Current Load: 31.04%
2026-05-14 15:48:01 [INFO]     [CpuWorker] Current Load: 35.13%
2026-05-14 15:48:07 [INFO]     [CpuWorker] Current Load: 40.32%
2026-05-14 15:48:10 [INFO]     [CpuWorker] Current Load: 46.54%
2026-05-14 15:48:13 [INFO]     [CpuWorker] Current Load: 50.52%
2026-05-14 15:48:13 [CRITICAL] [CpuWorker] CPU Threshold Violated! (50.52%).
```

### 시스템 도구 출력 (top/ps)

```bash
# 실행 중 CPU 급상승 확인
$ top -bn1 | grep agent
457 agent-a+  30  10  50.2  0.0  0.0 R  99.7  0.0  ...  agent-app

# 종료 직후
$ ps aux | grep agent-app
(출력 없음)
```

### 부트 시퀀스의 경고 메시지

```
[6/6] Verifying Mission Environment  [OK]
   ... MEMORY_LIMIT=512MB, CPU_MAX_OCCUPY=80%, MULTI_THREAD_ENABLE=False
[ CPU ] Limit: 80%   [ WARNING: Recommend Under 50% ]
```

> 부트 단계에서 이미 `CPU_MAX_OCCUPY=80`이 권장 범위(50% 미만)를 초과한다고 경고.

---

## 3. Root Cause Analysis (원인 분석)

**현상 분석**: CpuWorker는 `CPU_MAX_OCCUPY`를 목표 상한으로 설정하고 CPU 부하를
점진적으로 증가시킨다. 앱 내부 안전 정책의 실제 임계치는 **50%** 로 하드코딩되어 있어,
`CPU_MAX_OCCUPY`가 50%를 초과하면 CpuWorker가 목표에 도달하기 전에 안전 정책이 먼저
트리거되어 프로세스를 강제 종료한다.

**OS 동작 원리**: 특정 프로세스가 CPU를 독점하면 다른 프로세스들의 스케줄링 지연이
발생하고 시스템 응답성이 저하된다. 이 앱의 Watchdog(CpuWorker 안전 정책)은 CPU 과점유
방지를 위해 임계치 초과 시 자기 종료를 선택한다.

**수집된 증거 기반 결론**:
- CpuWorker Load: 5 → 6 → 15 → 20 → 26 → 31 → 35 → 40 → 46 → **50.52%** (단조 증가)
- 50% 초과 직후 `CPU Threshold Violated!` → 즉시 종료
- `CPU_MAX_OCCUPY=80` 설정 시 부트 단계에서 이미 `WARNING: Recommend Under 50%` 경고 발생

---

## 4. Workaround & Verification (조치 및 검증)

### 조치 내용

`CPU_MAX_OCCUPY` 값을 `80`에서 `20`으로 하향 조정하여
CpuWorker가 안전 임계치(50%)에 도달하지 않도록 설정했다.

```bash
# Before
export CPU_MAX_OCCUPY=80

# After
export CPU_MAX_OCCUPY=20
```

### Before & After 비교

| 항목 | Before (CPU_MAX_OCCUPY=80) | After (CPU_MAX_OCCUPY=20) |
|------|---------------------------|--------------------------|
| CpuWorker 목표 | 80% (임계치 초과) | 20% (임계치 이하) |
| 실제 CPU 도달값 | 50.52% → 임계 초과 | 20.00% → 피크 후 쿨다운 |
| 종료 여부 | **종료** (약 31초 후) | **지속 실행** (30초+ 확인) |
| 종료 메시지 | `CPU Threshold Violated! (50.52%)` | 없음 |
| 부트 경고 | `WARNING: Recommend Under 50%` | `OK` |

### 검증 결과

`CPU_MAX_OCCUPY=20` 설정 후:
```
[CpuWorker] Peak reached (20.00%). Starting cooldown...
[CpuWorker] Current Load: 20.00%
... (쿨다운 후 재개, 반복)
```
CpuWorker가 20% 피크 도달 시 자동으로 쿨다운에 진입하고, 이후에도 프로세스가
정상적으로 계속 실행됨을 확인 (30초 후에도 PID 유지).

### 근본적 해결을 위한 추가 제안 (선택)

`CPU_MAX_OCCUPY` 하향은 CPU 부하를 줄이지만 작업 처리 성능도 저하된다.
근본 해결을 위해서는 CpuWorker의 CPU 집약적 작업(busy-loop 등)을 비동기
I/O 또는 sleep 기반 폴링으로 리팩토링하거나, 안전 임계치를 `CPU_MAX_OCCUPY`에
연동하도록 수정하는 것이 필요하다.
