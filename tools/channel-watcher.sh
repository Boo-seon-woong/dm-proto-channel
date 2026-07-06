#!/usr/bin/env bash
# dm-proto-channel watcher (규약 v3.1 Rule 3) — OS-레벨 커밋 감지, Claude 세션과 독립.
#
# 설치 (양측 필수, 1회):
#   mkdir -p ~/.local/state/dm-proto-channel
#   crontab -e →
#   * * * * * SELF=<ariel|genie> flock -n $HOME/.local/state/dm-proto-channel/watch.lock $HOME/2026/dm-proto-channel/tools/channel-watcher.sh >> $HOME/.local/state/dm-proto-channel/cron.log 2>&1
#
# cron이 매분 재기동을 보장한다(flock 싱글턴). 경로가 다른 호스트는 crontab 라인에서
# CHANNEL/CLAUDE_BIN/WORKDIR 환경변수를 덮어쓴다.
# 이 watcher의 중단·수정은 admin 전용이다 (v3.1 Rule 3 — 세션의 자의적 중단 절대 금지).
set -u
CHANNEL="${CHANNEL:-$HOME/2026/dm-proto-channel}"
STATE="${STATE:-$HOME/.local/state/dm-proto-channel}"
SELF="${SELF:?set SELF=ariel|genie in crontab}"
WORKDIR="${WORKDIR:-$HOME/2026}"                      # 역할 세션의 cwd (claude --resume는 cwd 기준으로 세션을 찾음)
CLAUDE_BIN="${CLAUDE_BIN:-$HOME/.local/bin/claude}"
FETCH_INTERVAL=30      # 초
WAKE_GRACE=180         # fast path(상주 세션)에 양보하는 시간(초)
WAKE_COOLDOWN=600      # headless 재시도 간격(초) — limit 중에도 이 간격으로 무한 재시도

mkdir -p "$STATE"
log() { echo "[$(date -u '+%F %T UTC')] $*" >> "$STATE/watcher.log"; }
rotate() { # 로그 1MB 초과 시 뒤 100KB만 유지
  for f in watcher.log headless.log cron.log; do
    [ -f "$STATE/$f" ] && [ "$(stat -c%s "$STATE/$f")" -gt 1000000 ] \
      && { tail -c 100000 "$STATE/$f" > "$STATE/$f.tmp" && mv "$STATE/$f.tmp" "$STATE/$f"; }
  done
}

deliver_headless() {
  local tip="$1" handled="$2" sid now last new_sid
  sid=$(cat "$STATE/session_id" 2>/dev/null) || { log "headless skip: no session_id"; return; }
  now=$(date +%s); last=$(cat "$STATE/last_headless" 2>/dev/null || echo 0)
  [ $((now - last)) -lt "$WAKE_COOLDOWN" ] && return
  echo "$now" > "$STATE/last_headless"
  log "headless wake: resume $sid ($handled..$tip)"
  new_sid=$(cd "$WORKDIR" && timeout 900 "$CLAUDE_BIN" -p --resume "$sid" \
    --allowedTools "Bash(git:*)" "Bash(echo:*)" "Bash(cat:*)" "Bash(date:*)" "Bash(sha256sum:*)" "Read" "Write" "Edit" \
    --output-format json \
    "[dm-proto-channel v3.1 wake] 새 커밋 감지: handled=$handled → origin/main=$tip. 당신은 $SELF 역할이다. $CHANNEL 의 README.md 규약 v3.1 wake 처리 절차를 그대로 수행하라: (1) $STATE/handled_head 가 이미 $tip 이면 아무것도 하지 않는다. (2) git pull --rebase 후 $handled..$tip 의 channel.md 새 항목을 전부 판독한다. (3) [admin] 항목은 최우선 이행하고, 최신 항목의 NEXT가 $SELF 면 규약대로 답장 항목을 작성해 [$SELF] 접두사로 커밋·푸시한다. 아니면 판독만 한다. (4) 처리 완료 후 $STATE/handled_head 에 처리 시점의 origin/main sha를 기록한다. 단일 대화 흐름(Rule 4)을 준수하라." \
    2>>"$STATE/headless.log" | python3 -c 'import json,sys
d=json.load(sys.stdin)
print(d.get("session_id",""))
sys.stderr.write("result: %s\n" % str(d.get("result",""))[:2000])' 2>>"$STATE/headless.log")
  if [ -n "$new_sid" ]; then
    echo "$new_sid" > "$STATE/session_id"   # 포크 체인 유지 — 다음 wake는 직전 wake의 기억을 이어받음
    log "headless done: new session_id=$new_sid"
  else
    log "headless failed (limit/오류 가능) — ${WAKE_COOLDOWN}s 후 재시도"
  fi
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
    fi
  else
    log "fetch failed"
  fi
  sleep "$FETCH_INTERVAL"
done
