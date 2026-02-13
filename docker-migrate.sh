#!/bin/bash
# docker-migrate.sh - 一键迁移 Docker 环境到新服务器

set -e

# ======================
# 🔧 配置区（请按需修改）
# ======================

OLD_SERVER_USER="ubuntu"
OLD_SERVER_IP="123.123.123.123"
SSH_KEY=""  # 如 ~/.ssh/id_rsa，留空则用密码

# 是否自动 commit 所有正在运行的容器（true/false）
AUTO_COMMIT_RUNNING_CONTAINERS=true

# 要从旧服务器拉取的额外文件/目录（绝对路径）
EXTRA_PATHS=(
    "/home/ubuntu/fa_data"
)

# docker-compose.yml 的路径（必须是绝对路径）
COMPOSE_FILE="/home/ubuntu/docker-compose.yml"

# ======================
# 🛠 函数定义
# ======================

ssh_cmd() {
    if [[ -n "$SSH_KEY" ]]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$OLD_SERVER_USER@$OLD_SERVER_IP" "$@"
    else
        ssh -o StrictHostKeyChecking=no "$OLD_SERVER_USER@$OLD_SERVER_IP" "$@"
    fi
}

rsync_cmd() {
    if [[ -n "$SSH_KEY" ]]; then
        rsync -avzP -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" "$@"
    else
        rsync -avzP -e "ssh -o StrictHostKeyChecking=no" "$@"
    fi
}

# ======================
# 🚀 主流程
# ======================

echo "🚀 开始从旧服务器迁移 Docker 环境..."

# 1️⃣ 【新】在新服务器上安装 Docker（如果未安装）
if ! command -v docker &> /dev/null; then
    echo "📦 安装 Docker..."
    sudo apt update
    sudo apt install -y ca-certificates curl gnupg lsb-release
    sudo mkdir -p /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
    sudo apt update
    sudo apt install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
    # 启动服务
    sudo systemctl enable --now docker
fi

# 2️⃣ 【新】将当前用户加入 docker 组（避免每次 sudo）
if ! groups | grep -q '\bdocker\b'; then
    echo "👥 将当前用户加入 docker 组..."
    sudo usermod -aG docker "$USER"
    echo "⚠️  注意：你需要重新登录 shell 或运行 'newgrp docker' 才能生效"
    # 临时激活组（当前会话）
    newgrp docker << END
exec "$0" "$@"
END
    exit 0
fi

# 3️⃣ 在旧服务器上准备镜像包（含 commit）
echo "🔧 在旧服务器上准备 Docker 镜像..."

prepare_script=$(cat << 'EOF'
#!/bin/bash
set -e
mkdir -p /tmp/docker-migration

# 停止所有容器（可选，避免数据不一致）
# docker stop $(docker ps -q) 2>/dev/null || true

# 如果启用自动 commit
if [ "$AUTO_COMMIT" = "true" ]; then
    echo "🔄 正在 commit 所有运行中的容器..."
    docker ps -q | while read cid; do
        name=$(docker inspect --format='{{.Name}}' "$cid" | sed 's/^\///' | tr '[:upper:]' '[:lower:]')
        image_name="backup/${name}:$(date +%Y%m%d-%H%M%S)"
        echo "Committing container $name -> $image_name"
        docker commit "$cid" "$image_name"
    done
fi

# 保存所有镜像
docker save $(docker images -q) -o /tmp/docker-migration/all-images.tar
echo "✅ 镜像打包完成"
EOF
)

# 上传并执行准备脚本
echo "📤 上传准备脚本到旧服务器..."
ssh_cmd "cat > /tmp/prepare-docker.sh" <<< "$prepare_script"
ssh_cmd "chmod +x /tmp/prepare-docker.sh"
ssh_cmd "AUTO_COMMIT=$AUTO_COMMIT_RUNNING_CONTAINERS /tmp/prepare-docker.sh"

# 4️⃣ 拉取镜像包
WORK_DIR="./migration-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK_DIR"
echo "📥 下载 all-images.tar..."
rsync_cmd "$OLD_SERVER_USER@$OLD_SERVER_IP:/tmp/docker-migration/all-images.tar" "$WORK_DIR/"

# 5️⃣ 拉取额外数据（如 fa_data）
for path in "${EXTRA_PATHS[@]}"; do
    echo "📥 下载 $path ..."
    rsync_cmd "$OLD_SERVER_USER@$OLD_SERVER_IP:$path" "$(dirname "$path")/"
done

# 6️⃣ 拉取 docker-compose.yml 到**原路径**
echo "📥 下载 docker-compose.yml 到 $COMPOSE_FILE ..."
sudo mkdir -p "$(dirname "$COMPOSE_FILE")"
rsync_cmd "$OLD_SERVER_USER@$OLD_SERVER_IP:$COMPOSE_FILE" "$COMPOSE_FILE"

# 7️⃣ 加载镜像
echo "🔄 加载 Docker 镜像..."
docker load -i "$WORK_DIR/all-images.tar"

# 8️⃣ 【关键修正】直接在 compose 文件所在目录启动（保留相对路径语义）
echo "▶️  启动 docker-compose 服务（在 $(dirname "$COMPOSE_FILE")）..."
cd "$(dirname "$COMPOSE_FILE")"
docker-compose up -d

# 9️⃣ 清理旧服务器
echo "🧹 清理旧服务器临时文件..."
ssh_cmd "rm -f /tmp/prepare-docker.sh && rm -rf /tmp/docker-migration"

echo "✅ 迁移完成！服务已启动。"
echo "工作目录: $WORK_DIR"
echo "Compose 文件: $COMPOSE_FILE"
