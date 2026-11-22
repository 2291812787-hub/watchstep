#!/bin/sh
# check_expiry.sh -- one line answer: is the WatchStep signing still alive?
#
#   EXPIRE_UTC=… EXPIRE_LOCAL=… DAYS=… PROFILES=… NOTIFY=yes|no SOURCE=live
#   EXPIRE_UTC=… EXPIRE_LOCAL=… DAYS=… PROFILES=-1 NOTIFY=… SOURCE=cache STALE=1
#   FAIL=<reason>
#
# NOTIFY=yes only when the signature has expired AND nothing was sent in the
# last 3 days, so an ignored install does not nag every single day.
# The live date comes from the Windows PC. The expiry only ever moves forward
# when a NEW profile is signed, so the cached date is a safe fallback.

HOST=Administrator@192.168.31.82
KEY=$HOME/.ssh/id_ed25519
HERE=$(dirname "$0")
CACHE="$HERE/../expires.txt"
STATE="$HERE/../expiry_notify.txt"
LOCAL_PY="$HERE/expiry.py"
REMOTE_PY='C:\Users\Public\expiry.py'
WINPY='C:\Users\Administrator\AppData\Local\Programs\Python\Python312\python.exe'
SSH="ssh -i $KEY -o StrictHostKeyChecking=no -o BatchMode=yes -o ConnectTimeout=12"

run_remote() { $SSH "$HOST" "$WINPY $REMOTE_PY" 2>&1 | tr -d '\r'; }

# $1 = utc iso -> "DAYS EXPIRE_LOCAL NOTIFY"; also updates the nag-streak state
calc() {
    python3 - "$1" "$STATE" << 'PY'
import sys, os, datetime
s = sys.argv[1].rstrip('Z')
state = sys.argv[2]
d = datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%S")
now = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
days = round((d - now).total_seconds() / 86400.0, 1)
local = (d + datetime.timedelta(hours=8)).strftime("%Y-%m-%dT%H:%M")
notify = "no"
if days <= 0:
    last = None
    if os.path.exists(state):
        try:
            last = datetime.date.fromisoformat(open(state).read().strip())
        except Exception:
            last = None
    today = now.date()
    if last is None or (today - last).days >= 3:
        notify = "yes"
        try:
            open(state, "w").write(today.isoformat())
        except Exception:
            pass
else:
    if os.path.exists(state):
        try:
            os.remove(state)
        except Exception:
            pass
print("%s %s %s" % (days, local, notify))
PY
}

emit() {
    # $1 = "EXPIRE_UTC=..." fragment, $2 = PROFILES value, $3 = SOURCE, $4 = "1" if stale
    utc=$(echo "$1" | sed -n 's/.*EXPIRE_UTC=\([^ ]*\).*/\1/p')
    [ -z "$utc" ] && return 1
    echo "EXPIRE_UTC=$utc" > "$CACHE"
    c=$(calc "$utc")
    days=$(echo "$c" | cut -d' ' -f1)
    loc=$(echo "$c" | cut -d' ' -f2)
    nfy=$(echo "$c" | cut -d' ' -f3)
    line="EXPIRE_UTC=$utc EXPIRE_LOCAL=$loc DAYS=$days PROFILES=$2 NOTIFY=$nfy SOURCE=$3"
    [ -n "$4" ] && line="$line STALE=1"
    echo "$line"
}

out=$(run_remote)

case "$out" in
    *EXPIRE_UTC=*)
        frag=$(echo "$out" | grep -E 'EXPIRE_UTC=' | head -1)
        prof=$(echo "$frag" | sed -n 's/.*PROFILES=\([0-9-]*\).*/\1/p')
        emit "$frag" "${prof:--1}" live ""
        exit 0
        ;;
    *"can't open file"*|*"No such file"*)
        if [ -f "$LOCAL_PY" ]; then
            ( cd "$HERE" && scp -i "$KEY" -o StrictHostKeyChecking=no \
                -o BatchMode=yes -o ConnectTimeout=12 expiry.py \
                "Administrator@192.168.31.82:C:/Users/Public/expiry.py" >/dev/null 2>&1 )
            out=$(run_remote)
            case "$out" in
                *EXPIRE_UTC=*)
                    frag=$(echo "$out" | grep -E 'EXPIRE_UTC=' | head -1)
                    prof=$(echo "$frag" | sed -n 's/.*PROFILES=\([0-9-]*\).*/\1/p')
                    emit "$frag" "${prof:--1}" live ""
                    exit 0
                    ;;
            esac
        fi
        ;;
esac

# live lookup failed -- fall back to the last known date
if [ -f "$CACHE" ]; then
    utc=$(sed -n 's/.*EXPIRE_UTC=\([^ ]*\).*/\1/p' "$CACHE" | head -1)
    if [ -n "$utc" ]; then
        emit "EXPIRE_UTC=$utc" -1 cache 1
        exit 0
    fi
fi

reason=$(echo "$out" | grep -viE 'deprecation|now_utc' | tail -2 | tr '\n' ' ')
echo "FAIL=${reason:-no output from PC, no cached date}"
exit 1
