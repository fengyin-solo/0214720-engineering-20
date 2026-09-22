#!/usr/bin/env bash
# =============================================================================
# preview.sh - 本地预览生产构建产物（nginx 部署前的等价静态托管验证）
#
# 行为：
#   1. 依赖检查
#   2. 产物检查（dist/ 缺失 -> 退出码 6，并提示先构建）
#   3. 固定端口启动 vite preview（--strictPort，占用即退出码 3，不静默漂移）
#   4. 退出时自动回收进程，不残留服务
#
# 用法:
#   scripts/preview.sh            # 前台预览（默认端口 8090）
#   FRONTEND_USER_PREVIEW_PORT=9000 scripts/preview.sh
#
# 退出码: 0 / 2 缺少依赖 / 3 端口占用 / 6 产物缺失 / 7 服务启动失败
# =============================================================================
set -uo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { sed -n '2,20p' "$0"; exit 0; }
PORT="${FRONTEND_USER_PREVIEW_PORT:-$PREVIEW_PORT_DEFAULT}"

check_node
verify_dist
ensure_port_free "$PORT" "vite preview"

CHILD_PID=""
PREVIEW_LOG="/tmp/frontend-user-preview.$$.log"
cleanup() {
  trap - EXIT INT TERM
  if [ -n "$CHILD_PID" ]; then
    log "停止 preview (进程组 $CHILD_PID) ..."
    stop_bg "$CHILD_PID"
  fi
  rm -f "$PREVIEW_LOG" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "预览构建产物：http://localhost:$PORT"
start_bg "$PROJECT_ROOT" "$PREVIEW_LOG" npx vite preview --port "$PORT" --strictPort --host 0.0.0.0
CHILD_PID="$BG_PID"

if ! wait_for_http "http://localhost:$PORT/" 30; then
  cat "$PREVIEW_LOG" >&2 || true
  die 7 "preview 服务在 30 秒内未就绪，日志见上方。"
fi

printf '\n%s访问地址: http://localhost:%s%s\n' "$C_BOLD" "$PORT" "$C_RESET"
log "按 Ctrl-C 停止（脚本自动回收进程，不残留服务）"
wait "$CHILD_PID" 2>/dev/null || true
