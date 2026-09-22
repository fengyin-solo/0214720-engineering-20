#!/usr/bin/env bash
# =============================================================================
# dev.sh - 用户端开发服务器（固定端口基线 + 失败快速明确 + 退出不残留服务）
#
# 行为：
#   1. 先做依赖 / 环境变量 / 端口基线检查（不通过立即退出，退出码明确）
#   2. 以固定端口启动 vite dev，并带 --strictPort（端口被占直接失败，不静默漂移）
#   3. 就绪探测通过后打印访问地址
#   4. Ctrl-C / kill / 脚本退出时自动回收服务进程，不残留
#
# 用法:
#   scripts/dev.sh             # 前台启动开发服务器（默认端口 8080）
#   scripts/dev.sh --smoke     # 启动后检查核心页面入口，随后自动停止并退出
#
# 可选环境变量:
#   FRONTEND_USER_PORT  覆盖默认开发端口（默认 8080，需与 vite.config.js 一致）
#
# 退出码: 0 成功(冒烟通过) / 2 缺少依赖 / 3 端口占用 / 4 配置缺失 / 7 服务启动或页面检查失败
# =============================================================================
set -uo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

SMOKE=0
[ "${1:-}" = "--smoke" ] && SMOKE=1
[ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ] && { sed -n '2,22p' "$0"; exit 0; }
PORT="${FRONTEND_USER_PORT:-$DEV_PORT_DEFAULT}"

check_dependencies
check_env dev
ensure_port_free "$PORT" "vite dev"

CHILD_PID=""
DEV_LOG="/tmp/frontend-user-dev.$$.log"
cleanup() {
  trap - EXIT INT TERM
  if [ -n "$CHILD_PID" ]; then
    log "停止开发服务器 (进程组 $CHILD_PID) ..."
    stop_bg "$CHILD_PID"
  fi
  rm -f "$DEV_LOG" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

log "启动 vite dev：http://localhost:$PORT（strictPort，占用即失败）"
start_bg "$PROJECT_ROOT" "$DEV_LOG" npx vite --port "$PORT" --strictPort --host 0.0.0.0
CHILD_PID="$BG_PID"

if ! wait_for_http "http://localhost:$PORT/" 30; then
  cat "$DEV_LOG" >&2 || true
  die 7 "开发服务器在 30 秒内未就绪，启动日志见上方。"
fi
ok "开发服务器已就绪 (PID=$CHILD_PID)"

SMOKE_ROUTES="/ /tables /courses /competitions /shop /profile /tasks"
fail=0
if [ "$SMOKE" -eq 1 ]; then
  log "冒烟检查核心页面入口（HTTP 状态码）..."
  for route in $SMOKE_ROUTES; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT$route")"
    if [ "$code" = "200" ]; then
      ok "  $route -> 200"
    else
      err "  $route -> $code（期望 200）"
      fail=1
    fi
  done
  # 模块入口必须能被 vite 正常转换返回（可拦截语法错误/导入失败）
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://localhost:$PORT/src/main.js")"
  if [ "$code" = "200" ]; then ok "  /src/main.js 模块转换 -> 200"; else err "  /src/main.js -> $code"; fail=1; fi

  cleanup
  trap - EXIT INT TERM
  if [ "$fail" -eq 0 ]; then
    ok "开发模式冒烟通过，服务已停止，无残留进程"
    exit 0
  fi
  die 7 "部分核心页面入口检查失败。"
fi

printf '\n%s访问地址: http://localhost:%s%s\n' "$C_BOLD" "$PORT" "$C_RESET"
log "可用路由: $(printf '%s ' $SMOKE_ROUTES)"
log "按 Ctrl-C 停止服务（脚本会自动回收进程）"

wait "$CHILD_PID" 2>/dev/null || true
