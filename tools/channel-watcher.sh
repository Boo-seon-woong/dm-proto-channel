#!/usr/bin/env bash
# dm-proto-channel watcher (규약 v3.2 Rule 3) — OS-레벨 커밋 감지와 STATUS 하트비트.
#
# 설치 (양측 필수, 1회):
#   mkdir -p ~/.local/state/dm-proto-channel
#   crontab -e →
#   * * * * * SELF=<ariel|genie> flock -n $HOME/.local/state/dm-proto-channel/watch.lock $HOME/2026/dm-proto-channel/tools/channel-watcher.sh >> $HOME/.local/state/dm-proto-channel/cron.log 2>&1
#
# cron이 매분 재기동을 보장한다(flock 싱글턴). 경로가 다른 호스트는 crontab 라인에서
# CHANNEL/CLAUDE_BIN/WORKDIR 환경변수를 덮어쓴다.
# 이 watcher의 중단·수정은 admin 전용이다 (Rule 3 — 세션의 자의적 중단 절대 금지).
set -u
CHANNEL="${CHANNEL:-$HOME/2026/dm-proto-channel}"
STATE="${STATE:-$HOME/.local/state/dm-proto-channel}"
SELF="${SELF:?set SELF=ariel|genie in crontab}"
WORKDIR="${WORKDIR:-$HOME/2026}"                      # 역할 세션의 cwd (claude --resume는 cwd 기준으로 세션을 찾음)
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
FETCH_INTERVAL=30      # 초
WAKE_GRACE=180         # fast path(상주 세션)에 양보하는 시간(초)
WAKE_COOLDOWN=600      # headless 재시도 간격(초) — limit 중에도 이 간격으로 무한 재시도
HEARTBEAT_INTERVAL=1500 # 초: 25분. Rule 2의 30분 기한 전에 STATUS wake를 시도한다.

mkdir -p "$STATE"
log() { echo "[$(date -u '+%F %T UTC')] $*" >> "$STATE/watcher.log"; }
rotate() { # 로그 1MB 초과 시 뒤 100KB만 유지
  for f in watcher.log headless.log cron.log; do
    [ -f "$STATE/$f" ] && [ "$(stat -c%s "$STATE/$f")" -gt 1000000 ] \
      && { tail -c 100000 "$STATE/$f" > "$STATE/$f.tmp" && mv "$STATE/$f.tmp" "$STATE/$f"; }
  done
}

run_resume() {
  local label="$1" prompt="$2" sid new_sid
  sid=$(cat "$STATE/session_id" 2>/dev/null) || { log "$label skip: no session_id"; return 1; }
  log "$label: resume $sid"
  new_sid=$(cd "$WORKDIR" && timeout 900 "$CLAUDE_BIN" -p --resume "$sid" --fork-session \
    --allowedTools "Bash(git:*)" "Bash(echo:*)" "Bash(cat:*)" "Bash(date:*)" "Bash(sha256sum:*)" "Bash(pgrep:*)" "Bash(ps:*)" "Read" "Write" "Edit" \
    --output-format json \
    "$prompt" \
    2>>"$STATE/headless.log" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("session_id",""))
sys.stderr.write("result: %s\n" % str(d.get("result",""))[:2000])' 2>>"$STATE/headless.log")
  if [ -n "$new_sid" ]; then
    echo "$new_sid" > "$STATE/session_id"   # 포크 체인 유지 — 다음 wake는 직전 wake의 기억을 이어받음
    log "$label done: new session_id=$new_sid"
    return 0
  else
    log "$label failed (limit/오류 가능) — ${WAKE_COOLDOWN}s 후 재시도"
    return 1
  fi
}

