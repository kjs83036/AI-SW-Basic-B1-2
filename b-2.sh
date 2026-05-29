#!/usr/bin/env bash
# b-2.sh — agent-monitor 컨테이너(am) leak 검증 래퍼
# 전제: docker build -t agent-monitor <b1_dir>/ 완료,
#        docker run -d --cap-add=NET_ADMIN --name am agent-monitor start-entrypoint 완료

set -u

CONTAINER=am
IMAGE=agent-monitor
SCRIPT_DIR="."
LEAK_BIN="${SCRIPT_DIR}/agent-app-leak"
VERIFY_SRC="${SCRIPT_DIR}/verify2.sh"
LEAK_DST=/home/agent-admin/agent-app/agent-app-leak
VERIFY_DST=/usr/local/bin/verify2.sh
#
## ── 색상 헬퍼 ─────────────────────────────────────────
#RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
#BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'
#
#info()  { echo -e "  ${BLUE}▶${NC} $*"; }
#ok()    { echo -e "  ${GREEN}[OK]${NC} $*"; }
#fail()  { echo -e "  ${RED}[FAIL]${NC} $*"; }
#warn()  { echo -e "  ${YELLOW}[WARN]${NC} $*"; }
#
#step_header() {
#    echo
#    echo -e "${BOLD}═══════ $* ═══════${NC}"
#}
#
## Enter 대기. 인자: 버튼 라벨
#pause() {
#    echo
#    echo -ne "  ${BOLD}[Enter: ${1:-다음}]${NC} "
#    read -r _
#}
#
## 명령 출력 → Enter → 실행 → 결과
#run_step() {
#    local cmd="$1"
#    echo -e "\n  실행할 명령:\n    ${BOLD}\$ ${cmd}${NC}"
#    pause "실행"
#    echo "--- 출력 ---"
#    eval "$cmd"
#    echo "--- 끝 ---"
#}
#
## ── 자동 검증 ─────────────────────────────────────────
#auto_verify() {
#    echo
#    echo -e "${BOLD}▶ 자동 검증 실행${NC} — 전체 시나리오 (최대 360초)"
#    echo
#    docker exec -u root "${CONTAINER}" "${VERIFY_DST}"
#    local rc=$?
#    echo
#    if [ $rc -eq 0 ]; then
#        ok "자동 검증 완료 — 전체 통과"
#    else
#        fail "자동 검증 종료 (exit ${rc}) — FAIL 항목 확인 필요"
#    fi
#}
#
## ── 수동 검증 ─────────────────────────────────────────
#manual_verify() {
#    echo
#    echo -e "${BOLD}▶ 수동 검증${NC} — Step 0 ~ Step 4"
#    echo "  단계마다: 명령 표시 → Enter → 실행 → 결과 → Enter → 다음"
#    echo "  각 시나리오는 정상 환경[Before]과 장애 유발 환경[After]을 비교한다."
#    pause "시작"
#
#    # ── Step 0: 환경 점검 ──────────────────────────────────────────
#    step_header "Step 0: 컨테이너 환경 사전 점검"
#    echo "  목적: AGENT_ 환경변수, leak 바이너리, verify.sh 존재 확인"
#    run_step "docker exec ${CONTAINER} bash -c 'env | grep ^AGENT_'"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} ls -l ${LEAK_DST}"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} head -20 ${VERIFY_DST}"
#    pause "Step 1-A로"
#
#    # ── Step 1-A [Before]: memory — 정상 한도(512MB) 힙 추이 관찰 ──
#    step_header "Step 1-A [Before]: memory_leak — 정상 한도(MEMORY_LIMIT=512) 힙 추이"
#    echo "  목적: 512MB 한도에서 힙이 증가해도 프로세스가 종료되지 않음을 확인"
#    echo "  소요: 앱 기동 후 15초 관찰"
#    run_step "docker exec -u root ${CONTAINER} bash -c 'su agent-admin -c \"cd \$AGENT_HOME && exec env MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false ./agent-app-leak\" >/tmp/mb.log 2>&1 &'"
#    info "15초 대기 중 (힙 상승 추이 수집)..."
#    sleep 15
#    run_step "docker exec ${CONTAINER} grep 'Current Heap' /tmp/mb.log | tail -5"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} ps -o pid,rss,cmd -C agent-app-leak --no-headers"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} bash -c 'pgrep -f agent-app-leak && echo 프로세스_생존 || echo 프로세스_없음'"
#    run_step "docker exec ${CONTAINER} bash -c 'pkill -f agent-app-leak 2>/dev/null; echo done'"
#    pause "Step 1-B(After)로"
#
#    # ── Step 1-B [After]: memory — 낮은 한도(256MB) → MemoryGuard 트리거 ─
#    step_header "Step 1-B [After]: memory_leak — 낮은 한도(MEMORY_LIMIT=256) → MemoryGuard"
#    echo "  목적: MEMORY_LIMIT=256 → 힙 누수 후 [CRITICAL] 로그 + 자가종료 확인"
#    echo "  소요: 최대 120초"
#    run_step "docker exec -u root ${CONTAINER} ${VERIFY_DST} memory"
#    pause "Step 2-A로"
#
#    # ── Step 2-A [Before]: cpu — 정상 한도(50%) CPU 추이 관찰 ────────
#    step_header "Step 2-A [Before]: cpu_spike — 정상 한도(CPU_MAX_OCCUPY=50) CPU 추이"
#    echo "  목적: CPU 50% 한도에서 임계치를 넘지 않고 정상 실행됨을 확인"
#    echo "  소요: 앱 기동 후 20초 관찰"
#    run_step "docker exec -u root ${CONTAINER} bash -c 'su agent-admin -c \"cd \$AGENT_HOME && exec env MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false ./agent-app-leak\" >/tmp/cb.log 2>&1 &'"
#    info "20초 대기 중 (CPU 부하 추이 수집)..."
#    sleep 20
#    run_step "docker exec ${CONTAINER} grep 'Current Load' /tmp/cb.log | tail -5"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} bash -c 'top -b -n1 -p \"\$(pgrep -f agent-app-leak | head -n1)\" 2>/dev/null | tail -3'"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} bash -c 'pgrep -f agent-app-leak && echo 프로세스_생존 || echo 프로세스_없음'"
#    run_step "docker exec ${CONTAINER} bash -c 'pkill -f agent-app-leak 2>/dev/null; echo done'"
#    pause "Step 2-B(After)로"
#
#    # ── Step 2-B [After]: cpu — 높은 한도(90%) → Watchdog 트리거 ────
#    step_header "Step 2-B [After]: cpu_spike — 높은 한도(CPU_MAX_OCCUPY=90) → Watchdog"
#    echo "  목적: CPU_MAX_OCCUPY=90 → CPU Threshold Violated + 강제 종료 확인"
#    echo "  소요: 최대 120초"
#    run_step "docker exec -u root ${CONTAINER} ${VERIFY_DST} cpu"
#    pause "Step 3-A로"
#
#    # ── Step 3-A [Before/교착]: deadlock — BLOCKED 로그 + 스레드 상태 관찰 ─
#    step_header "Step 3-A [Before/교착]: deadlock — MULTI_THREAD_ENABLE=true → 교착 발생"
#    echo "  목적: 멀티스레드 활성화 → BLOCKED 로그 + ps -eLf 스레드 상태 확인"
#    echo "  소요: 앱 기동 후 25초 관찰"
#    run_step "docker exec -u root ${CONTAINER} bash -c 'su agent-admin -c \"cd \$AGENT_HOME && exec env MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=true ./agent-app-leak\" >/tmp/db.log 2>&1 &'"
#    info "25초 대기 중 (교착 발생 대기)..."
#    sleep 25
#    run_step "docker exec ${CONTAINER} grep -E 'POTENTIAL DEADLOCK|Status: BLOCKED|WAITING for' /tmp/db.log"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} ps -eLf | grep '[a]gent-app-leak'"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} ps -o pid,stat,%cpu,rss,cmd -C agent-app-leak --no-headers"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} tail -3 /tmp/db.log"
#    run_step "docker exec ${CONTAINER} bash -c 'pkill -f agent-app-leak 2>/dev/null; echo done'"
#    pause "Step 3-B(After/해소)로"
#
#    # ── Step 3-B [After/해소]: deadlock — MULTI_THREAD=false 정상 실행 확인 ─
#    step_header "Step 3-B [After/해소]: deadlock — MULTI_THREAD_ENABLE=false → 정상 실행"
#    echo "  목적: 멀티스레드 비활성화 → 교착 없이 정상 실행 확인 (해소 검증)"
#    echo "  소요: 앱 기동 후 20초 관찰"
#    run_step "docker exec -u root ${CONTAINER} bash -c 'su agent-admin -c \"cd \$AGENT_HOME && exec env MEMORY_LIMIT=512 CPU_MAX_OCCUPY=50 MULTI_THREAD_ENABLE=false ./agent-app-leak\" >/tmp/db2.log 2>&1 &'"
#    info "20초 대기 중 (정상 실행 관찰)..."
#    sleep 20
#    run_step "docker exec ${CONTAINER} grep -E 'Task Completed|Healthy' /tmp/db2.log | tail -5"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} bash -c 'grep -q \"Status: BLOCKED\" /tmp/db2.log && echo 교착_감지됨 || echo 교착상태_없음_확인'"
#    pause "계속"
#    run_step "docker exec ${CONTAINER} ps -o pid,stat,%cpu,rss,cmd -C agent-app-leak --no-headers"
#    run_step "docker exec ${CONTAINER} bash -c 'pkill -f agent-app-leak 2>/dev/null; echo done'"
#    pause "Step 4로"
#
#    # ── Step 4: 결과 로그 파일 확인 ────────────────────────────────
#    step_header "Step 4: 검증 결과 로그 파일 확인"
#    echo "  목적: 각 시나리오 로그(/tmp/verify-run/) 생성 여부 확인"
#    run_step "docker exec ${CONTAINER} ls -lh /tmp/verify-run/"
#
#    echo
#    ok "수동 검증 완료"
#}
#
## ═══════════════════════════════════════════════════════
## 메인
## ═══════════════════════════════════════════════════════
#
#echo
#echo -e "${BOLD}╔══════════════════════════════════════════╗${NC}"
#echo -e "${BOLD}║   b-2  agent-monitor leak 검증 래퍼     ║${NC}"
#echo -e "${BOLD}╚══════════════════════════════════════════╝${NC}"
#echo
#
## 0. 사전 점검
#info "사전 점검 중..."
#
#if ! docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qx "${CONTAINER}"; then
#    fail "컨테이너 '${CONTAINER}' 미존재."
#    echo "  먼저 아래 명령으로 컨테이너를 생성하세요:"
#    echo "    docker run -d --cap-add=NET_ADMIN --name ${CONTAINER} ${IMAGE} start-entrypoint"
#    exit 1
#fi
#ok "컨테이너 '${CONTAINER}' 존재 확인"
#
#for f in "${LEAK_BIN}" "${VERIFY_SRC}"; do
#    if [ ! -f "$f" ]; then
#        fail "파일 없음: ${f}"
#        exit 1
#    fi
#done
#ok "자산 파일 확인 (agent-app-leak, verify2.sh)"
#
## 1. 검증용 idle 컨테이너 재기동
#RUNNING=$(docker inspect -f '{{.State.Running}}' "${CONTAINER}" 2>/dev/null)
#if [ "${RUNNING}" = "true" ] && \
#   docker exec "${CONTAINER}" ps -ef 2>/dev/null | grep -q '[a]gent-app-linux-x86'; then
#    warn "agent-app-linux-x86 (PID 1) 감지. 포트 15034 점유 중."
#    info "idle 컨테이너로 재기동 중... (am 일시 중단 후 재생성)"
#    docker stop "${CONTAINER}" >/dev/null || { fail "docker stop 실패"; exit 1; }
#    docker rm   "${CONTAINER}" >/dev/null || { fail "docker rm 실패";   exit 1; }
#    docker run -d --cap-add=NET_ADMIN --name "${CONTAINER}" "${IMAGE}" sleep infinity \
#        >/dev/null || { fail "컨테이너 재기동 실패"; exit 1; }
#    ok "idle 컨테이너 기동 완료 (sleep infinity, 포트 15034 미점유)"
#else
#    ok "컨테이너 이미 idle 상태"
#fi

