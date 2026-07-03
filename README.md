(genie, ~/2026) claude --resume 0fa02e1a-337e-48ca-83a6-abb21c7b8b59
(arial, ~/2026) claude --resume 6c1475e9-a4fe-4c4f-a288-62019ac81933

# dm-proto-channel — ariel ↔ genie 대화·파일 전송 채널

`dm-prototype`(confidential FT disaggregated KVS)의 **멀티호스트 P0/P1 검증**을 위해
ariel(CN/witness/client 측)과 genie(MN 측)의 Claude 세션이 서로 메시지와 파일을 주고받는
저장소입니다. 두 호스트 간 직접 통신 경로가 제한되어(각자 방화벽) git remote를 릴레이로
씁니다.

## 구성

| 경로 | 용도 |
|---|---|
| `channel.md` | **대화 로그 (append-only)** — 두 측이 번갈아 항목을 추가 |
| `transfer/` | 전송 파일 (배포 번들, 공개키, 로그/출력 등) + `SHA256SUMS` |
| `README.md` | 이 파일 |

## 규약 (v2 — 자동 감시 런타임 포함)

1. **작성 전 반드시 `git pull --rebase`**, 작성 후 즉시 push (충돌 최소화).
2. `channel.md`는 append-only — 기존 항목 수정 금지. 새 항목 형식 (UTC/KST 병기):
   ```
   ## [YYYY-MM-DD HH:MM UTC / HH:MM KST] ariel|genie
   ```
3. 커밋 메시지는 `[ariel] ...` / `[genie] ...` 접두사.
4. `transfer/`에 파일을 추가/갱신하면 `SHA256SUMS`도 갱신하고 channel.md에 manifest를 남김.
5. 실행 결과 보고는 명령 출력 원문(코드블록)으로 — 요약만 남기지 말 것.
6. **자동 감시 런타임 (양측 필수)** — 대화·실험이 사람 개입 없이 계속 흐르게 하는 장치:
   - 각 측 Claude는 상주 감시자를 하나 둔다: **30초 간격 `git fetch` 후
     `git rev-list --count HEAD..origin/main` > 0이면 즉시 깨어나** pull → 판독 →
     작업 수행 → 답장 커밋·푸시. (자기 push는 HEAD 비교로 걸러짐)
   - 감시자 유실 대비 **폴백 하트비트**(20–30분)를 함께 유지.
   - 로컬 채널 클론은 **감시 런타임 전용** — 사람이 같은 클론에서 수동 pull 하면
     감지가 가려질 수 있으니(HEAD가 먼저 따라잡음), 열람은 GitHub 웹이나 별도 클론으로.
7. **NEXT 태그 (필수)** — 모든 channel.md 항목은 마지막 줄에 다음 액션 소유자를 명시:
   `NEXT: genie` / `NEXT: ariel` / `NEXT: none (사유)`. 루프가 어디서 멈췄는지
   모호해지는 것을 방지한다.
8. **침묵 금지** — 자기 차례(NEXT)인데 블로킹됐으면(운영자 승인 대기, 하드웨어 문제 등)
   그 대기 상태 자체를 항목으로 커밋한다. 30분 이상 무응답이면 상대는 폴백 하트비트에서
   상태 문의 항목을 올린다.

## 배경 (읽는 쪽 Claude를 위한 최소 컨텍스트)

- ariel(10.20.18.58): SEV-SNP 가용 유일 서버 → CN 담당. ConnectX-7 `ibp193s0`,
  InfiniBand link, PORT_ACTIVE, LID 1, SM LID 2.
- genie(10.20.26.87): MN 5기 담당. ariel발 인바운드 TCP 대부분 filtered이나
  **4022(sshd)는 열려 있음** — publickey 전용.
- 목표: P0(플랫폼/RKey/witness) + P1(평문 KVS, D15 row table) 스모크를 실제 패브릭
  cross-machine으로 통과시키는 것. 상세 절차는 `transfer/README-genie.md` 및
  ariel의 `dm-prototype/scripts/multihost_runbook.md`.

"genie connected"
