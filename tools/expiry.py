"""expiry.py -- print when the WatchStep signing expires. ASCII only.
Parses `pymobiledevice3 provision list` line by line: within one profile block
the "ExpirationDate" line comes immediately before its "Name" line, so we hold
the last ExpirationDate seen and pair it with the next watchstep Name.
Output (one line, machine readable):
  EXPIRE_UTC=<iso> EXPIRE_LOCAL=<iso> DAYS=<float> PROFILES=<n>
On failure prints FAIL <reason> and exits 1.
After a reinstall DAYS should jump to ~7. If it does not, iLoader reused the
old profile and the clock did NOT restart.
"""
import datetime
import os
import re
import subprocess
import sys

PYM = (r"C:\Users\Administrator\AppData\Local\Programs\Python\Python312"
       r"\Scripts\pymobiledevice3.exe")
EXP_RX = re.compile(r'"ExpirationDate":\s*"?(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2})')
NAME_KEY = '"Name": "iOS Team Provisioning Profile: top.webchangming.watchstep'


def main():
    if not os.path.exists(PYM):
        print("FAIL pymobiledevice3 not found")
        return 1
    try:
        out = subprocess.run([PYM, "provision", "list"],
                             capture_output=True, timeout=240)
    except Exception as e:  # noqa: BLE001
        print("FAIL run error: %s" % e)
        return 1
    text = (out.stdout or b"").decode("utf-8", "replace")
    if not text.strip():
        err = (out.stderr or b"").decode("utf-8", "replace")[:200]
        print("FAIL empty output: %s" % err)
        return 1

    last_exp = None
    best = None
    count = 0
    for line in text.splitlines():
        m = EXP_RX.search(line)
        if m:
            last_exp = m.group(1)
            continue
        if NAME_KEY in line and last_exp:
            count += 1
            d = datetime.datetime.strptime(last_exp, "%Y-%m-%dT%H:%M:%S")
            if best is None or d > best:
                best = d
    if best is None:
        print("FAIL no watchstep profile found")
        return 1

    now_utc = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    days = round((best - now_utc).total_seconds() / 86400.0, 1)
    local = best + datetime.timedelta(hours=8)
    print("EXPIRE_UTC=%s EXPIRE_LOCAL=%s DAYS=%s PROFILES=%d" % (
        best.strftime("%Y-%m-%dT%H:%M:%SZ"),
        local.strftime("%Y-%m-%dT%H:%M"),
        days, count))
    return 0


if __name__ == "__main__":
    sys.exit(main())
