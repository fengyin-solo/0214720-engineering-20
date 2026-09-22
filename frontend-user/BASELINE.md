# 用户端可复现运行基线（BASELINE）

本文件固化用户端（`frontend-user`，Vue 3 + Vite 5）的**开发启动、构建、环境变量、端口、容器运行**约束。
目标：对「缺少依赖、配置缺失、端口占用、构建失败、产物缺失」五类问题都给出**明确的退出码与提示**；
检查与冒烟结束后**不残留服务**；**不改写业务源码**；现有 `npm run dev / build / test` 与默认 Mock 数据继续可用。

## 1. 版本与端口基线

| 项 | 基线值 | 来源 |
|----|--------|------|
| Node | 20.x（最低 18） | `.nvmrc`、`Dockerfile`（node:20-alpine） |
| 包管理 | npm，依赖版本以 `package-lock.json` 为准 | `npm ci` |
| 开发端口 | **8080/tcp** | `vite.config.js`，启动加 `--strictPort`，占用即失败 |
| 本地预览端口 | **8090/tcp**（`FRONTEND_USER_PREVIEW_PORT` 可覆盖） | `scripts/preview.sh` |
| 容器映射 | 宿主机 **8081** → 容器内 **80** | 根目录 `docker-compose.yml` |
| 容器镜像 | 多架构 `node:20-alpine` + `nginx:1.25-alpine`（amd64/arm64） | `Dockerfile` |

页面入口（SPA 路由，dev / preview / 容器均须返回 200）：

```
/            首页        /tables       球桌预约
/courses     教学课程    /competitions 赛事活动
/shop        装备商城    /profile      个人中心
/tasks       任务中心
```

## 2. 环境变量基线

| 变量 | 必填 | 允许值 / 默认 | 说明 |
|------|------|----------------|------|
| `VITE_USE_MOCK` | ✅ | `true` / `false` | 缺失或为其它值 → 检查失败（退出码 4）。默认 `true`，继续使用内置 Mock 数据 |
| `VITE_API_BASE_URL` | ❌ | 默认 `/api` | `VITE_USE_MOCK=false` 时须指向真实后端，否则给出警告 |
| `VITE_LOG_LEVEL` | ❌ | `debug`/`info`/`warn`/`error`，默认 `info` | 缺失仅提示 |
| `VITE_APP_TITLE` | ❌ | 默认 `台球俱乐部` | 缺失仅提示 |

文件优先级（Vite 原生）：`.env.local` > `.env.[mode]` > `.env`。
模板见 `.env.example`；开发用 `.env.development`，生产构建用 `.env.production`，`.env.local` 不入库（见根 `.gitignore`）。

## 3. 基线命令

所有脚本位于 `frontend-user/scripts/`，均可直接执行（`bash scripts/xxx.sh`），也有 npm 包装：

| 命令 | npm 包装 | 作用 | 启动服务？ |
|------|----------|------|-----------|
| `scripts/check.sh [production] [--with-dist]` | `npm run check:dev` / `check:prod` | 只读检查：依赖、平台匹配、环境变量、端口、（可选）产物 | 否 |
| `scripts/dev.sh [--smoke]` | —（`npm run dev:smoke` 冒烟） | 固定 8080 启动 dev；`--smoke` 检查 7 个入口后自动停止 | 是，退出即回收 |
| `scripts/build.sh [--verify]` | `npm run build:verify` | 依赖/配置检查 → `vite build` → 产物校验；`--verify` 起停 preview 做 HTTP 冒烟 | 仅 `--verify` 临时启动 |
| `scripts/preview.sh` | — | 预览 `dist/`（默认 8090），退出即回收 | 是，退出即回收 |
| `scripts/container.sh up\|verify\|down\|logs` | `container:up` / `container:verify` / `container:down` | 8081 端口预检 → 镜像构建 → 启动 → 健康检查 + 入口冒烟 | Docker 容器 |

原命令不受影响，继续可用：`npm run dev`、`npm run build`、`npm run preview`、`npm run test`、`npm run lint`。

