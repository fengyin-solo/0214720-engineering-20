#!/usr/bin/env bash
# =============================================================================
# lib.sh - 用户端可复现基线公共函数库
#
# 被 check.sh / dev.sh / build.sh / preview.sh / container.sh 引用，不单独执行。
#
# 统一退出码（所有基线脚本一致）：
#   0  成功
#   1  其它/未分类错误
#   2  缺少依赖或依赖与当前平台不匹配
#   3  端口被占用
#   4  环境变量配置缺失或非法
#   5  构建失败
#   6  构建产物缺失
# =============================================================================

# 项目根目录（frontend-user/），即本脚本所在目录的上一级
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# 端口基线
DEV_PORT_DEFAULT=8080       # vite dev（与 vite.config.js 保持一致）
PREVIEW_PORT_DEFAULT=8090   # 本地预览构建产物
CONTAINER_PORT_DEFAULT=8081 # 容器对宿主机映射端口 -> 容器内 80

# Node 基线版本（.nvmrc / Dockerfile 同为 20）
NODE_BASELINE_MAJOR=20
NODE_MIN_MAJOR=18

# -----------------------------------------------------------------------------
# 日志输出
# -----------------------------------------------------------------------------
if [ -t 1 ] && command -v tput >/dev/null 2>&1; then
  C_RED="$(tput setaf 1)"; C_GREEN="$(tput setaf 2)"; C_YELLOW="$(tput setaf 3)"
  C_BLUE="$(tput setaf 4)"; C_BOLD="$(tput bold)"; C_RESET="$(tput sgr0)"
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_RESET=''
fi

