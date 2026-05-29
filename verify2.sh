#!/usr/bin/env bash
# =============================================================
# verify2.sh - 트러블슈팅 리포트 증거 자동 검증
# 역할: 3개 장애 시나리오(메모리 누수 / CPU 과점유 / 교착상태)를
#       실제로 재현시켜 리포트에 기재된 증거 신호가 나타나는지 확인.
# 검증 대상: issue_01~03 리포트의 [Evidence & Logs] 진위
# 실행 위치: 컨테이너 내부, root (앱은 agent-admin 으로 기동)
# 사용법:   verify2.sh                       # 전체 시나리오
#           verify2.sh memory|cpu|deadlock   # 단일 시나리오
# 제약: 바이너리 리버싱 금지 → 외부 관찰(로그/프로세스 상태)만으로 판정
# 비고: 앱은 부팅 시 MEMORY_LIMIT/CPU_MAX_OCCUPY/MULTI_THREAD_ENABLE
#       3개 환경변수가 모두 있어야 기동된다. 따라서 시나리오마다
#       3개를 전부 주입하되 해당 장애를 유발하는 값 하나만 바꾼다.
# =============================================================
set -u

AGENT_HOME="${AGENT_HOME:-/home/agent-admin/agent-app}"
APP_BIN="${AGENT_HOME}/agent-app-leak"

# ── 기준(정상) 환경값 — 앱 부팅 권장 범위 ────────────────────
BASE_MEM="${VERIFY_BASE_MEM:-512}"      # MEMORY_LIMIT (MB), 권장 >=256
BASE_CPU="${VERIFY_BASE_CPU:-50}"       # CPU_MAX_OCCUPY (%), 권장 <50
BASE_THR="${VERIFY_BASE_THR:-false}"    # MULTI_THREAD_ENABLE

# ── 장애 유발 환경값 ─────────────────────────────────────────
TRIG_MEM="${VERIFY_TRIG_MEM:-256}"      # 낮은 한도 → 누수가 빠르게 한도 초과
TRIG_CPU="${VERIFY_TRIG_CPU:-90}"       # 권장(50%) 초과 → CPU watchdog 발동
TRIG_THR="${VERIFY_TRIG_THR:-true}"     # 멀티스레드 → 교착

WAIT_SECS="${VERIFY_WAIT:-60}"         # 시나리오당 최대 관찰 시간(초)
# 주의: 앱은 AGENT_PORT 가 15034 가 아니면 부팅을 거부한다(포트 하드코딩).
#       따라서 verify2.sh 는 상시 앱이 떠 있지 않은 컨테이너에서 실행해야 한다.
#       (docker run image /usr/local/bin/verify2.sh ... 권장. start-entrypoint2
#        인자를 주지 않으면 래퍼가 앱을 기동하지 않는다.)

RUNDIR=/tmp/verify-run
mkdir -p "$RUNDIR"; chmod 777 "$RUNDIR"

PASS=0; FAIL=0

# ── 단일 시나리오 실행기 ─────────────────────────────────────
# 인자: 1=이름 2=MEMORY_LIMIT 3=CPU_MAX_OCCUPY 4=MULTI_THREAD_ENABLE
#       5=증거신호 정규식 6=기대 프로세스 상태(exited|alive)
run_case() {
    local name="$1" mem="$2" cpu="$3" thr="$4" sig="$5" want="$6"
    local out="$RUNDIR/${name}.log"
    : > "$out"; chmod 666 "$out"

    echo "------------------------------------------------------------"
    echo "[CASE] ${name}"
    echo "  주입: MEMORY_LIMIT=${mem} CPU_MAX_OCCUPY=${cpu} MULTI_THREAD_ENABLE=${thr}"

    # 앱을 agent-admin(비루트)으로 기동, 출력 캡처
    su agent-admin -c "cd '${AGENT_HOME}' && exec env \
        MEMORY_LIMIT=${mem} CPU_MAX_OCCUPY=${cpu} MULTI_THREAD_ENABLE=${thr} \
        ./agent-app-leak" >"$out" 2>&1 &
    local pid=$!

    # 관찰 루프: 종료 감지 또는 (교착처럼) 신호 포착 시 조기 중단
    local i state="alive" sig_seen=1
    for (( i = 0; i < WAIT_SECS; i++ )); do
        if ! kill -0 "$pid" 2>/dev/null; then state="exited"; break; fi
        if grep -aqE "$sig" "$out"; then
            sig_seen=0
            # 생존 기대(교착) 시 신호 확인되면 더 기다릴 필요 없음
            [ "$want" = "alive" ] && break
        fi
        sleep 1
    done

    # 잔존 프로세스 정리
    if [ "$state" = "alive" ]; then
        kill "$pid" 2>/dev/null
        wait "$pid" 2>/dev/null
    fi

    # 판정 1: 프로세스 상태
    local ok_state="FAIL"
    [ "$state" = "$want" ] && ok_state="OK"
    echo "  프로세스 상태: ${state} (기대=${want}) ... [${ok_state}]"

    # 판정 2: 증거 신호
    local ok_sig="FAIL" hit
    hit=$(grep -aE "$sig" "$out" | head -n1)
    [ -n "$hit" ] && ok_sig="OK"
    echo "  증거 신호: ${sig}"
    echo "  포착 로그: ${hit:-(없음)}"
    echo "  신호 판정 ... [${ok_sig}]"

    if [ "$ok_state" = "OK" ] && [ "$ok_sig" = "OK" ]; then
        echo "  >>> ${name}: PASS"
        PASS=$((PASS+1))
    else
        echo "  >>> ${name}: FAIL  (전체 출력: ${out})"
        FAIL=$((FAIL+1))
    fi
}

echo "============================================================"
echo " 트러블슈팅 리포트 증거 자동 검증 - verify2.sh"
echo " 대상 바이너리: ${APP_BIN}"
echo "============================================================"

[ -x "$APP_BIN" ] || { echo "[ERROR] 앱 바이너리 없음/실행불가: $APP_BIN"; exit 2; }

SEL="${1:-all}"

# ── CASE 1: 메모리 누수 → MemoryGuard 자가종료 ───────────────
if [ "$SEL" = "all" ] || [ "$SEL" = "memory" ]; then
    run_case "memory_leak" "$TRIG_MEM" "$BASE_CPU" "$BASE_THR" \
        "Memory limit exceeded|MemoryGuard|Self-terminating" "exited"
fi

# ── CASE 2: CPU 과점유 → CpuWorker 임계 위반 종료 ────────────
if [ "$SEL" = "all" ] || [ "$SEL" = "cpu" ]; then
    run_case "cpu_spike" "$BASE_MEM" "$TRIG_CPU" "$BASE_THR" \
        "CPU Threshold Violated|Terminated" "exited"
fi

# ── CASE 3: 교착상태 → 스레드 BLOCKED, 프로세스 생존 ─────────
if [ "$SEL" = "all" ] || [ "$SEL" = "deadlock" ]; then
    run_case "deadlock" "$BASE_MEM" "$BASE_CPU" "$TRIG_THR" \
        "Status: BLOCKED|WAITING for|DEADLOCK" "alive"
fi

echo "============================================================"
echo " 결과 요약: PASS=${PASS}  FAIL=${FAIL}"
echo "============================================================"
[ "$FAIL" -eq 0 ]
