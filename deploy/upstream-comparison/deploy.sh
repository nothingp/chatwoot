#!/usr/bin/env bash
#
# 把 upstream-comparison 实例更新到 GHCR 上的镜像。
#
# 镜像是 .github/workflows/publish_fork_image.yml 从 develop 构建并推送的。所以完整流程是：
#
#   本地改代码  →  git push origin develop  →  等 Actions 构建完（几分钟）
#                                            →  ./deploy.sh  （本脚本）
#
# 用法:
#   ./deploy.sh                # 拉 :develop 最新并重建
#   ./deploy.sh sha-1a2b3c4    # 先换到这个 tag（写回服务器上的 compose），再重建
#   ./deploy.sh --status       # 只看当前跑的镜像版本，不改任何东西
#
# 环境变量:
#   UPSTREAM_HOST   ssh 目标，默认 ubuntu@32.236.75.213
#
set -euo pipefail

HOST="${UPSTREAM_HOST:-ubuntu@32.236.75.213}"
REMOTE_DIR=/opt/chatwoot-upstream

case "${1:-}" in
  -h|--help)
    sed -n '3,16p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

# docker compose 要 sudo：.env 是 root:root 600，普通用户读不到 POSTGRES_PASSWORD
if [ "${1:-}" = "--status" ]; then
  echo "→ $HOST 上当前跑的镜像"
  ssh "$HOST" "cd $REMOTE_DIR && sudo -n docker compose ps --format '{{.Service}}\t{{.Image}}\t{{.Status}}'"
  ssh "$HOST" "cd $REMOTE_DIR && sudo -n docker compose images --format '{{.Service}}\t{{.Repository}}:{{.Tag}}\t{{.ID}}' | head -3"
  exit 0
fi

TAG="${1:-}"
if [ -n "$TAG" ]; then
  echo "→ 把 compose 里的镜像 tag 改成 $TAG"
  ssh "$HOST" "cd $REMOTE_DIR && sed -i 's|^\(  image: ghcr.io/nothingp/chatwoot:\).*|\1$TAG|' docker-compose.yml && grep -m1 'image: ghcr.io' docker-compose.yml"
fi

echo "→ 拉取镜像"
if ! ssh "$HOST" "cd $REMOTE_DIR && sudo -n docker compose pull"; then
  echo
  echo "✗ 拉取失败。如果报 unauthorized，说明 GHCR 上的包还是私有的，二选一：" >&2
  echo "  1) 到 GitHub → Packages → chatwoot → Package settings 把可见性改成 Public" >&2
  echo "  2) 在服务器上登录：echo \$GITHUB_PAT | sudo docker login ghcr.io -u nothingp --password-stdin" >&2
  exit 1
fi

echo "→ 重建容器"
ssh "$HOST" "cd $REMOTE_DIR && sudo -n docker compose up -d"

echo "→ 等待启动"
sleep 25
ssh "$HOST" "
  cd $REMOTE_DIR
  sudo -n docker compose ps --format '{{.Service}}\t{{.Status}}' | grep -v ' redis\| postgres'
  echo -n '站点 HTTP: '
  curl -s -o /dev/null -m 20 -w '%{http_code}\n' http://127.0.0.1:81/
"

echo "✓ 完成"
