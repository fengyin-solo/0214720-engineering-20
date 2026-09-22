#!/usr/bin/env bash
# =============================================================================
# container.sh - 用户端容器运行约束基线（构建 -> 启动 -> 健康检查 -> 停止）
#
# 容器约束（与根目录 docker-compose.yml / Dockerfile 一致）：
#   - 多架构基础镜像：node:20-alpine 构建，nginx:1.25-alpine 运行（amd64/arm64）
#   - 宿主机固定端口 8081 -> 容器内 80；端口被占用直接失败，不换端口
#   - 构建上下文忽略 node_modules/dist（见 .dockerignore），依赖在镜像内按
#     package-lock.json 重新安装，避免宿主席原生模块污染镜像
#   - 内置 HEALTHCHECK，容器未通过健康检查视为失败
#
# 用法:
#   scripts/container.sh up       # 检查端口 -> compose build -> up -d -> 健康检查
#   scripts/container.sh verify   # 仅对已运行容器做健康与页面入口检查
#   scripts/container.sh down     # 停止并移除容器（不残留）
#   scripts/container.sh logs     # 查看容器日志
#
# 可选环境变量:
#   FRONTEND_USER_PORT  覆盖宿主机映射端口（默认 8081）
#
# 退出码: 0 成功 / 2 缺少 docker 或依赖 / 3 端口占用 / 5 镜像构建失败
#         7 容器未通过健康检查 / 6 页面入口检查失败
# =============================================================================
set -uo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

COMPOSE_FILE="$PROJECT_ROOT/../docker-compose.yml"
COMPOSE_SERVICE="frontend-user"
CONTAINER_NAME="billiard-frontend-user"
HOST_PORT="${FRONTEND_USER_PORT:-$CONTAINER_PORT_DEFAULT}"

# 兼容 docker compose v2 与独立的 docker-compose v1
compose() {
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_FILE" "$@"
  elif command -v docker-compose >/dev/null 2>&1; then
    docker-compose -f "$COMPOSE_FILE" "$@"
  else
    die 2 "未找到 docker compose（需 Docker Desktop / Docker Engine + compose 插件）。"
  fi
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die 2 "未找到 docker。容器基线需要可用的 Docker（支持多架构：amd64/arm64）。"
  docker info >/dev/null 2>&1 || die 2 "docker 守护进程不可用，请先启动 Docker（macOS 打开 Docker Desktop；Linux 执行 systemctl start docker）。"
  compose version >/dev/null 2>&1 || die 2 "docker compose 不可用。"
  [ -f "$COMPOSE_FILE" ] || die 2 "未找到根目录 docker-compose.yml：$COMPOSE_FILE"
  ok "Docker 环境可用"
}

container_health() {
  docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$CONTAINER_NAME" 2>/dev/null
}

wait_healthy() {
  local i status
  for i in $(seq 1 30); do
    status="$(container_health)"
    [ "$status" = "healthy" ] && return 0
    if [ "$status" = "unhealthy" ] || [ "$status" = "exited" ] || [ "$status" = "dead" ]; then
      err "容器状态异常: $status，最近日志："
      docker logs --tail 30 "$CONTAINER_NAME" >&2 2>&1 || true
      return 1
    fi
    sleep 2
  done
  err "等待容器健康检查超时（60 秒），最后状态: ${status:-未知}"
  docker logs --tail 30 "$CONTAINER_NAME" >&2 2>&1 || true
  return 1
}

http_smoke() {
  local fail=0 route code
  for route in / /tables /courses /competitions /shop /profile /tasks; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$HOST_PORT$route")"
    if [ "$code" = "200" ]; then ok "  http://localhost:$HOST_PORT$route -> 200"; else err "  $route -> $code"; fail=1; fi
  done
  # 静态资源哈希文件必须可访问
  local asset
  asset="$(curl -s "http://localhost:$HOST_PORT/" | grep -o 'assets/[^"]*\.js' | head -1)"
  if [ -n "$asset" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$HOST_PORT/$asset")" = "200" ]; then
    ok "  /$asset -> 200"
  else
    err "  容器内 JS 资源不可访问: ${asset:-index.html 未引用资源}"
    fail=1
  fi
  return "$fail"
}

cmd_up() {
  check_docker
  # 端口检查放在构建之前：快速失败，避免无意义构建
  ensure_port_free "$HOST_PORT" "容器映射 -> 0.0.0.0:$HOST_PORT:80"

  log "构建镜像（多架构基础镜像 node:20-alpine / nginx:1.25-alpine）..."
  if ! compose build "$COMPOSE_SERVICE"; then
    die 5 "镜像构建失败，请查看上方构建日志。常见原因：依赖安装失败、vite build 失败、网络无法访问 npm registry。"
  fi
  ok "镜像构建成功"

  log "启动容器 $CONTAINER_NAME ..."
  if ! compose up -d "$COMPOSE_SERVICE"; then
    die 7 "容器启动失败，请执行: docker logs $CONTAINER_NAME"
  fi

  if ! wait_healthy; then
    die 7 "容器未通过健康检查，已保留现场以便排查；确认后执行 scripts/container.sh down 清理。"
  fi
  ok "容器健康检查通过"

  if http_smoke; then
    ok "用户端已上线: http://localhost:$HOST_PORT"
  else
    die 6 "容器运行但核心页面入口检查失败，请检查 nginx 配置与构建产物。"
  fi
}

cmd_verify() {
  check_docker
  docker inspect "$CONTAINER_NAME" >/dev/null 2>&1 || die 7 "容器 $CONTAINER_NAME 未运行，请先执行 scripts/container.sh up"
  wait_healthy || die 7 "容器未通过健康检查。"
  http_smoke || die 6 "页面入口检查失败。"
  ok "容器基线验证全部通过"
}

cmd_down() {
  check_docker
  compose down --remove-orphans
  ok "已停止并移除容器（数据为前端 Mock，无持久化卷需要清理）"
}

cmd_logs() {
  check_docker
  docker logs -f "$CONTAINER_NAME"
}

case "${1:-}" in
  up)     cmd_up ;;
  verify) cmd_verify ;;
  down)   cmd_down ;;
  logs)   cmd_logs ;;
  -h|--help) sed -n '2,24p' "$0"; exit 0 ;;
  '') die 1 "缺少命令。用法: scripts/container.sh up|verify|down|logs" ;;
  *)  die 1 "未知命令: $1（支持 up / verify / down / logs）" ;;
esac
