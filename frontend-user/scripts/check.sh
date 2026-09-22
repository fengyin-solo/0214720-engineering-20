#!/usr/bin/env bash
# =============================================================================
# check.sh - 用户端基线环境检查（只读，不启动服务、不修改任何文件）
#
# 检查项：
#   1. Node/npm 是否存在、版本是否符合基线
#   2. node_modules 是否存在、vite/rollup/esbuild 是否与当前平台匹配
#   3. 环境变量文件是否完整、必填项是否合法
#   4. 端口是否被占用
#   5. （仅 --with-dist）构建产物是否存在且完整
#
# 用法:
#   scripts/check.sh                 # 开发模式基线（检查 .env.development、8080）
#   scripts/check.sh production      # 生产模式基线（检查 .env.production、8081/80）
#   scripts/check.sh --with-dist     # 额外校验 dist/ 构建产物
#
# 退出码: 0 通过 / 2 缺少依赖 / 3 端口占用 / 4 配置缺失 / 6 产物缺失
# =============================================================================
set -uo pipefail

source "$(cd "$(dirname "$0")" && pwd)/lib.sh"

mode="dev"
with_dist=0
for arg in "$@"; do
  case "$arg" in
    production|prod) mode="production" ;;
    dev|development) mode="dev" ;;
    --with-dist)     with_dist=1 ;;
    -h|--help)
      sed -n '2,20p' "$0"
      exit 0 ;;
    *) die 1 "未知参数: $arg（支持 dev / production / --with-dist）" ;;
  esac
done

printf '%s\n' "${C_BOLD}== 用户端可复现基线检查（模式: $mode）==${C_RESET}"
check_dependencies
check_env "$mode"

if [ "$mode" = "production" ]; then
  ensure_port_free "${FRONTEND_USER_PORT:-$CONTAINER_PORT_DEFAULT}" "容器映射端口 -> 80"
else
  ensure_port_free "${FRONTEND_USER_PORT:-$DEV_PORT_DEFAULT}" "vite dev"
fi

if [ "$with_dist" -eq 1 ]; then
  verify_dist
fi

ok "全部基线检查通过"
