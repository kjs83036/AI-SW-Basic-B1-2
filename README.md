# 리눅스 프로세스 및 시스템 리소스 트러블슈팅 (b2)

## 개요

제공 바이너리 `agent-app-leak` 이 일으키는 3대 시스템 장애
— 메모리 누수/OOM, CPU 과점유, 교착상태(Deadlock) — 를 격리된 Docker 환경에서
재현·진단하고 GitHub Issue 형태의 트러블슈팅 리포트로 정리한다(PDF §2~§4, §8).
추가로, 작성한 리포트의 증거(Evidence)가 실제 동작과 일치하는지를
수동(`MANUAL_VERIFICATION.md`)** 두 방식으로 검증한다.
B1-1과 이어지는 과제이며 필요한 파일은 해당 저장소에서 볼수 있다.

## 사전 준비 (빌드 컨텍스트)

`Dockerfile` 은 빌드 컨텍스트(이 폴더)에서 다음 파일을 필요로 한다.

- `agent-app-leak` — 제공 ELF 바이너리 (원본 파일명 그대로, 이름변경 불필요)
- `monitor.sh` — 첨부 관제 스크립트 (`APP_NAME=agent-app-leak`)
- `verify2.sh` - 자동 검증
- `b-2.sh` - agent-app-leak, verify2.sh 자동 카피


## 실행 방법


```bash
# 1) 이미지 빌드
docker build --platform=linux/amd64 -t agent-monitor .

# 2) 풀 기동 (sshd/cron/ufw + monitor.sh 매분 + 앱 정상 실행)
docker run -d --platform=linux/amd64 --name agent-minitor am start-entrypoint

## 검증 방법

```bash
# [자동] 3개 리포트 증거를 한 번에 검증 (앱 미기동 컨테이너에서)
docker run --rm --platform=linux/amd64 am /usr/local/bin/verify2.sh
# 단일 시나리오: ... agent-app:b2 /usr/local/bin/verify2.sh memory | cpu | deadlock

# [수동] MANUAL_VERIFICATION.md 의 0~3절 절차를 한 줄씩 직접 실행
```

## 파일

- `verify2.sh` — 자동 검증 (3개 장애 시나리오 재현 → 증거 신호 PASS/FAIL)
- `MANUAL_VERIFICATION.md` — 수동 검증 가이드
- `issue_01_memory_leak.md` — 메모리 누수 트러블슈팅 리포트
- `issue_02_cpu_spike.md` — CPU 과점유 트러블슈팅 리포트
- `issue_03_deadlock.md` — 교착상태 트러블슈팅 리포트
- `architecture.md` — 전체 구조도 (mermaid)
- `EXPLANATION.md` — 코드리뷰 수준 통합 설명 + 제약-코드 매핑
- `README.md` — 본 문서

## 결과 요약

- 3대 장애를 Docker 환경에서 실측 재현하고 GitHub Issue 4단 구조 리포트 3건 작성.
- `verify2.sh` 자동 검증 실측: **PASS=3 / FAIL=0** — 모든 리포트 증거가 실제 동작과 일치.
  - 메모리: `Memory limit exceeded (275MB >= 256MB)` → SIGKILL 자가종료
  - CPU: `CPU Threshold Violated! (53.67%)` → SIGTERM 강제종료
  - 교착: `POTENTIAL DEADLOCK` + `Status: BLOCKED` → 프로세스 생존 채 정지
- 선택과제(PDF §5 스케줄링 알고리즘 추론)는 미수행.
