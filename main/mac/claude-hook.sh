#!/bin/sh
# Claude Code hook → Mercy. Installed into ~/.claude/settings.json by
# main/claude/hooks.js:
#
#   claude-hook.sh <bridge file>              any event (runs async)
#   claude-hook.sh <bridge file> permission   PermissionRequest: prints Mercy's decision
#
# Never gets in Claude's way: if Mercy isn't running or doesn't answer, it
# prints nothing and exits 0, and Claude carries on as usual.
{ read -r PORT TOKEN < "$1"; } 2>/dev/null || exit 0

# Claude's terminal, so Mercy can type into the right tab.
pid=$PPID
tty=
for _ in 1 2 3 4; do
  tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
  case "$tty" in ttys*) break ;; esac
  tty=
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -z "$pid" ] || [ "$pid" -le 1 ] && break
done

if [ "$2" = permission ]; then route=permission; wait=55; else route=event; wait=2; fi
curl -s --max-time "$wait" \
  -H "Authorization: Bearer $TOKEN" -H "X-Claude-TTY: $tty" -H "Content-Type: application/json" \
  --data-binary @- "http://127.0.0.1:$PORT/$route" 2>/dev/null
exit 0
