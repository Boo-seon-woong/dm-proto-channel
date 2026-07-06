# genie MN bundle — 배포 절차

ariel(10.20.18.58, CN/witness/client)과 함께 dm-prototype의 P0/P1 멀티호스트 검증을 돌리기
위한 genie 측 Memory Node(5×`mnd`) 번들. MN은 **비신뢰 수동 데몬**입니다: 개인키 없음,
바깥으로 다이얼하지 않음, TCP 리스너(QP 부트스트랩) + RDMA 응답자 역할만 합니다.

## 번들 내용

| file | 설명 |
|---|---|
| `mnd` | MN 데몬 (ariel에서 빌드된 x86_64 바이너리; `libibverbs` 동적 링크) |
| `genie_mn.sh` | 사전 점검 + 5개 mnd 기동/상태/정지 |
| `cluster.toml` + `.sig` | 서명된 클러스터 구성 (수정 금지 — 수정하면 서명 검증 실패) |
| `op.pub` | operator Ed25519 공개키 (config 서명 검증용) |

## 사전 요구사항 (genie)

1. **rdma-core** 설치 (`ibv_devices`, `libibverbs`): `sudo apt install rdma-core` (또는 배포판 동등 패키지).
2. **IB 포트가 ariel과 같은 패브릭에서 ACTIVE** — `ibv_devinfo`로 `state: PORT_ACTIVE`,
   `link_layer: InfiniBand`, LID 배정 확인. (ariel은 LID 1, SM LID 2인 IB 패브릭.
   genie 포트가 RoCE라면 같은 패브릭이 아니므로 진행 불가 — 먼저 보고.)
3. **memlock**: `ulimit -l`이 region당 2×(region_mb)MiB + 여유보다 커야 함
   (기본 region 2 MiB ⇒ 8 MiB면 충분).
4. **방화벽**: ariel(10.20.18.58)에서 genie로 **TCP 7101–7105 인바운드 허용**.
   (예: `sudo ufw allow from 10.20.18.58 to any port 7101:7105 proto tcp`
   또는 iptables/nft 동등 규칙. 이 5개 포트가 QP 부트스트랩 경로 전부이며,
   genie에서 ariel로 나가는 연결은 없음.)

## 실행

```sh
tar xzf genie-mn-bundle.tar.gz && cd genie-mn
./genie_mn.sh start      # 사전 점검 + 5x mnd 기동 (MN0는 rw-first: NIC 체크)
./genie_mn.sh status
./genie_mn.sh stop
```

- 디바이스명이 config 기본값(`ibp193s0`)과 달라도 됨 — `genie_mn.sh`가 첫 번째 로컬
  디바이스를 자동 선택하며, `DM_RDMA_DEV=<dev> ./genie_mn.sh start`로 명시 가능.
- **테스트 런 사이마다 `stop` 후 `start`로 재기동** (region을 새로 받아 row table이
  깨끗한 상태에서 시작해야 함). ariel 쪽 p0 → p1 연속 실행은 재기동 없이 가능.
- **⚠️ P3 recovery/kill-9 라운드는 예외 — MN 무재기동 유지.** 이 mnd는 KVS row table에
  더해 **per-CN redo-log 링(1024 slots × 80 B/CN)**을 호스팅합니다(기동 배너 참조).
  boot recovery는 CN이 죽는 동안 MN이 살아 로그를 보존해야 성립하므로, recovery 라운드
  중 `stop`/`start`는 로그 링을 wipe해 검증 대상을 파괴합니다. **내구성 경계 = MN 프로세스
  생존**(mnd는 디스크 백킹 없음). clean-region 재기동이 필요할 때만 채널로 명시 요청.

## P3 로그 링 확인 (배포 검증)

로그-링 인식 mnd가 맞는지 기동 배너로 확인:

```
mnd[0]: log ring: 1024 slots/CN x 80 B (80 KiB/CN x 2 CNs), log_base=0x…, log_len=160 KiB
```

이 줄이 안 보이면 구(舊) mnd이며 CN의 `append_log`가 조용히 no-op → recovery 불가.
region 16 MiB는 row table(11000 KiB) + scratch + 로그 링(160 KiB)을 모두 수용합니다.

## 선택: 스택에 앞서 raw RDMA 확인 (perftest 설치 시)

```sh
genie$ ib_read_bw -d <dev> --report_gbits          # 서버 (포트 18515 개방 필요)
ariel$ ib_read_bw -d ibp193s0 <genie-ip> --report_gbits
```

## 문제 발생 시 확인 순서

1. `mn*.log` — mnd가 뱉은 에러 (device open 실패 / bind 실패 / memlock).
2. `ibv_devinfo` — 포트 상태·LID. LID 0이면 SM 미도달.
3. ariel에서 `nc -vz <genie-ip> 7101` — 방화벽.
