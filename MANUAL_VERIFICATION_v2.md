# 수동 검증 가이드 v2 (MANUAL_VERIFICATION)

본 문서는 `verify2.sh`(자동 검증 스크립트)의 내부 로직, 환경 변수 주입 조건 및 장애 분석 리포트 3종([issue_01](file:///Users/kotaro83038303/.CMVolumes/프로트수/codyssey/b1-2/output_리눅스프로세스및시스템리소스트러블슈팅_b2/issue_01_memory_leak.md), [issue_02](file:///Users/kotaro83038303/.CMVolumes/프로트수/codyssey/b1-2/output_리눅스프로세스및시스템리소스트러블슈팅_b2/issue_02_cpu_spike.md), [issue_03](file:///Users/kotaro83038303/.CMVolumes/프로트수/codyssey/b1-2/output_리눅스프로세스및시스템리소스트러블슈팅_b2/issue_03_deadlock.md))에 기록된 실측 증거 자료들을 완벽히 재현하고 검증할 수 있도록 대폭 리팩토링된 수동 검증 절차서다.

---

## 0. 검증 전 필수 숙지 사항 & 기본 설정

### 1) 환경 변수 기동 제약
앱(`agent-app-leak`)은 부팅 시 **`MEMORY_LIMIT` · `CPU_MAX_OCCUPY` · `MULTI_THREAD_ENABLE` 3개 환경변수가 모두 정의되어 있어야** 정상 기동된다. 하나라도 누락되면 `System Boot Failed` 에러와 함께 즉시 종료된다.
- **정상(권장) 기본값**: `MEMORY_LIMIT=512` (MB), `CPU_MAX_OCCUPY=50` (%), `MULTI_THREAD_ENABLE=false`
- **장애 재현 설정**:
  - **메모리 누수**: `MEMORY_LIMIT=256` (한도 임계를 낮추어 빠른 자가종료 유도)
  - **CPU 과점유**: `CPU_MAX_OCCUPY=90` (안전 임계선 50% 초과 지점을 타깃 설정)
  - **교착 상태**: `MULTI_THREAD_ENABLE=true` (멀티스레드 동시성 활성화)

### 2) 실행 포트 및 셸 환경 제약
* 앱은 **`AGENT_PORT`가 `15034`가 아니면 부팅을 강제 거부**한다. 포트 충돌 방지를 위해 테스트 전 항상 기존 기동된 백그라운드 테스트 프로세스들을 정리한다. (`killall agent-app-leak agent-app-linux-x86 2>/dev/null`)
* 수동 검증 시 부모-자식 2중 프로세스 구동 문제를 완벽히 방지하여 RSS 수치 관찰을 쉽게 만들려면, 기동 명령어 앞에 반드시 **`exec`**를 주입하여 셸 프로세스를 대체한다.
* 💡 **모니터링 툴(`monitor.sh`) 프로세스 매칭 제약**: 
  컨테이너 내부에 구워진 `monitor.sh` 원본의 기본 헬스체크 프로세스명은 `agent-app-linux-x86`으로 하드코딩되어 있습니다. 따라서 우리가 장애 재현용으로 사용하는 `agent-app-leak`을 올바르게 감시하고 정상 판정(`[OK]`)을 내리게 하려면, 모니터링 스크립트 실행 전 반드시 **`export APP_NAME=agent-app-leak` 환경변수를 명시적으로 주입**해야 합니다.

### 3) 검증용 컨테이너 기동
```bash

#agent-app-leak and verify2.sh copy(b-2.sh폴더에서)
b-2.sh

#도커 컨테이너 진입
docker exec -it am bash

#기존 포트 선점하고 있는 에이전트앱 제거
pkill -9 -f agent-app-linux-x86

# (컨테이너 내부 진입 후) 기본 환경 변수 및 바이너리 권한 상태 사전 검증
env | grep -E '^AGENT_'
ls -l "$AGENT_HOME/agent-app-leak"
```
*기대 결과*: `AGENT_HOME` 경로 및 `AGENT_PORT=15034`가 조회되며, 바이너리는 `-rwxr-x--- agent-admin agent-core` 권한을 가진다. 아래의 모든 수동 검증 명령어는 이 컨테이너 터미널 내에서 실행한다.

---

## 1. 메모리 누수 → MemoryGuard 자가종료 (issue_01 검증)

### 검증 개요
작업 스레드(`MemoryWorker`)가 3초마다 25MB씩 힙 메모리를 해제 없이 늘려가다, 환경변수로 지정한 낮은 임계값(`MEMORY_LIMIT=256`)을 초과하는 순간 앱 내의 자가 모니터링 모듈(`MemoryGuard`)이 시스템 다운을 막기 위해 **스스로를 강제 종료(`SIGKILL` / Exited 137)**시키는지 검증한다.

### 수동 검증 수행 절차

#### 1-1. [Before] 낮은 메모리 한도로 백그라운드 앱 기동 (비루트 `agent-admin` 권한 + `exec` 주입)
```bash
su agent-admin -c "cd $AGENT_HOME && \
  exec env MEMORY_LIMIT=256 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false \
  ./agent-app-leak" > /tmp/m.log 2>&1 &
echo "PID=$!"
```

#### 1-2. 초기 부팅 환경 경고(Recommend Over 256MB) 검증
```bash
sleep 2; head -n 30 /tmp/m.log
```
*기대 결과*: 로그 상단에 아래와 같이 기준 미달 경고가 명확히 출력되는지 확인한다.
> `[ MEMORY ] Limit: 256MB   [ WARNING: Recommend Over 256MB ]`

#### 1-3. 힙(Heap) 및 RSS(실 메모리)의 단조 증가 실시간 추적
```bash
# 약 10초 대기 후 힙 증가 로그 조회
sleep 10; grep 'Current Heap' /tmp/m.log
```
*기대 결과*: `[MemoryWorker] Current Heap: 25MB → 50MB → 75MB → ...` 형태로 3초당 25MB씩 단조 증가해야 한다.

```bash
# ps 커맨드를 통해 실제 시스템 물리 메모리(RSS) 증가 추이 교차 관찰 (exec로 단일 프로세스만 조회됨)
for i in 1 2 3; do ps -o pid,rss,cmd -C agent-app-leak --no-headers; sleep 5; done
```
*기대 결과*: 루프마다 `RSS` 값이 계속 커지는 것을 실측할 수 있어야 한다.

#### 1-4. 시스템 모니터링(`monitor.sh`) 로그 연동 검증
누수가 진행 중일 때(기동 후 30초 이내 추천), 시스템 모니터링 스크립트를 백그라운드 크론 대신 수동으로 강제 가동하여 상태를 검증한다.
```bash
# 로그 디렉토리 사전 생성 및 APP_NAME 매칭 환경변수 주입
export APP_NAME=agent-app-leak

# 모니터링 스크립트 수동 기동 및 로그 분석
/home/agent-admin/agent-app/bin/monitor.sh
cat /var/log/agent-app/monitor.log
```
*기대 결과*: `Checking process 'agent-app-leak'... [OK]`, `Checking port 15034... [OK]` 및 시스템 전체 기준 자원 소모 스냅샷(MEM Usage)이 오류 없이 모니터링 로그에 정상 기록되는지 검증한다.

#### 1-5. 한도 초과 및 자가종료 증거 검증 (`verify2.sh` 매핑)
```bash
# 자가종료 임계선 도달 시점 대기 (약 20초 추가 대기)
sleep 20
pgrep -f agent-app-leak || echo "프로세스 자가종료됨 [OK]"
```
*기대 결과*: `verify2.sh`와 동일한 패턴 매칭 명령어를 사용하여 최종 차단 신호가 존재하는지 확인한다.
```bash
grep -E 'Memory limit exceeded|MemoryGuard|Self-terminating' /tmp/m.log
```
*핵심 검출 증거*:
> `[CRITICAL] [MemoryGuard] Memory limit exceeded (275MB >= 256MB)`
> `[CRITICAL] [MemoryGuard] Self-terminating process <PID> to prevent system instability.`

**판정 (Before)**: 초기 경고 검출 + 힙/RSS 단조 증가 + monitor.sh 정상 실행 + MemoryGuard 차단 신호 포착 + 프로세스 자가종료(`Exited 137`) 확인 시 **이슈 재현 및 감지 검증 완료**.

#### 1-6. [After] 우회 조치 검증 (충분한 메모리 한도 512MB로 기동)
```bash
# 기존 테스트 찌꺼기 완벽 클린업 후 상향된 메모리로 기동
killall agent-app-leak 2>/dev/null
su agent-admin -c "cd $AGENT_HOME && \
  exec env MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false \
  ./agent-app-leak" > /tmp/m_after.log 2>&1 &
echo "PID=$!"
```
```bash
# 자가종료 구간이었던 40초를 충분히 대기한 후 결과 관찰
sleep 40
pgrep -f agent-app-leak && echo "프로세스 정상 유지 중 [OK]"
```
*기대 결과*: 프로세스가 자가종료 없이 안정적으로 살아있으며, 자가종료 로그(`Memory limit exceeded` 등)가 남지 않고 정상적인 처리가 장기 지속되는 상태를 수동으로 확인한다.
```bash
# 검사 완료 후 클린업
kill "$(pgrep -f agent-app-leak | head -n1)" 2>/dev/null
```

**최종 판정**: Before OOM 자가종료 재현 + After 메모리 상향 조치 후 프로세스 생존이 모두 입증되었을 시 **issue_01 검증 통과**.

---

## 2. CPU 과점유 → CpuWorker 임계 위반 종료 (issue_02 검증)

### 검증 개요
작업 스레드(`CpuWorker`)가 단일 코어 연산 부하를 서서히 끌어올리다가, 안전 기준선(50%)을 초과하는 수준의 높은 타깃(`CPU_MAX_OCCUPY=90`)에 도달해 50% 경계선을 넘는 즉시 자체 감시 로직에 따라 프로세스를 **`SIGTERM`(Exited 143)**으로 안전하게 자동 종료시키는지 확인한다.

### 수동 검증 수행 절차

#### 2-1. [Before] 권장 범위를 초과하는 높은 임계값 설정으로 백그라운드 앱 기동
```bash
su agent-admin -c "cd $AGENT_HOME && \
  exec env MEMORY_LIMIT=512 CPU_MAX_OCCUPY=90 MULTI_THREAD_ENABLE=false \
  ./agent-app-leak" > /tmp/c.log 2>&1 &
echo "PID=$!"
```

#### 2-2. 초기 부팅 환경 경고(Recommend Under 50%) 검증
```bash
sleep 2; head -n 30 /tmp/c.log
```
*기대 결과*: 로그 상단에 아래와 같이 권장 초과 경고가 정확하게 표시되는지 확인한다.
> `[ CPU    ] Limit: 90%    [ WARNING: Recommend Under 50% ]`

#### 2-3. 실시간 CPU 부하 상승 교차 관찰 (`top` 활용)
```bash
# 약 10초 대기 후 로드 증가 로그 조회
sleep 10; grep 'Current Load' /tmp/c.log
```
*기대 결과*: `[CpuWorker] Current Load` 수치가 점진적으로 상승(5% → 9% → 15% → ...)하는 것이 확인된다.

```bash
# top 커맨드를 이용해 실제 CPU 사용률 확인
top -b -n 20 -d 0.1 -p "$(pgrep -f "agent-app-leak" | grep -v "su" | paste -sd, -)" | grep -v -E "( 0.0  0.1| 0.0  0.0)"
```
*기대 결과*: `agent-app-leak` 프로세스가 단일 CPU 자원을 집중 점유하고 있음을 실시간 실측한다.

#### 2-4. 모니터링 백그라운드 크론 검토 (`monitor.sh` 연동 주의 사항)
CPU 임계 위반 현상 발생 도중 또는 종료 직후 `monitor.sh`를 구동하고 로그를 본다.
```bash
/home/agent-admin/agent-app/bin/monitor.sh
cat /var/log/agent-app/monitor.log
```
*분석 포인트*: 모니터링 크론은 1분 주기로 스냅샷을 캡처한다. 반면 CPU 급증 장애는 기동 후 약 30초 내에 발생하고 앱이 바로 강제 종료되므로, 1분 단위 스냅샷 로그에는 CPU Peak가 정상적으로 포착되지 않을 수 있습니다. 따라서 CPU 과점유 규명 시에는 **실시간 `top` 분석 및 앱 내부 로그의 임계 위반 검출**을 수동으로 수행하는 절차가 왜 필수적인지 교차 학습합니다.

#### 2-5. 임계 위반 강제 종료 대기 및 증거 검증 (`verify2.sh` 매핑)
```bash
# 약 15초 추가 대기 후 정상 종료 확인
sleep 15
pgrep -f agent-app-leak || echo "프로세스 자가종료됨 [OK]"
```
*기대 결과*: `verify2.sh` 판단 정규식과 연동하여 종료 메시지가 포착되는지 검색한다.
```bash
grep -E 'CPU Threshold Violated|Terminated' /tmp/c.log
```
*핵심 검출 증거*:
> `[CRITICAL] [CpuWorker] CPU Threshold Violated! (52.91%).`
> `Terminated` (SIGTERM에 의한 셸 차단 알림)

**판정 (Before)**: 초기 권장 범위 위반 경고 + CPU Load 및 top 실측 상승 + 모니터링 스냅샷 한계 인지 + CPU 임계 Violated 신호 포착 + 프로세스 종료(`Exited 143`) 확인 시 **이슈 재현 및 감지 검증 완료**.

#### 2-6. [After] 우회 조치 검증 (권장 CPU 한도 50%로 기동)
```bash
# 기존 테스트 찌꺼기 완벽 클린업 후 권장 한도로 기동
killall agent-app-leak 2>/dev/null
su agent-admin -c "cd $AGENT_HOME && \
  exec env MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false \
  ./agent-app-leak" > /tmp/c_after.log 2>&1 &
echo "PID=$!"
```
```bash
# 안전 임계를 넘는 시점(40초)을 대기하여 관찰
top -b -n 20 -d 2 -p "$(pgrep -f "agent-app-leak" | grep -v "su" | paste -sd, -)" | awk '/agent-a/ {print "Current Load: "$9"%"}'
pgrep -f agent-app-leak && echo "프로세스 정상 유지 중 [OK]"
```
*기대 결과*: 부하(Load)가 50% 부근에서 안전하게 통제되고 자가종료되지 않고 생존하여 프로세스가 계속 작업을 문제없이 수행하고 있음을 확인한다.
```bash
# 검사 완료 후 클린업
kill "$(pgrep -f agent-app-leak | head -n1)" 2>/dev/null
```

**최종 판정**: Before CPU 오버 플로우 자가종료 재현 + After 임계 한도 재조정 후 프로세스 안정 작동이 모두 입증되었을 시 **issue_02 검증 통과**.

---

## 3. 교착상태(Deadlock) → 진행 정지 (issue_03 검증)

### 검증 개요
`MULTI_THREAD_ENABLE=true`로 멀티스레드 방식을 적용할 경우, 두 작업 스레드가 `Shared_Memory_A`와 `Socket_Pool_B`에 대해 상호 점유 및 교차 락 대기에 빠지는 순환 대기(Circular Wait) 상태를 유발한다. 이 경우 프로세스는 강제 종료되지 않고 계속 **살아있으나(`alive`) 실제 아무런 처리를 수행하지 않고 정지**된 상태를 파악하는 것이 핵심이다.

### 수동 검증 수행 절차

#### 3-1. [Before] 멀티스레드 옵션을 켠 채 백그라운드로 앱 기동
```bash
su agent-admin -c "cd $AGENT_HOME && \
  exec env MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=true \
  ./agent-app-leak" > /tmp/d.log 2>&1 &
APP_PID=$(pgrep -f "agent-app-leak" | grep -v "su" | tail -n1)
echo "PID=${APP_PID}"
```

#### 3-2. 초기 부팅 잠재적 교착 경고(POTENTIAL DEADLOCK) 검증
```bash
sleep 2; head -n 30 /tmp/d.log
```
*기대 결과*: 로그 상단에 잠재적 교착상태 경고 메시지가 포착되는지 확인한다.
> `>>> SYSTEM WARNING: POTENTIAL DEADLOCK IN CONCURRENT MODE.`

#### 3-3. 교착 상태 진입 및 락 획득/대기(Status: BLOCKED) 로그 확인
```bash
sleep 15
grep -E 'LOCK ACQUIRED|Status: BLOCKED|WAITING for|DEADLOCK' /tmp/d.log
```
*기대 결과*: 두 스레드가 서로 다른 락을 선획득(ACQUIRED)한 후, 상대방 스레드가 가진 락 자원을 무한정 요구하며 대기 상태로 고착된 상황을 판독한다.
> `[Worker-Thread-1] LOCK ACQUIRED: [Shared_Memory_A]. (Holding...)`
> `[Worker-Thread-2] LOCK ACQUIRED: [Socket_Pool_B]. (Holding...)`
> `[Worker-Thread-1] WAITING for [Socket_Pool_B]... (Status: BLOCKED)`
> `[Worker-Thread-2] WAITING for [Shared_Memory_A]... (Status: BLOCKED)`

#### 3-4. 스레드(LWP) 수준의 정밀 상태 검증 (`ps -L` 및 `top -H` 실측)
이슈 리포트의 기술 분석 방식과 일치하는 스레드 수준 모니터링 명령어로 실태를 상세 확인한다.
```bash
# 1) ps -L 커맨드로 개별 스레드 STAT 및 CPU 사용율 실시간 관찰
ps -L -p "${APP_PID}" -o pid,lwp,stat,%cpu,%mem,comm
```
*기대 결과*: 메인 스레드 외에 `Worker-Thread-1`(LWP 11)과 `Worker-Thread-2`(LWP 12)가 모두 대기 상태(`STAT=S` 또는 `SNl`), `%CPU=0.0%`로 자원 변동 없이 고정된 상황이 표시된다.

```bash
# 2) top 스레드 정밀 모드를 실행하여 멈춰 있는 하위 스레드를 교차 분석
top -bH -n1 | grep -E "PID|agent-app|${APP_PID}"
```
*기대 결과*: 실제 락을 대기하는 스레드가 스케줄러에서 대기 상태로 유지되며 CPU 점유율을 0.0%로 최소화한 채 정지되어 있음을 정밀 규명한다.

```bash
# 3) 실시간 로그 기록 중단 교차 검증
tail -n 5 /tmp/d.log
```
*기대 결과*: 스레드가 BLOCKED 상태에 머문 이후에는 시간이 지나도 추가 로그(Progress)가 더 이상 기록되지 않는다.

#### 3-5. 헬스체크 툴(`monitor.sh`)의 오판 한계 증명
```bash
/home/agent-admin/agent-app/bin/monitor.sh
cat /var/log/agent-app/monitor.log
```
*분석 포인트*: 교착상태 시 프로세스 PID와 TCP 15034 포트는 활성(Listen) 상태를 지속하므로, `export APP_NAME=agent-app-leak`를 통해 헬스체크를 기동하면 `monitor.sh`는 `[HEALTH CHECK] ... [OK]` 판정을 내립니다. 즉, 프로세스가 완전히 정지해 작업이 불능임에도 단순 포트/프로세스 기동 여부 검사(헬스체크)만으로는 장애를 전혀 감지하지 못한다는 시스템 관리적 한계를 수동 분석을 통해 이해하고 증명합니다.

**판정 (Before)**: 초기 대형 경고 확인 + 상호 WAITING(BLOCKED) 락 로그 + 스레드(LWP) 단위 S 상태 및 CPU 0% 실측 + monitor.sh 정상 오판 한계 입증 시 **이슈 재현 및 감지 검증 완료**.

#### 3-6. [After] 장애 우회(단일 스레드 변경) 및 정상 동작 해소 검증
```bash
# 기존 교착상태 프로세스 제거
kill "${APP_PID}" 2>/dev/null

# 멀티스레드 옵션을 비활성화(false)하여 다시 기동 (exec 반영)
su agent-admin -c "cd $AGENT_HOME && \
  exec env MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false \
  ./agent-app-leak" > /tmp/d2.log 2>&1 &
echo "PID=$!"
sleep 15
```
```bash
# 단일 스레드로 원활하게 연산이 완료되었는지 확인
grep -E 'Task Completed|Healthy' /tmp/d2.log
```
*기대 결과*: `Task Completed` 가 발견되며, 단일 스레드 구동을 통한 락 경쟁 해소 정책(Workaround)의 유효성을 수동으로 입증한다.
```bash
# 테스트 프로세스 클린업
kill "$(pgrep -f agent-app-leak | head -n1)" 2>/dev/null
```

**최종 판정**: Before 멀티스레드 교착 재현 + After 싱글스레드 우회 조치 후 정상 동작 완료가 모두 입증되었을 시 **issue_03 검증 통과**.

---

## 4. 자동 검증(verify2.sh)과의 종합 대응 마스터 테이블

자동 검증 스크립트 `verify2.sh`에서 시나리오마다 주입하는 환경 변수 값, 최종 검출 정규식, 기대 프로세스 상태는 수동 검증의 판정식과 아래와 같이 100% 매핑된다.

| 장애 시나리오 | 주입 파라미터 조합 (Memory/CPU/Thread) | 기대 프로세스 상태 (`want`) | `verify2.sh` 감지 정규식 (자동 검출 대상) | 수동 검증 상세 보강 항목 (이슈 리포트 대응 실측) |
| :--- | :--- | :--- | :--- | :--- |
| **1. 메모리 누수**<br>(issue_01) | `MEMORY_LIMIT=256`<br>`CPU_MAX_OCCUPY=50`<br>`MULTI_THREAD_ENABLE=false` | **exited** (137) | `Memory limit exceeded`<br>`MemoryGuard`<br>`Self-terminating` | • [Before] OOM 자가종료 검증 (256MB)<br>• [After] 정상 상향 검증 (512MB 생존)<br>• RSS 메모리 및 `monitor.sh` 연동 검증 |
| **2. CPU 과점유**<br>(issue_02) | `MEMORY_LIMIT=512`<br>`CPU_MAX_OCCUPY=90`<br>`MULTI_THREAD_ENABLE=false` | **exited** (143) | `CPU Threshold Violated`<br>`Terminated` | • [Before] CPU 임계 위반 검증 (90%)<br>• [After] 권장 기준 통제 검증 (50% 생존)<br>• 실시간 `top` 추적 및 모니터링 샘플링 분석 |
| **3. 교착 상태**<br>(issue_03) | `MEMORY_LIMIT=512`<br>`CPU_MAX_OCCUPY=50`<br>`MULTI_THREAD_ENABLE=true` | **alive** | `Status: BLOCKED`<br>`WAITING for`<br>`DEADLOCK` | • [Before] 교착 상태 정지 검증 (true)<br>• [After] 단일 스레드 해소 검증 (false 정상완료)<br>• `ps -L` / `top -H`를 통한 개별 LWP 상태(S) 규명 |
