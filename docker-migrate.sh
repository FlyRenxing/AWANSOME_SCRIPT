#!/bin/bash
# docker-migrate.sh - 一键迁移 Docker 环境到新服务器（含 SSH 自动配置）

set -e

# ======================
# 🔧 配置区（请按需修改）
# ======================

OLD_SERVER_USER="ubuntu"
OLD_SERVER_IP="43.165.190.14"

# 是否自动生成并部署 SSH 密钥（true/false）
AUTO_SETUP_SSH_KEY=true

# 是否自动 commit 所有正在运行的容器（true/false）
AUTO_COMMIT_RUNNING_CONTAINERS=true

# 要从旧服务器拉取的额外文件/目录（绝对路径）
EXTRA_PATHS=(
    "/home/ubuntu/fa-data"
)

# docker-compose.yml 的路径（必须是绝对路径）
COMPOSE_FILE="/home/ubuntu/docker-compose.yml"

# ======================
# 🛠 内部变量
# ======================

SSH_KEY="$HOME/.ssh/id_rsa"
WORK_DIR="./migration-$(date +%Y%m%d-%H%M%S)"

# ======================
# 🛠 函数定义
# ======================

setup_ssh_key() {
    if [[ ! -f "$SSH_KEY" ]]; then
        echo "🔑 生成新的 SSH 密钥对..."
        ssh-keygen -t rsa -b 4096 -f "$SSH_KEY" -N ""
    fi

    echo "📤 将公钥复制到旧服务器 ($OLD_SERVER_USER@$OLD_SERVER_IP)..."
    ssh-copy-id -i "${SSH_KEY}.pub" -o StrictHostKeyChecking=no "$OLD_SERVER_USER@$OLD_SERVER_IP"
}

ssh_cmd() {
    if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
        ssh -i "$SSH_KEY" -o StrictHostKeyChecking=no "$OLD_SERVER_USER@$OLD_SERVER_IP" "$@"
    else
        ssh -o StrictHostKeyChecking=no "$OLD_SERVER_USER@$OLD_SERVER_IP" "$@"
    fi
}

rsync_cmd() {
    if [[ -n "$SSH_KEY" && -f "$SSH_KEY" ]]; then
        rsync -avzP -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=no" "$@"
    else
        rsync -avzP -e "ssh -o StrictHostKeyChecking=no" "$@"
    fi
}

# ======================
# 🚀 主流程
# ======================

echo "🚀 开始从旧服务器迁移 Docker 环境..."

# 0️⃣ 【新增】自动配置 SSH 密钥
if [[ "$AUTO_SETUP_SSH_KEY" == "true" ]]; then
    setup_ssh_key
fi

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
    sudo systemctl enable --now docker
fi

# 2️⃣ 【新】将当前用户加入 docker 组
if ! groups | grep -q '\bdocker\b'; then
    echo "👥 将当前用户加入 docker 组..."
    sudo usermod -aG docker "$USER"
    echo "⚠️  注意：你需要重新登录 shell 或运行 'newgrp docker' 才能生效"
    newgrp docker << END
exec "$0" "$@"
END
    exit 0
fi

# 3️⃣ 在旧服务器上准备镜像包（含 commit，容器名转小写）
echo "🔧 在旧服务器上准备 Docker 镜像..."

prepare_script=$(cat << 'EOF'
#!/bin/bash
set -e
mkdir -p /tmp/docker-migration

if [ "$AUTO_COMMIT" = "true" ]; then
    echo "🔄 正在 commit 所有运行中的容器..."
    docker ps -q | while read cid; do
        orig_name=$(docker inspect --format='{{.Name}}' "$cid" | sed 's/^\///')
        name=$(echo "$orig_name" | tr '[:upper:]' '[:lower:]')
        image_name="backup/${name}:$(date +%Y%m%d-%H%M%S)"
        echo "Committing container $orig_name -> $image_name"
        docker commit "$cid" "$image_name"
    done
fi

docker save $(docker images -q) -o /tmp/docker-migration/all-images.tar
echo "✅ 镜像打包完成"
EOF
)

echo "📤 上传准备脚本到旧服务器..."
ssh_cmd "cat > /tmp/prepare-docker.sh" <<< "$prepare_script"
ssh_cmd "chmod +x /tmp/prepare-docker.sh"
ssh_cmd "AUTO_COMMIT=$AUTO_COMMIT_RUNNING_CONTAINERS /tmp/prepare-docker.sh"

# 4️⃣ 拉取镜像包
mkdir -p "$WORK_DIR"
echo "📥 下载 all-images.tar..."
rsync_cmd "$OLD_SERVER_USER@$OLD_SERVER_IP:/tmp/docker-migration/all-images.tar" "$WORK_DIR/"

# 5️⃣ 【关键修复】用 sudo tar 同步 EXTRA_PATHS（绕过权限问题）
for path in "${EXTRA_PATHS[@]}"; do
    echo "📥 安全同步 $path (via sudo tar)..."
    dir=$(dirname "$path")
    base=$(basename "$path")
    # 在旧服务器打包（用 sudo）
    ssh_cmd "sudo tar -czf /tmp/${base}.tar.gz -C '$dir' '$base'"
    # 下载 tar 包
    rsync_cmd "$OLD_SERVER_USER@$OLD_SERVER_IP:/tmp/${base}.tar.gz" "$WORK_DIR/"
    # 解压到原路径（需要 sudo）
    sudo mkdir -p "$dir"
    sudo tar -xzf "$WORK_DIR/${base}.tar.gz" -C "$dir"
    # 清理旧服务器临时包
    ssh_cmd "sudo rm -f /tmp/${base}.tar.gz"
done

# 6️⃣ 拉取 docker-compose.yml 到原路径
echo "📥 下载 docker-compose.yml 到 $COMPOSE_FILE ..."
sudo mkdir -p "$(dirname "$COMPOSE_FILE")"
rsync_cmd "$OLD_SERVER_USER@$OLD_SERVER_IP:$COMPOSE_FILE" "$COMPOSE_FILE"

# 7️⃣ 加载镜像
echo "🔄 加载 Docker 镜像..."
docker load -i "$WORK_DIR/all-images.tar"

# 8️⃣ 启动服务
echo "▶️  启动 docker-compose 服务（在 $(dirname "$COMPOSE_FILE")）..."
cd "$(dirname "$COMPOSE_FILE")"
docker-compose up -d

# 9️⃣ 清理旧服务器
echo "🧹 清理旧服务器临时文件..."
ssh_cmd "rm -f /tmp/prepare-docker.sh && sudo rm -rf /tmp/docker-migration"

echo "✅ 迁移完成！服务已启动。"
echo "工作目录: $WORK_DIR"
echo "Compose 文件: $COMPOSE_FILE"
