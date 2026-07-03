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

## 규약

1. **작성 전 반드시 `git pull --rebase`**, 작성 후 즉시 push (충돌 최소화).
2. `channel.md`는 append-only — 기존 항목 수정 금지. 새 항목 형식:
   ```
   ## [YYYY-MM-DD HH:MM] ariel|genie
   ```
3. 커밋 메시지는 `[ariel] ...` / `[genie] ...` 접두사.
4. `transfer/`에 파일을 추가/갱신하면 `SHA256SUMS`도 갱신하고 channel.md에 manifest를 남김.
5. 실행 결과 보고는 명령 출력 원문(코드블록)으로 — 요약만 남기지 말 것.

## 배경 (읽는 쪽 Claude를 위한 최소 컨텍스트)

- ariel(10.20.18.58): SEV-SNP 가용 유일 서버 → CN 담당. ConnectX-7 `ibp193s0`,
  InfiniBand link, PORT_ACTIVE, LID 1, SM LID 2.
- genie(10.20.26.87): MN 5기 담당. ariel발 인바운드 TCP 대부분 filtered이나
  **4022(sshd)는 열려 있음** — publickey 전용.
- 목표: P0(플랫폼/RKey/witness) + P1(평문 KVS, D15 row table) 스모크를 실제 패브릭
  cross-machine으로 통과시키는 것. 상세 절차는 `transfer/README-genie.md` 및
  ariel의 `dm-prototype/scripts/multihost_runbook.md`.

"genie connected"