log()  { printf '%s[INFO]%s  %s\n' "$C_BLUE" "$C_RESET" "$*"; }
ok()   { printf '%s[OK]%s    %s\n' "$C_GREEN" "$C_RESET" "$*"; }
warn() { printf '%s[WARN]%s  %s\n' "$C_YELLOW" "$C_RESET" "$*"; }
err()  { printf '%s[ERROR]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()  { err "$2"; exit "$1"; }

# -----------------------------------------------------------------------------
# 1. 运行环境与依赖检查（缺少依赖 / 平台不匹配 -> 退出码 2）
# -----------------------------------------------------------------------------
check_node() {
  command -v node >/dev/null 2>&1 || die 2 \
    "未找到 Node.js。基线要求 Node ${NODE_BASELINE_MAJOR}.x（最低 ${NODE_MIN_MAJOR}），请安装后重试（可执行 nvm use）。"
  command -v npm >/dev/null 2>&1 || die 2 "未找到 npm，请随 Node.js ${NODE_BASELINE_MAJOR}.x 一并安装。"

  local major
  major="$(node -p 'process.versions.node.split(".")[0]')"
  if [ "$major" -lt "$NODE_MIN_MAJOR" ]; then
    die 2 "Node 版本 $(node -v) 过低，基线要求 Node ${NODE_BASELINE_MAJOR}.x（最低 ${NODE_MIN_MAJOR}）。"
  fi
  if [ "$major" != "$NODE_BASELINE_MAJOR" ]; then
    warn "当前 Node $(node -v)，基线版本为 ${NODE_BASELINE_MAJOR}.x（见 .nvmrc / Dockerfile），建议切换以获得可复现结果。"
  else
    ok "Node $(node -v)"
  fi
}

check_dependencies() {
  check_node

  [ -f "$PROJECT_ROOT/package.json" ] || die 2 "缺少 package.json，当前目录是否为 frontend-user 项目根目录？"

  if [ ! -d "$PROJECT_ROOT/node_modules" ]; then
    die 2 "缺少依赖（node_modules 不存在）。请在 $PROJECT_ROOT 执行：npm ci（或 npm install）"
  fi

  if [ ! -x "$PROJECT_ROOT/node_modules/.bin/vite" ] && [ ! -f "$PROJECT_ROOT/node_modules/vite/bin/vite.js" ]; then
    die 2 "依赖不完整（未找到 vite）。请重新安装依赖：npm ci（或 npm install）"
  fi

  # 功能性校验：直接执行 vite 可同时触发 rollup 原生模块加载，
  # 能识别 node_modules 在其它平台/架构安装后被复制过来的情况
  # （例如 macOS 上安装的 @rollup/rollup-darwin-arm64 在 Linux 上不可用）。
  if ! (cd "$PROJECT_ROOT" && node node_modules/vite/bin/vite.js --version >/dev/null 2>&1); then
    local platform
    platform="$(node -p 'process.platform + "-" + process.arch')"
    die 2 "vite/rollup 在当前平台($platform)无法运行，通常是 node_modules 来自其它操作系统/架构。请重新安装依赖：rm -rf node_modules && npm ci"
  fi

  # esbuild 原生二进制同样带平台相关产物（.bin/esbuild 指向真实可执行文件，
  # 直接执行，不能用 node 加载）
  if [ -x "$PROJECT_ROOT/node_modules/.bin/esbuild" ]; then
    if ! "$PROJECT_ROOT/node_modules/.bin/esbuild" --version >/dev/null 2>&1; then
      die 2 "esbuild 原生二进制在当前平台不可用，依赖与平台不匹配。请重新安装：rm -rf node_modules && npm ci"
    fi
  fi

  ok "依赖检查通过（node_modules 与当前平台匹配）"
}

# -----------------------------------------------------------------------------
# 2. 环境变量检查（配置缺失/非法 -> 退出码 4）
#
# 用法: check_env <dev|production>
# -----------------------------------------------------------------------------
_env_value() {
  # $1=文件 $2=变量名；输出第一个非注释中的赋值（未设置则无输出）
  local file="$1" key="$2" line value
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in ''|'#'*) continue ;; esac
    if printf '%s' "$line" | grep -q "^${key}="; then
      value="${line#*=}"
      value="${value%"${value##*[![:space:]]}"}"
      printf '%s' "$value"
      return 0
    fi
  done < "$file"
  return 1
}

check_env() {
  local mode="$1" env_file
  [ -f "$PROJECT_ROOT/.env.example" ] || die 4 "缺少配置模板 .env.example"

  case "$mode" in
    dev)        env_file="$PROJECT_ROOT/.env.development" ;;
    production) env_file="$PROJECT_ROOT/.env.production" ;;
    *) die 1 "check_env: 未知模式 '$mode'（支持 dev / production）" ;;
  esac

  [ -f "$env_file" ] || die 4 "缺少环境配置文件 $(basename "$env_file")，可从 .env.example 复制后按基线修改。"

  # 必填项：VITE_USE_MOCK，且只允许 true/false
  local use_mock
  use_mock="$(_env_value "$env_file" VITE_USE_MOCK)" || true
  if [ -z "$use_mock" ]; then
    die 4 "$(basename "$env_file") 缺少必填变量 VITE_USE_MOCK（true=模拟数据 / false=真实API）。"
  fi
  case "$use_mock" in
    true|false) ;;
    *) die 4 "VITE_USE_MOCK=$use_mock 非法，只允许 true 或 false（文件：$(basename "$env_file")）。" ;;
  esac

  # 可选项：缺失时代码内有默认值，仅提示不阻断
  local missing=()
  [ -n "$(_env_value "$env_file" VITE_API_BASE_URL 2>/dev/null)" ] || missing+=(VITE_API_BASE_URL)
  [ -n "$(_env_value "$env_file" VITE_LOG_LEVEL 2>/dev/null)" ]  || missing+=(VITE_LOG_LEVEL)
  [ -n "$(_env_value "$env_file" VITE_APP_TITLE 2>/dev/null)" ]  || missing+=(VITE_APP_TITLE)
  if [ "${#missing[@]}" -gt 0 ]; then
    warn "$(basename "$env_file") 未设置 ${missing[*]}，将使用代码默认值（/api、info、台球俱乐部）。"
  fi

  # 使用真实 API 时给出地址合理性提示
  local api_base
  api_base="$(_env_value "$env_file" VITE_API_BASE_URL 2>/dev/null)" || true
  if [ "$use_mock" = "false" ]; then
    if [ -z "$api_base" ] || [ "$api_base" = "/api" ]; then
      warn "VITE_USE_MOCK=false 但 VITE_API_BASE_URL 未指向真实后端（当前：'${api_base:-}'），请确认反向代理或后端地址。"
    fi
  fi

  # .env.local 覆盖（不入库）存在时提示其优先级最高
  [ -f "$PROJECT_ROOT/.env.local" ] && warn "检测到 .env.local，其变量优先级最高且不入库，排查配置时需注意。"

  ok "环境变量检查通过（模式：$mode，文件：$(basename "$env_file")，MOCK=$use_mock）"
}