## 4. 失败结果矩阵（统一退出码）

| 场景 | 检测点 | 退出码 | 处理提示 |
|------|--------|--------|----------|
| 未安装 Node/npm，或版本低于 18 | check/dev/build/preview | 2 | 安装 Node 20（`nvm use`） |
| `node_modules` 缺失 | 同上 | 2 | `npm ci`（或 `npm install`） |
| 依赖平台不匹配（如 macOS 的 node_modules 拷到 Linux，rollup/esbuild 原生模块不可用） | 直接执行 vite/esbuild 做功能性探测 | 2 | `rm -rf node_modules && npm ci` |
| `.env.development` / `.env.production` 缺失 | check/dev/build | 4 | 从 `.env.example` 复制 |
| `VITE_USE_MOCK` 缺失或非法 | 同上 | 4 | 只能填 `true` / `false` |
| 8080 / 8090 / 8081 端口被占用 | 启动前探测并打印占用进程 PID | 3 | 停止占用进程，或用 `FRONTEND_USER_PORT` / `FRONTEND_USER_PREVIEW_PORT` 换端口 |
| `vite build` 编译失败 | build | 5 | 原样输出构建日志 |
| Docker 镜像构建失败 | container up | 5 | 输出 compose build 日志 |
| `dist/index.html` 或 `dist/assets/*.js` 缺失 | build 后 / preview / check --with-dist | 6 | 重新执行 `scripts/build.sh` |
| dev/preview/容器 30~60s 未就绪或健康检查失败 | 就绪探测 / HEALTHCHECK | 7 | 输出服务/容器日志 |
| 页面入口非 200 或哈希资源不可访问 | 冒烟 | 6/7 | 检查路由与产物 |

## 5. 容器运行约束

1. **多架构**：基础镜像官方支持 `linux/amd64` 与 `linux/arm64`；`Dockerfile` 构建阶段使用 `--platform=$BUILDPLATFORM`，Apple Silicon 上原生构建。
2. **干净构建上下文**：`.dockerignore` 排除 `node_modules`、`dist`，依赖在镜像内 `npm ci` 重装——杜绝宿主席原生模块（如 `@rollup/rollup-darwin-arm64`）进入 Linux 镜像导致构建失败。
3. **构建即验证**：Dockerfile 内 `npm run build && test -f dist/index.html`，构建失败不会产出运行空站点的镜像。
4. **固定端口**：`8081:80`，占用时 `up` 直接失败（脚本在构建前预检端口）。
5. **健康检查**：镜像内置 `HEALTHCHECK`，compose 同步声明；`container.sh up` 等到 `healthy` 且 7 个入口 + 哈希资源全部 200 才算成功。
6. **安全**：`init: true` 负责信号回收，`security_opt: no-new-privileges`；前端纯静态 + Mock 数据，无持久化卷。
7. **清理**：`scripts/container.sh down`（等价 `docker compose down`）移除容器，不残留。

## 6. 不残留服务的保证

- `dev.sh` / `preview.sh` 通过 `trap EXIT/INT/TERM` 在 Ctrl-C、kill、脚本结束时回收子进程。
- `build.sh --verify` 的 preview 在冒烟结束后自动停止。
- 冒烟模式的临时日志写到 `/tmp`，文件名带 PID，退出时删除。

## 7. 标准验收流程

```bash
cd frontend-user

npm ci                         # 缺依赖时先装（或 npm install）
npm run check:prod             # 1) 基线检查（依赖/配置/8081端口）
npm run build:verify           # 2) 构建 + 产物 + HTTP 冒烟
npm run dev:smoke              # 3) dev 模式核心入口冒烟（自动起停）

# 容器（需要 Docker）
scripts/container.sh up        # 4) 构建镜像 -> 启动 -> healthy -> 入口冒烟
# 浏览器验证: http://localhost:8081 （user / 123456）
scripts/container.sh down      # 5) 清理容器
```