deliver_headless() {
  local tip="$1" handled="$2" now last prompt
  now=$(date +%s); last=$(cat "$STATE/last_headless" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$WAKE_COOLDOWN" ] && return
  echo "$now" > "$STATE/last_headless"
  prompt="[dm-proto-channel v3.2 wake] 새 커밋 감지: handled=$handled → origin/main=$tip. 당신은 $SELF 역할이다. $CHANNEL 의 README.md 규약 v3.2 wake 처리 절차를 그대로 수행하라: (1) $STATE/handled_head 가 이미 $tip 이면 아무것도 하지 않는다. (2) git pull --rebase 후 $handled..$tip 의 channel.md 새 항목을 전부 판독한다. (3) [admin] 항목은 최우선 이행하고, 최신 항목의 NEXT가 $SELF 면 규약대로 답장 항목을 작성해 [$SELF] 접두사로 커밋·푸시한다. 아니면 판독만 한다. (4) 처리 완료 후 $STATE/handled_head 에 처리 시점의 origin/main sha를 기록한다. (5) 자기 마지막 커밋이 25분 이상 전이면 Rule 2 형식의 STATUS도 함께 커밋한다. 단일 대화 흐름(Rule 4)을 준수하라."
  run_resume "headless wake ($handled..$tip)" "$prompt"
}

deliver_heartbeat() {
  local tip="$1" now last own_ts age prompt
  own_ts=$(git -C "$CHANNEL" log -1 --format=%ct --grep="^\[$SELF\]" origin/main 2>/dev/null || true)
  case "$own_ts" in ''|*[!0-9]*) return ;; esac
  now=$(date +%s)
  age=$((now - own_ts))
  [ "$age" -lt "$HEARTBEAT_INTERVAL" ] && return
  last=$(cat "$STATE/last_heartbeat" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$WAKE_COOLDOWN" ] && return
  echo "$now" > "$STATE/last_heartbeat"
  prompt="[dm-proto-channel v3.2 heartbeat] Rule 2 STATUS 기한 도래: origin/main=$tip, 마지막 [$SELF] 커밋 age=${age}s. 당신은 $SELF 역할이다. git pull --rebase 후 최신 channel.md를 판독하고, 새 주제를 열지 말고 현재 NEXT/블로커를 유지한 Rule 2 형식 STATUS를 channel.md 끝에 append-only로 작성하라. 감시자 줄에는 $STATE/last_fetch 시각과 channel-watcher PID(pgrep/ps로 확인 가능)를 넣어라. 커밋 메시지는 [$SELF] STATUS: ... 형식으로 하고 즉시 push하라. push가 성공하면 $STATE/handled_head 를 처리 시점 origin/main sha로 갱신하라. 처리 중 [admin] 새 지시가 보이면 최우선 접수하라."
  run_resume "heartbeat wake (age=${age}s, tip=$tip)" "$prompt"
}

log "watcher start (SELF=$SELF, pid $$)"
while true; do
  rotate
  if git -C "$CHANNEL" fetch -q origin 2>>"$STATE/watcher.log"; then
    date -u '+%F %T UTC' > "$STATE/last_fetch"
    TIP=$(git -C "$CHANNEL" rev-parse origin/main 2>/dev/null)
    HANDLED=$(cat "$STATE/handled_head" 2>/dev/null || true)
    if [ -z "$HANDLED" ]; then
      echo "$TIP" > "$STATE/handled_head"; log "init handled_head=$TIP"
    elif [ -n "$TIP" ] && [ "$TIP" != "$HANDLED" ]; then
      if ! RANGE=$(git -C "$CHANNEL" log --format='%s' "$HANDLED..$TIP" 2>/dev/null); then
        log "range error $HANDLED..$TIP — handled_head 재초기화"; echo "$TIP" > "$STATE/handled_head"
      elif [ -z "$(echo "$RANGE" | grep -v "^\[$SELF\]")" ]; then
        echo "$TIP" > "$STATE/handled_head"; rm -f "$STATE/pending_wake"
        log "self-push auto-handled: $TIP"
      else
        if [ "$(cat "$STATE/pending_wake" 2>/dev/null)" != "$TIP" ]; then
          echo "$TIP" > "$STATE/pending_wake"; date +%s > "$STATE/pending_since"
          log "unhandled: $HANDLED..$TIP → pending_wake (fast path 우선)"
        fi
        AGE=$(( $(date +%s) - $(cat "$STATE/pending_since" 2>/dev/null || echo 0) ))
        [ "$AGE" -ge "$WAKE_GRACE" ] && deliver_headless "$TIP" "$HANDLED"
      fi
    else
      rm -f "$STATE/pending_wake"
      deliver_heartbeat "$TIP"
    fi
  else
    log "fetch failed"
  fi
  sleep "$FETCH_INTERVAL"
done
