# 리눅스 프로세스 및 시스템 리소스 트러블슈팅

> AI/SW 기초 (Linux & OS) 미션 과제 결과물

---

## 미션 개요

| 항목 | 내용 |
|------|------|
| 분야 | AI/SW 기초 |
| 구분 | Linux와 OS |
| 학습 시간 | 40시간 |
| 주제 | 빌드된 프로그램(`agent-app`)을 운영 환경에서 실행하며 발생하는 시스템 장애 분석 및 리포팅 |

실서버에서 발생할 수 있는 **Memory Leak(OOM)**, **CPU Spike**, **Deadlock** 3가지 장애를 직접 재현하고,
관제 데이터와 로그를 근거로 원인을 분석하여 GitHub Issue 형태의 기술 리포트로 작성한다.

---

## 장애 유형별 이슈 리포트 요약

### 1. OOM Crash — 메모리 누수로 인한 MemoryGuard 강제 종료

| 항목 | 내용 |
|------|------|
| 발생 환경 | Ubuntu 24.04 LTS (Docker), `MEMORY_LIMIT=100` |
| 현상 | 앱 시작 약 9초 후 프로세스 예고 없이 종료 |
| 원인 | MemoryWorker가 3초마다 25MB씩 힙 할당 후 미해제 → 선형 메모리 누수 |
| 트리거 | 내부 MemoryGuard가 `MEMORY_LIMIT(100MB)` 도달 시 SIGKILL 자기 종료 |
| 조치 | `MEMORY_LIMIT=100` → `MEMORY_LIMIT=512` 상향 조정 |
| 검증 결과 | 30초 이상 정상 실행 확인 (100MB 초과 후에도 MemoryGuard 미발생) |
| 근본 해결 | MemoryWorker 할당 로직에 `del`/`pop`으로 주기적 해제 리팩토링 필요 |

**메모리 증가 패턴:**
```
25MB → 50MB → 75MB → 100MB → [CRITICAL] Memory limit exceeded
```

---

### 2. CPU Spike — CpuWorker 과점유로 인한 보호 정책 강제 종료

| 항목 | 내용 |
|------|------|
| 발생 환경 | Ubuntu 24.04 LTS (Docker), `CPU_MAX_OCCUPY=80` |
| 현상 | CpuWorker가 CPU를 점진적으로 높이다 ~50% 도달 시 프로세스 종료 |
| 원인 | 앱 내부 안전 임계치가 **50%로 하드코딩** — `CPU_MAX_OCCUPY=80` 설정 시 목표 도달 전에 임계치 초과 |
| 트리거 | `[CRITICAL] CPU Threshold Violated! (50.52%)` 메시지와 함께 강제 종료 |
| 조치 | `CPU_MAX_OCCUPY=80` → `CPU_MAX_OCCUPY=20` 하향 조정 |
| 검증 결과 | 20% 피크 도달 후 쿨다운 진입, 30초 이상 정상 실행 확인 |
| 근본 해결 | 안전 임계치를 `CPU_MAX_OCCUPY`에 연동하거나, busy-loop을 비동기 I/O로 리팩토링 필요 |

**CPU 증가 패턴:**
```
5% → 6% → 15% → 20% → 26% → 31% → 35% → 40% → 46% → 50.52% → 종료
```

---

### 3. Deadlock — 멀티스레드 환경에서 교착상태 발생으로 프로세스 무응답

| 항목 | 내용 |
|------|------|
| 발생 환경 | Ubuntu 24.04 LTS (Docker), `MULTI_THREAD_ENABLE=true` |
| 현상 | 앱 실행 약 7초 후 PID는 유지되나 CPU 0%, 로그 출력 완전 중단 |
| 원인 | Worker-Thread-1과 Worker-Thread-2가 서로의 자원을 순환 대기 (Circular Wait) |
| 교착 구조 | Thread-1: `Shared_Memory_A` 보유 → `Socket_Pool_B` 대기 / Thread-2: `Socket_Pool_B` 보유 → `Shared_Memory_A` 대기 |
| 조치 | `MULTI_THREAD_ENABLE=true` → `MULTI_THREAD_ENABLE=false` 변경 |
| 검증 결과 | 단일 스레드 Round-Robin 방식으로 Thread-A/B/C 순차 실행, 30초 이상 정상 동작 확인 |
| 근본 해결 | 락 순서 고정, `pthread_mutex_timedlock()` 타임아웃 도입, 또는 단일 뮤텍스 통합 |

**교착상태 4대 조건 (모두 충족):**

| 조건 | 충족 | 근거 |
|------|------|------|
| 상호 배제 | ✅ | 한 스레드만 락 보유 |
| 점유 대기 | ✅ | 락 보유한 채 다른 락 대기 |
| 비선점 | ✅ | 외부 강제 해제 불가 |
| 순환 대기 | ✅ | Thread-1 → B 대기, Thread-2 → A 대기 |

---

## 환경 변수 요약

| 환경 변수 | 정상 범위 | 이슈 발생 값 | 조치 값 |
|-----------|----------|-------------|---------|
| `MEMORY_LIMIT` | 256MB 이상 권장 | 100 | 512 |
| `CPU_MAX_OCCUPY` | 50% 미만 권장 | 80 | 20 |
| `MULTI_THREAD_ENABLE` | false (안정) | true | false |

---

## 이슈 리포트 파일

| 장애 유형 | 파일 |
|-----------|------|
| OOM Crash | [issue_oom.md](issue_oom.md) |
| CPU Spike | [issue_cpu.md](issue_cpu.md) |
| Deadlock | [issue_deadlock.md](issue_deadlock.md) |

---

## 개발 환경

- **OS**: Ubuntu 24.04 LTS (Docker 컨테이너)
- **앱**: `agent-app` (Python 기반 바이너리)
- **관제 도구**: `monitor.sh`, `ps`, `top`, `htop`
- **포트**: 15034 (고정)
