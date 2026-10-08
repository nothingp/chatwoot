#!/usr/bin/env bash
#
# 从本仓库工作树在目标服务器上原生构建镜像并部署 —— 不推 registry、不依赖 CI、不 push。
#
# 为什么在服务器上构建而不是本机：服务器是 x86_64，本机是 arm64。在本机构建要 QEMU
# 模拟 x86_64，Chatwoot 这种体量的镜像会慢到不可用。这里用 `DOCKER_HOST=ssh://`
# 把本地目录当构建上下文、交给服务器的 docker daemon 原生构建 —— 镜像直接落在
# 服务器的 image store 里，不需要经过任何 registry。
#
# ⚠️ 构建大约 20–40 分钟（4 核），期间会跑 bundle install + pnpm install +
#    assets precompile，吃 CPU 和内存（NODE_OPTIONS 给 vite 留了 4G）。这台机器上
#    同时跑着生产客服栈，构建时盯一眼 `free -h`。
#
# 用法:
#   ./deploy.sh                 # 构建 + 部署（tag = 短 SHA，工作区脏则加 -dirty）
#   ./deploy.sh --build-only    # 只构建，不部署
#   ./deploy.sh --status        # 只看服务器上现在跑的是哪个镜像
#   ./deploy.sh --tag <tag>     # 切到一个已经构建好的 tag，不重新构建
#
# 环境变量:
#   UPSTREAM_HOST   ssh 目标，默认 ubuntu@32.236.75.213
#
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOST="${UPSTREAM_HOST:-ubuntu@32.236.75.213}"
REMOTE_DIR=/opt/chatwoot-upstream
IMAGE_REPO=chatwoot-upstream

case "${1:-}" in
  -h|--help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# docker compose 要 sudo：.env 是 root:root 600，普通用户读不到 POSTGRES_PASSWORD
remote_compose() { ssh "$HOST" "cd $REMOTE_DIR && sudo -n docker compose $*"; }
set_image_tag() {
  ssh "$HOST" "cd $REMOTE_DIR && sed -i 's|^\(  image: $IMAGE_REPO:\).*|\1$1|' docker-compose.yml && grep -m1 'image: $IMAGE_REPO:' docker-compose.yml"
}

if [ "${1:-}" = "--status" ]; then
  echo "→ $HOST 上当前跑的镜像"
  remote_compose "ps --format '{{.Service}}\t{{.Image}}\t{{.Status}}'"
  echo
  echo "→ 服务器上已有的 $IMAGE_REPO 镜像（最近的 5 个）"
  ssh "$HOST" "docker images $IMAGE_REPO --format '{{.Tag}}\t{{.CreatedSince}}\t{{.Size}}' | head -5"
  exit 0
fi

if [ "${1:-}" = "--tag" ]; then
  TAG="${2:?--tag 需要一个 tag}"
  echo "→ 切到已构建的 tag：$TAG"
  set_image_tag "$TAG"
  remote_compose "up -d"
  exit 0
fi

# 镜像 tag 用当前 commit，工作区有改动就标 -dirty —— 这样"线上跑的到底是哪份代码"可查
SHA="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
if ! git -C "$REPO_DIR" diff --quiet || ! git -C "$REPO_DIR" diff --cached --quiet; then
  SHA="$SHA-dirty"
fi
TAG="$SHA"
IMAGE="$IMAGE_REPO:$TAG"

echo "→ 在 ${HOST} 上构建 ${IMAGE}（上下文：${REPO_DIR}）"
echo "  预计 20–40 分钟，没有缓存会更久"
echo
DOCKER_HOST="ssh://$HOST" docker build \
  -f "$REPO_DIR/docker/Dockerfile" \
  -t "$IMAGE" \
  "$REPO_DIR"

echo
echo "✓ 构建完成：$IMAGE"

if [ "${1:-}" = "--build-only" ]; then
  echo "  （--build-only，未部署）"
  exit 0
fi

echo "→ 把 compose 指到 $TAG"
set_image_tag "$TAG"

echo "→ 重建容器"
remote_compose "up -d" 2>&1 | grep -vE "^\s*$" | tail -8

echo "→ 等待启动"
sleep 25
ssh "$HOST" "
  cd $REMOTE_DIR
  sudo -n docker compose ps --format '{{.Service}}\t{{.Image}}\t{{.Status}}' | grep -vE 'redis|postgres'
  echo -n '站点 HTTP: '
  curl -s -o /dev/null -m 20 -w '%{http_code}\n' http://127.0.0.1:81/
"

echo "✓ 完成"
