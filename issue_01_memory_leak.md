# [Bug] agent-app-leak 메모리 누수로 인한 MemoryGuard 자가종료

> 장애 분석 리포트 — Memory Leak / OOM Case (PDF §4.2, §8)
> 아래 로그는 컨테이너 실측 채집본. 재검증: `verify2.sh memory` / `MANUAL_VERIFICATION.md` §1

## 1. Description (현상 설명)

`agent-app-leak` 실행 후 `MemoryWorker` 가 약 3초마다 힙(Heap)을 25MB 씩
계속 늘리며 메모리를 해제하지 않는다. 누적 힙이 환경변수 `MEMORY_LIMIT`(MB) 한도를
넘으면 앱 내부 `MemoryGuard` 가 시스템 보호를 위해 **자기 프로세스를 강제 종료**한다.
재현 조건: `MEMORY_LIMIT=256` (권장값 256 이상 미만이면 부팅 시 WARNING).

## 2. Evidence & Logs (증거 자료 — 실측)

### 2-1. 부팅 시 환경 경고
```
 [ MEMORY ] Limit: 256MB 		[ WARNING: Recommend Over 256MB ]
```

### 2-2. Application Log — 힙 단조 증가 후 한도 초과 자가종료
```
2026-05-21 17:59:49,556 [INFO] [MemoryWorker] Current Heap: 25MB
2026-05-21 17:59:52,573 [INFO] [MemoryWorker] Current Heap: 50MB
   ... (3초 간격 25MB 씩 증가) ...
2026-05-21 18:00:17,808 [INFO] [MemoryWorker] Current Heap: 250MB
2026-05-21 18:00:20,827 [INFO] [MemoryWorker] Current Heap: 275MB
2026-05-21 18:00:20,827 [CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB) / (Recommend Over 256MB)
2026-05-21 18:00:20,827 [CRITICAL] [MemoryGuard] Self-terminating process 49 to prevent system instability.
Killed
```

### 2-3. 프로세스 종료 코드
```
컨테이너 상태: Exited (137)   # 137 = 128 + 9(SIGKILL), 자가 KILL
```

### 2-4. monitor.sh 시스템 모니터링 결과 (장애 진행 중 실측)
```
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app-leak'... [OK] (PID: 1)
Checking port 15034... [OK]

[STATUS CHECK]
[WARNING] 방화벽(UFW)이 비활성 상태입니다.

[RESOURCE MONITORING]
CPU Usage : 0.2%
MEM Usage : 5.7%
DISK Used : 3%

[INFO] Log appended: /var/log/agent-app/monitor.log
```
> monitor.sh 는 프로세스/포트 정상 확인. MEM 수치는 시스템 전체 기준이며
> 앱 힙 누수는 앱 내부 로그(`[MemoryWorker] Current Heap`)로 직접 추적된다.

## 3. Root Cause Analysis (원인 분석)

- `MemoryWorker` 가 작업 데이터를 힙에 계속 적재하고 해제하지 않아 RSS 가 단조 증가한다.
- `MemoryGuard` 가 현재 힙과 `MEMORY_LIMIT` 를 비교, 한도 도달 시 `SIGKILL` 자가 종료.
- 즉 **자가종료는 결과**, **근본 원인은 메모리 미해제(누수)** 이며 한도값이 낮을수록 빨리 터진다.
- PDF §6 제약(바이너리 리버싱 금지) → 앱 로그·`ps`·`monitor.sh` 외부 관찰로 규명.

## 4. Workaround & Verification (조치 및 검증)

### 우회 조치
- 단기: `MEMORY_LIMIT` 를 작업량 대비 충분히(권장 256 이상) 상향해 자가종료를 지연.
- 운영: `monitor.sh` 의 `MEM_THRESHOLD`(10%) 경고로 재발을 조기 감지.
- 주의: 누수 자체는 남아 있으므로 한도 상향은 임시책. 근본 해결은 앱 메모리 해제 수정.

### Before / After (실측)

| 구분 | MEMORY_LIMIT | 결과 |
|------|--------------|------|
| Before | 256 (MB) | 힙 275MB 에서 `Memory limit exceeded` → SIGKILL, Exited(137) |
| After  | 512 (MB) | 동일 구간 자가종료 없이 작업 지속 (정상 부팅 [OK]) |

### 검증 방법
```bash
verify2.sh memory     # 자동: 프로세스 종료 + MemoryGuard 신호 → PASS
# 수동: MANUAL_VERIFICATION.md §1 (힙 증가 추이 + 신호 로그 직접 확인)
```
실측 자동 검증 결과: **PASS** (`Memory limit exceeded (275MB >= 256MB)` 포착, 프로세스 종료).
