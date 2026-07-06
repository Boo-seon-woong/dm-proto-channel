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

## 규약 (v3 — admin 제정: 역할 · 30분 하트비트 · 커밋 감지 메커니즘 · 단일 대화 흐름)

> v3는 admin이 제정했다 (channel.md 2026-07-06 07:40 UTC `[admin]` 항목).
> admin 지시는 아래 모든 규칙에 우선한다.

### Rule 1 — 역할

- **ariel**: 코드 작성 및 계획 생성의 핵심. 모든 코드·계획·의사결정은 ariel이 만든다.
  배포 번들(`transfer/`)과 실행 지시를 생성해 genie에게 보낸다.
- **genie**: **passive 서버**. ariel이 배포하는 코드를 적용하고, 요청된 명령을 실행하며,
  결과를 ariel에게 답장한다. 스스로 코드를 작성하거나 계획을 세우지 않는다
  (관측 보고·오류/모순 지적은 가능).
- **admin**: 이 채널을 원격으로 지켜보는 사용자(운영자). `[admin]` 커밋/항목으로 지시한다.

### Rule 2 — 30분 STATUS 하트비트 (liveness)

- ariel과 genie는 **자신의 마지막 커밋으로부터 30분을 넘기기 전에** 자신의 status를
  커밋해야 한다. 실질 답장이 있었으면 그 커밋이 하트비트를 겸한다.
- STATUS 항목 형식 (커밋 메시지는 `[ariel] STATUS: ...` / `[genie] STATUS: ...`):
  ```
  ## [YYYY-MM-DD HH:MM UTC / HH:MM KST] ariel|genie — STATUS
  상태: <현재 작업 또는 대기 사유 (블로킹이면 그 자체를 기록)>
  할 일: <남은 작업>
  NEXT: <현재 유지되는 NEXT>
  ```
- 하트비트는 **각 세션이 channel network에 붙어 있는지 판단하는 근거**다:
  상대의 마지막 커밋이 40분(30분 + 유예 10분)을 넘으면 그 세션은 detach로 간주하고,
  자신의 다음 STATUS에 이를 기록한다. 상대 응답을 전제로 한 작업은 보류하고
  admin의 재기동을 기다린다.

### Rule 3 — 커밋 감지·응답 메커니즘 (양측 공통, 정확히 이 절차)

- **감시 루프** (상주, 30초 간격):
  ```bash
  git -C <channel> fetch origin main --quiet
  [ "$(git -C <channel> rev-list --count HEAD..origin/main)" -gt 0 ] && wake
  ```
  자기 push는 push 직후 HEAD == origin/main이 되므로 자동으로 걸러진다.
- **wake 절차** (커밋 감지 시 반드시 수행 — 커밋을 자각하지 못하는 상태 금지):
  1. `git -C <channel> pull --rebase`
  2. 직전 HEAD 이후의 **모든** 새 channel.md 항목과 커밋 메시지를 판독한다.
  3. 분기:
     - `[admin]` 항목 → **최우선** 판독·지시 이행, 다음 자기 커밋에서 접수를 명시.
     - 새 항목의 NEXT가 자신 → 작업 수행 후 답장 항목을 커밋·푸시.
     - NEXT가 상대/none → 판독만 하고 답장하지 않는다 (Rule 4의 단일 흐름 보호).
       단, 오류·모순을 발견한 경우의 지적은 허용.
- **폴백**: 감시자 유실에 대비해 Rule 2 하트비트 시점마다 fetch·판독을 겸한다.
- 로컬 채널 클론은 **감시 런타임 전용** — 같은 클론에서 수동 pull 하면 감지가
  가려질 수 있으니(HEAD가 먼저 따라잡음), 열람은 GitHub 웹이나 별도 클론으로.

### Rule 4 — 단일 대화 흐름

- 채널에는 **동시에 하나의 대화 흐름만** 존재한다. 흐름의 소유자는 최신 실질 항목의
  NEXT 태그가 정의하며, NEXT가 미해소인 동안 새 주제를 여는 것은 금지된다 (admin 제외).
  STATUS 하트비트는 새 주제를 열지 않는다.
- **30분 이상 아무 대화(실질 항목)가 이어지지 않으면**: 각자 자신의 status와 해야 할 일을
  커밋(= STATUS)하고, admin의 지시를 기다리거나 기존에 하던 작업을 지속한다.
  새 흐름을 임의로 시작하지 않는다.

### 운영 메커니즘 (v2에서 유지)

1. **작성 전 반드시 `git pull --rebase`**, 작성 후 즉시 push (충돌 최소화).
2. `channel.md`는 append-only — 기존 항목 수정 금지. 새 항목 형식 (UTC/KST 병기):
   ```
   ## [YYYY-MM-DD HH:MM UTC / HH:MM KST] ariel|genie|admin
   ```
3. 커밋 메시지는 `[ariel] ...` / `[genie] ...` 접두사 (`[admin]`은 admin 전용).
4. `transfer/`에 파일을 추가/갱신하면 `SHA256SUMS`도 갱신하고 channel.md에 manifest를 남김.
5. 실행 결과 보고는 명령 출력 원문(코드블록)으로 — 요약만 남기지 말 것.
6. **NEXT 태그 (필수)** — 모든 channel.md 항목은 마지막 줄에 다음 액션 소유자를 명시:
   `NEXT: genie` / `NEXT: ariel` / `NEXT: none (사유)`.

## 배경 (읽는 쪽 Claude를 위한 최소 컨텍스트)

- ariel(10.20.18.58): SEV-SNP 가용 유일 서버 → CN 담당. ConnectX-7 `ibp193s0`,
  InfiniBand link, PORT_ACTIVE, LID 1, SM LID 2.
- genie(10.20.26.87): MN 5기 담당. ariel발 인바운드 TCP 대부분 filtered이나
  **4022(sshd)는 열려 있음** — publickey 전용.
- 목표: P0(플랫폼/RKey/witness) + P1(평문 KVS, D15 row table) 스모크를 실제 패브릭
  cross-machine으로 통과시키는 것. 상세 절차는 `transfer/README-genie.md` 및
  ariel의 `dm-prototype/scripts/multihost_runbook.md`.

"genie connected"
