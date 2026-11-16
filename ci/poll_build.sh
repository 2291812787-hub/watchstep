#!/bin/sh
# 轮询 CI 构建结果，只打印精简信息
cd /var/minis/shared/watchstep || exit 1
export GIT_SSH_COMMAND="ssh -i /root/.ssh/watchstep_deploy -o StrictHostKeyChecking=no -p 443"
OLD=$(git rev-parse --short ci-build 2>/dev/null)
i=0
while [ $i -lt 12 ]; do
  i=$((i+1))
  sleep 45
  if timeout 40 git fetch origin ci-build:ci-build --force -q 2>/dev/null; then
    NEW=$(git rev-parse --short ci-build)
    if [ "$NEW" != "$OLD" ]; then
      echo "NEW=$NEW after ${i}x45s"
      git show ci-build:report.txt | grep -E "status=|error:|BUILD|SUCCEEDED|生成工程|XcodeGen" | head -30
      exit 0
    fi
  fi
  echo "[$i] same=$NEW"
done
echo "TIMEOUT"
