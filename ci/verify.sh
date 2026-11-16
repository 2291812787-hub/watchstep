#!/bin/sh
set -e
cd /var/minis/shared/watchstep
export GIT_SSH_COMMAND="ssh -i /root/.ssh/watchstep_deploy -o StrictHostKeyChecking=no -p 443"
git fetch origin ci-build:ci-build --force -q
git show ci-build:WatchStep.ipa > /var/minis/attachments/WatchStep.ipa
rm -rf /tmp/ic && mkdir -p /tmp/ic
cd /tmp/ic
unzip -q /var/minis/attachments/WatchStep.ipa
echo "=== IPA size: $(ls -l /var/minis/attachments/WatchStep.ipa | awk '{print $5}')"
echo "=== 树"
find . -maxdepth 4 -name '*.app' -o -maxdepth 4 -name 'Watch' | sort
echo "=== 手表 keys"
python3 - <<'PY'
import plistlib
p='Payload/WatchStep.app/Watch/WatchStepWatch.app/Info.plist'
d=plistlib.load(open(p,'rb'))
for k in ['CFBundleIdentifier','CFBundleDisplayName','WKWatchOnly','WKBackgroundModes','NSMotionUsageDescription','MinimumOSVersion','UIDeviceFamily']:
    print(' ',k,'=',d.get(k))
PY
echo "=== 二进制架构"
python3 - <<'PY'
import struct
f='Payload/WatchStep.app/Watch/WatchStepWatch.app/WatchStepWatch'
b=open(f,'rb').read(0x1000)
magic=struct.unpack('>I',b[:4])[0]
print('magic=%x'%magic)
off=32 if magic in (0xfeedfacf,0xcffaedfe) else 28
ncmds=struct.unpack('<I',b[16:20])[0]
print('ncmds',ncmds)
PY
echo "=== entitlements/签名"
ls -a Payload/WatchStep.app/Watch/WatchStepWatch.app/ | grep -i "_CodeSignature\|embedded" || echo "无签名（未签名包，正常）"
