# =============================================================================
# 台球俱乐部用户端 Dockerfile（可复现基线）
#
# 多架构支持: linux/amd64 (x86_64) + linux/arm64 (Apple Silicon / AWS Graviton)
# 基础镜像 node:20-alpine、nginx:1.25-alpine 均为官方多架构镜像。
# 验证方式:
#   docker pull --platform linux/arm64 node:20-alpine
#   docker pull --platform linux/arm64 nginx:1.25-alpine
# 构建时请从仓库根目录使用 docker-compose（上下文即 frontend-user/）：
#   frontend-user/scripts/container.sh up
#
# 关键约束:
#   - .dockerignore 排除宿主席 node_modules/dist，依赖在镜像内按
#     package-lock.json 以 npm ci 重新安装（可复现，跨平台不污染）
#   - 构建失败（依赖/编译错误）则镜像构建中断，不会产出空站点镜像
#   - 运行阶段内置 HEALTHCHECK，编排层据此判定服务真实可用
# =============================================================================

# syntax=docker/dockerfile:1
FROM --platform=$BUILDPLATFORM node:20-alpine AS builder

WORKDIR /app

# 先复制依赖清单，利用 Docker 层缓存；npm ci 严格按 lockfile 安装，保证可复现
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund

# 复制源码与环境配置后构建；失败则整个镜像构建失败（明确结果，不产生空产物）
COPY . .
RUN npm run build && test -f dist/index.html

# -----------------------------------------------------------------------------
# 生产阶段：nginx 多架构镜像
# -----------------------------------------------------------------------------
FROM nginx:1.25-alpine

# 容器运行约束：非特权端口不适用（业务固定 80），以专用低权用户运行 worker 已在
# nginx.conf 中声明；root 仅用于 master 进程绑定 80 端口。
COPY --from=builder /app/dist /usr/share/nginx/html
COPY nginx.conf /etc/nginx/conf.d/default.conf

EXPOSE 80

# 健康检查：busybox wget（nginx:alpine 自带），每 10s 探测，3 次失败判为不可用
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q -O /dev/null http://127.0.0.1/ || exit 1

CMD ["nginx", "-g", "daemon off;"]

# =============================================================================
# 跨平台构建说明
#
# 1. compose 构建（推荐，自动跟随当前机器架构）:
#    frontend-user/scripts/container.sh up
#
# 2. 单平台指定架构构建:
#    docker build --platform linux/amd64 -t billiard-user:amd64 ./frontend-user
#    docker build --platform linux/arm64 -t billiard-user:arm64 ./frontend-user
#
# 3. 多架构构建并推送（需要 buildx）:
#    docker buildx create --use
#    docker buildx build --platform linux/amd64,linux/arm64 \
#      -t billiard-user:latest --push ./frontend-user
#
# 4. 验证镜像架构:
#    docker inspect billiard-frontend-user | grep Architecture
# =============================================================================
