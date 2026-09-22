# =============================================================================
# 台球俱乐部用户端 Dockerfile
# 支持多架构构建: AMD64 (x86_64) 和 ARM64 (Apple Silicon, AWS Graviton)
# =============================================================================

# -----------------------------------------------------------------------------
# 构建阶段
# 使用 node:20-alpine 作为基础镜像，该镜像官方支持多架构
# 验证命令: docker pull --platform linux/arm64 node:20-alpine
# -----------------------------------------------------------------------------
FROM node:20-alpine AS builder

WORKDIR /app

# 复制依赖文件
COPY package*.json ./

# 安装依赖（按 package-lock.json 可复现安装，跨架构在容器内拉取对应原生依赖）
RUN npm ci

# 复制源代码
COPY . .

# 构建应用
RUN npm run build

# -----------------------------------------------------------------------------
# 生产阶段
# 使用 nginx:1.25-alpine 作为基础镜像，该镜像官方支持多架构
# 验证命令: docker pull --platform linux/arm64 nginx:1.25-alpine
# -----------------------------------------------------------------------------
FROM nginx:1.25-alpine

# 复制构建产物
COPY --from=builder /app/dist /usr/share/nginx/html

# 复制nginx配置
COPY nginx.conf /etc/nginx/conf.d/default.conf

# 暴露端口
EXPOSE 80

# 启动nginx
CMD ["nginx", "-g", "daemon off;"]

# =============================================================================
# 跨平台构建说明
# =============================================================================
# 
# 1. 本地构建（自动使用当前平台架构）:
#    docker build -t billiard-user .
#
# 2. 指定平台构建:
#    docker build --platform linux/amd64 -t billiard-user:amd64 .
#    docker build --platform linux/arm64 -t billiard-user:arm64 .
#
# 3. 多架构构建并推送（需要 buildx）:
#    docker buildx create --use
#    docker buildx build --platform linux/amd64,linux/arm64 -t billiard-user:latest --push .
#
# 4. 验证镜像架构:
#    docker inspect billiard-user | grep Architecture
#
# =============================================================================
