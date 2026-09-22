#!/usr/bin/env bash
# =============================================================================
# build.sh - 用户端生产构建（固定可复现基线 + 明确失败结果 + 产物校验）
#
# 行为：
#   1. 依赖检查（node_modules 缺失/平台不匹配 -> 退出码 2，提示 npm ci）
#   2. 生产环境变量检查（.env.production 缺失/非法 -> 退出码 4）
#   3. 执行 vite build（失败 -> 退出码 5，原样输出构建日志）
#   4. 校验 dist/ 产物（缺失 -> 退出码 6）
#
# 用法:
#   scripts/build.sh             # 标准生产构建
#   scripts/build.sh --verify    # 构建后额外对产物执行 HTTP 冒烟（自动起停 preview，不残留服务）
#
# 说明: 本脚本不删除 dist/，也不修改任何业务源码；npm run build 原命令保持可用。
# 退出码: 0 成功 / 2 缺少依赖 / 4 配置缺失 / 5 构建失败 / 6 产物缺失 / 7 冒烟失败
# =============================================================================
set -uo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

VERIFY=0
case "${1:-}" in
  --verify) VERIFY=1 ;;
  -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
  '') ;;
  *) die 1 "未知参数: $1（支持 --verify）" ;;
esac

check_dependencies
check_env production

log "执行生产构建：npm run build（vite build）"
build_log="$(mktemp -t frontend-user-build.XXXXXX.log)"
trap 'rm -f "$build_log"' EXIT

if ! (cd "$PROJECT_ROOT" && npm run build) 2>&1 | tee "$build_log"; then
  die 5 "构建失败，请根据上方日志定位（常见原因：源码语法/导入错误、依赖缺失）。修复后重新执行本脚本。"
fi

verify_dist

if [ "$VERIFY" -eq 1 ]; then
  PORT="${FRONTEND_USER_PREVIEW_PORT:-$PREVIEW_PORT_DEFAULT}"
  ensure_port_free "$PORT" "vite preview 冒烟"
  log "启动 preview 对构建产物做 HTTP 冒烟，结束后自动停止"
  PREVIEW_LOG="/tmp/frontend-user-preview.$$.log"
  start_bg "$PROJECT_ROOT" "$PREVIEW_LOG" npx vite preview --port "$PORT" --strictPort --host 0.0.0.0
  PREVIEW_PID="$BG_PID"
  smoke_cleanup() {
    trap - EXIT INT TERM
    stop_bg "$PREVIEW_PID"
    rm -f "$PREVIEW_LOG" 2>/dev/null || true
  }
  trap 'smoke_cleanup; rm -f "$build_log"' EXIT INT TERM

  if ! wait_for_http "http://localhost:$PORT/" 30; then
    cat "$PREVIEW_LOG" >&2 || true
    die 7 "preview 服务在 30 秒内未就绪。"
  fi

  fail=0
  for route in / /tables /courses /competitions /shop /profile /tasks; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT$route")"
    if [ "$code" = "200" ]; then ok "  $route -> 200"; else err "  $route -> $code"; fail=1; fi
  done
  # 校验 index.html 引用的带哈希资源确实可访问（防止“有 html 无产物”）
  asset="$(curl -s "http://localhost:$PORT/" | grep -o 'assets/[^"]*\.js' | head -1)"
  if [ -n "$asset" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' "http://localhost:$PORT/$asset")" = "200" ]; then
    ok "  /$asset -> 200"
  else
    err "  构建产物中的 JS 资源无法访问: ${asset:-未在 index.html 中找到引用}"
    fail=1
  fi

  smoke_cleanup
  trap 'rm -f "$build_log"' EXIT
  if [ "$fail" -eq 0 ]; then
    ok "构建及产物冒烟全部通过，preview 已停止，无残留进程"
  else
    die 7 "产物冒烟失败，请检查构建结果。"
  fi
fi

ok "构建基线流程完成，产物位于 frontend-user/dist/"