# 2. 자산 주입
info "자산 주입 중..."

docker cp "${LEAK_BIN}"   "${CONTAINER}:${LEAK_DST}"   || { fail "agent-app-leak cp 실패"; exit 1; }
docker cp "${VERIFY_SRC}" "${CONTAINER}:${VERIFY_DST}" || { fail "verify.sh cp 실패";      exit 1; }
docker exec -u root "${CONTAINER}" chown agent-admin:agent-core "${LEAK_DST}" \
    || { fail "chown 실패"; exit 1; }
docker exec -u root "${CONTAINER}" chmod 750 "${LEAK_DST}"  || { fail "chmod 750 실패"; exit 1; }
docker exec -u root "${CONTAINER}" chmod +x  "${VERIFY_DST}" || { fail "chmod +x 실패";  exit 1; }

ok "자산 주입 완료"
echo "    컨테이너 내 경로: ${LEAK_DST}"
echo "    컨테이너 내 경로: ${VERIFY_DST}"
#
## 3. 메뉴 루프
#while true; do
#    echo
#    echo -e "${BOLD}══════════════════════════════════════════${NC}"
#    echo -e "${BOLD}  검증 메뉴${NC}"
#    echo    "  1) 자동 검증 (전체 시나리오)"
#    echo    "  2) 수동 검증 (단계별 실행)"
#    echo    "  3) 종료"
#    echo -e "${BOLD}══════════════════════════════════════════${NC}"
#    echo -ne "  선택 [1-3]: "
#    read -r choice
#
#    case "$choice" in
#        1) auto_verify   ;;
#        2) manual_verify ;;
#        3) echo; info "종료."; break ;;
#        *) warn "1, 2, 3 중 선택하세요." ;;
#    esac
#done