# -----------------------------------------------------------------------------
# 3. 端口检查（端口被占用 -> 退出码 3）
#
# 用法: ensure_port_free <端口> [用途说明]
# -----------------------------------------------------------------------------
_port_pid() {
  local port="$1"
  if command -v lsof >/dev/null 2>&1; then
    lsof -tiTCP:"$port" -sTCP:LISTEN 2>/dev/null | head -1
  elif command -v ss >/dev/null 2>&1; then
    ss -ltnpH "sport = :$port" 2>/dev/null | sed -n 's/.*pid=\([0-9]*\).*/\1/p' | head -1
  elif command -v fuser >/dev/null 2>&1; then
    fuser "$port/tcp" 2>/dev/null | tr -d ' '
  fi
}

# 实际尝试绑定端口探测占用（不依赖 ss/lsof，容器最小化镜像中同样可靠；
# macOS 与 Linux 均随 Node 可用）。返回 0=端口空闲，1=已占用。
_port_bind_free() {
  local port="$1"
  node -e '
    const net = require("net")
    const srv = net.createServer()
    srv.once("error", (e) => { process.exit(e.code === "EADDRINUSE" ? 1 : 2) })
    srv.listen('"$port"', "0.0.0.0", () => srv.close(() => process.exit(0)))
  ' >/dev/null 2>&1
}

ensure_port_free() {
  local port="$1" purpose="${2:-}"
  if ! _port_bind_free "$port"; then
    local pid
    pid="$(_port_pid "$port")"
    err "端口 $port 已被占用${purpose:+（$purpose）}${pid:+，占用进程 PID=$pid}："
    if [ -n "$pid" ] && command -v ps >/dev/null 2>&1; then
      ps -p "$pid" -o pid=,command= 2>/dev/null | sed 's/^/  /' >&2 || true
    fi
    die 3 "请停止占用该端口的进程，或设置 FRONTEND_USER_PORT / FRONTEND_USER_PREVIEW_PORT=<其它端口> 后重试。"
  fi
  ok "端口 $port 可用${purpose:+（$purpose）}"
}

# -----------------------------------------------------------------------------
# 4. HTTP 就绪探测
#
# 用法: wait_for_http <url> [最大秒数，默认30]；成功返回0
# -----------------------------------------------------------------------------
wait_for_http() {
  local url="$1" max="${2:-30}" i=0
  while [ "$i" -lt "$max" ]; do
    if curl -fsS -o /dev/null --max-time 2 "$url" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# -----------------------------------------------------------------------------
# 4b. 后台服务的进程组管理
#
# npx/npm 会派生多层子进程（npm -> node vite），只 kill 直接子进程会让真正的
# vite 被 init 收养而残留。这里用 job control 让整条命令成为独立进程组，
# 回收时按进程组发信号，保证“执行后不残留服务”。Linux 与 macOS 均适用。
#
# 用法:
#   start_bg <工作目录> <日志文件> <命令...>   # 成功后设置全局 BG_PID
#   stop_bg  <PID>                            # TERM -> KILL 整个进程组
# -----------------------------------------------------------------------------
start_bg() {
  local dir="$1" log="$2"
  shift 2
  set -m
  (
    cd "$dir" || exit 1
    exec "$@"
  ) >"$log" 2>&1 &
  BG_PID=$!
  set +m
}

stop_bg() {
  local pid="$1"
  [ -z "$pid" ] && return 0
  # 负 PID = 向整个进程组发信号
  kill -TERM "-$pid" 2>/dev/null || true
  for _ in 1 2 3 4 5; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 1
  done
  kill -KILL "-$pid" 2>/dev/null || true
  kill -KILL "$pid" 2>/dev/null || true
}

# -----------------------------------------------------------------------------
# 5. 构建产物校验（产物缺失 -> 退出码 6）
# -----------------------------------------------------------------------------
verify_dist() {
  local dist="$PROJECT_ROOT/dist"
  [ -f "$dist/index.html" ] || die 6 \
    "构建产物缺失：dist/index.html 不存在。请先执行 npm run build（或 scripts/build.sh）。"
  ls "$dist/assets/"*.js >/dev/null 2>&1 || die 6 "构建产物不完整：dist/assets/ 下未找到 JS 文件，构建可能失败。"
  ls "$dist/assets/"*.css >/dev/null 2>&1 || warn "dist/assets/ 下未找到 CSS 文件，请确认样式是否正常打包。"
  ok "构建产物校验通过：dist/index.html + $(ls "$dist/assets/" | wc -l | tr -d ' ') 个 assets 文件"
}
