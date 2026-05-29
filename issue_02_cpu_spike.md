# [Bug] agent-app-leak CPU 과점유로 CpuWorker 임계 위반 종료

> 장애 분석 리포트 — CPU Spike Case (PDF §4.3, §8)
> 아래 로그는 컨테이너 실측 채집본. 재검증: `verify2.sh cpu` / `MANUAL_VERIFICATION.md` §2

## 1. Description (현상 설명)

`agent-app-leak` 실행 시 `CpuWorker` 가 CPU 부하(Load)를 점진적으로 끌어올린다.
환경변수 `CPU_MAX_OCCUPY` 를 권장 한도(50%) 초과 값으로 주면, 부하가 안전선(약 50%)을
넘는 순간 `CpuWorker` 가 `CPU Threshold Violated` 를 기록하고 프로세스를 `SIGTERM` 으로
**강제 종료**한다. 재현 조건: `CPU_MAX_OCCUPY=90` (부팅 시 "Recommend Under 50%" 경고).

## 2. Evidence & Logs (증거 자료 — 실측)

### 2-1. 부팅 시 환경 경고
```
 [ CPU    ] Limit: 90%  		[ WARNING: Recommend Under 50% ]
```

### 2-2. Application Log — 부하 상승 후 임계 위반 종료
```
2026-05-21 18:01:39,689 [INFO] [CpuWorker] Current Load: 5.00%
2026-05-21 18:01:42,789 [INFO] [CpuWorker] Current Load: 9.43%
   ... (Load 점진 상승) ...
2026-05-21 18:02:05,618 [INFO] [CpuWorker] Current Load: 44.14%
2026-05-21 18:02:08,719 [INFO] [CpuWorker] Current Load: 52.91%
2026-05-21 18:02:08,819 [CRITICAL] [CpuWorker] CPU Threshold Violated! (52.91%).
Terminated
```

### 2-3. 프로세스 종료 코드
```
컨테이너 상태: Exited (143)   # 143 = 128 + 15(SIGTERM), watchdog 강제 종료
```

### 2-4. monitor.sh 시스템 모니터링 결과 (장애 진행 중 실측)
```
====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app-leak'... [OK] (PID: 461)
Checking port 15034... [OK]

[STATUS CHECK]
[WARNING] 방화벽(UFW)이 비활성 상태입니다.

[RESOURCE MONITORING]
CPU Usage : 0.0%
MEM Usage : 5.2%
DISK Used : 3%

[INFO] Log appended: /var/log/agent-app/monitor.log

====== SYSTEM MONITOR RESULT ======

[HEALTH CHECK]
Checking process 'agent-app-leak'... [OK] (PID: 461)
Checking port 15034... [OK]

[STATUS CHECK]
[WARNING] 방화벽(UFW)이 비활성 상태입니다.

[RESOURCE MONITORING]
CPU Usage : 0.0%
MEM Usage : 5.2%
DISK Used : 3%

[INFO] Log appended: /var/log/agent-app/monitor.log
```
> monitor.sh 는 매분 1회 스냅샷을 찍는다. CPU 스파이크는 약 30초 내 발생 후 종료되므로
> 매분 샘플에서 포착되지 않을 수 있다. 실시간 부하는 앱 로그(`[CpuWorker] Current Load`)와
> `top` 교차 확인이 권장된다(MANUAL_VERIFICATION.md §2 참조).

## 3. Root Cause Analysis (원인 분석)

- `CpuWorker` 가 처리 루프에서 CPU 부하를 계속 키워 단일 코어 점유율이 상승한다.
- `CPU_MAX_OCCUPY` 를 50% 초과로 설정하면 앱이 부하를 안전선 너머까지 밀어붙이고,
  `CpuWorker` 가 임계 위반을 감지해 `SIGTERM` 으로 자가 종료시킨다.
- **강제 종료는 결과**, **근본 원인은 과도한 CPU 점유 연산 + 권장 초과 한도값**.
- PDF §6 제약(리버싱 금지) → `top`·앱 로그·`monitor.sh` 외부 관찰로 규명.

## 4. Workaround & Verification (조치 및 검증)

### 우회 조치
- 단기: `CPU_MAX_OCCUPY` 를 권장 범위(50% 미만)로 되돌려 임계 위반 종료를 회피.
- 운영: `monitor.sh` 의 `CPU_THRESHOLD`(20%) 경고로 부하 급등을 조기 감지.

### Before / After (실측)

| 구분 | CPU_MAX_OCCUPY | 결과 |
|------|----------------|------|
| Before | 90 (%) | Load 52.91% 에서 `CPU Threshold Violated` → SIGTERM, Exited(143) |
| After  | 50 (%) | 정상 부팅 [OK], Load 가 50% 부근에서 안정, 종료 없음 |

### 검증 방법
```bash
verify2.sh cpu        # 자동: 프로세스 종료 + CPU Threshold Violated 신호 → PASS
# 수동: MANUAL_VERIFICATION.md §2 (top %CPU 급등 + 신호 로그 직접 확인)
```
실측 자동 검증 결과: **PASS** (`CPU Threshold Violated! (53.67%)` 포착, 프로세스 종료).
