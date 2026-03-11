#!/bin/bash
# docker-migrate.sh - 一键迁移 Docker 环境到新服务器（含 SSH 自动配置 + 命名卷修复）

set -e

# ======================
# 🔧 配置区（请按需修改）
# ======================

OLD_SERVER_USER="ubuntu"
OLD_SERVER_IP="123.13.13.132"

# 是否自动生成并部署 SSH 密钥（true/false）
AUTO_SETUP_SSH_KEY=true

# 是否自动 commit 所有正在运行的容器（true/false）
AUTO_COMMIT_RUNNING_CONTAINERS=true

# 要从旧服务器拉取的额外文件/目录（绝对路径，用于绑定挂载）
EXTRA_PATHS=(
    "/home/ubuntu/fa-data"
)

# docker-compose.yml 的路径（必须是绝对路径）
COMPOSE_FILE="/home/ubuntu/docker-compose.yml"

# 【新增】需要迁移的 Docker 命名卷名称列表
# 对应 docker-compose.yml 中 volumes 部分定义的卷名
# 注意：这里必须加上旧服务器上的项目前缀 (通常是目录名)
NAMED_VOLUMES=(
    "ubuntu_shared_fa_htmls"
    "ubuntu_shared_fa_uploads"
    "ubuntu_shared_fa_nginx"
    "ubuntu_shared_fa_cert"
)

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
    # 这里为了脚本连续性，使用 newgrp 重启当前脚本片段
    exec newgrp docker << END
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
    echo "🔄 Committing running containers to their original image names..."
    docker ps -q | while read cid; do
        name=$(docker inspect --format='{{.Name}}' "$cid" | sed 's/^\///')
        orig_image=$(docker inspect --format='{{.Config.Image}}' "$cid")
        echo "Committing container $name -> replacing image: $orig_image"
        docker commit "$cid" "$orig_image"
    done
fi

IMAGES=$(docker images --format "{{.Repository}}:{{.Tag}}" | grep -v "<none>:<none>")
if [ -n "$IMAGES" ]; then
  docker save $IMAGES -o /tmp/docker-migration/all-images.tar
else
  echo "⚠️  No tagged images found!"
  exit 1
fi

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

# 5️⃣ 同步 EXTRA_PATHS (绑定挂载的数据)
for path in "${EXTRA_PATHS[@]}"; do
    echo "📥 安全同步绑定挂载数据: $path (via sudo tar)..."
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

# 5.5️⃣ 【关键修复】迁移 Docker 命名卷 (Named Volumes)
if [[ ${#NAMED_VOLUMES[@]} -gt 0 ]]; then
    echo "📦 开始迁移 ${#NAMED_VOLUMES[@]} 个 Docker 命名卷..."
    
    for vol in "${NAMED_VOLUMES[@]}"; do
        echo "   🔄 处理卷: $vol"
        
        # 1. 旧服务器：打包卷数据 (_data 目录)
        # 注意：Docker 卷默认路径是 /var/lib/docker/volumes/<VOL_NAME>/_data
        echo "      [旧服务器] 打包数据..."
        ssh_cmd "sudo tar -czf /tmp/vol-${vol}.tar.gz -C /var/lib/docker/volumes/ '${vol}/_data'"
        
        # 2. 下载到本地临时目录
        echo "      [下载] 获取数据包..."
        rsync_cmd "$OLD_SERVER_USER@$OLD_SERVER_IP:/tmp/vol-${vol}.tar.gz" "$WORK_DIR/"
        
        # 3. 新服务器：先创建空卷（确保目录结构存在）
        echo "      [新服务器] 创建卷..."
        docker volume create "$vol"
        
        # 4. 获取新服务器上该卷的实际挂载点路径
        VOL_PATH=$(docker volume inspect "$vol" --format '{{ .Mountpoint }}')
        echo "      [新服务器] 卷路径为: $VOL_PATH"
        
        # 5. 解压数据
        # --strip-components=1 是因为 tar 包里是 'vol/_data/...'，我们要去掉 'vol' 这一层，直接放入 _data
        # 或者更稳妥的方式：解压到临时目录再移动，但这里直接用 strip-components 效率更高
        # 结构分析: tar 内容通常是 "vol_name/_data/file"。
        # 目标路径是: /var/lib/docker/volumes/vol_name/_data/file
        # 所以我们需要去掉第一层目录名 (vol_name)，让 _data 直接对齐到 VOL_PATH
        echo "      [新服务器] 恢复数据..."
        sudo tar -xzf "$WORK_DIR/vol-${vol}.tar.gz" -C "$VOL_PATH/.." --strip-components=1
        
        # 6. 修复权限 (可选，防止属主不对导致容器无法写入)
        # 通常 docker volume create 会设置正确的权限，但如果旧服务器是非 root 用户创建的，可能需要 chown
        # 这里暂时不做强制 chown，依赖 Docker 默认行为，如有报错可手动修复
        
        # 7. 清理旧服务器临时包
        ssh_cmd "sudo rm -f /tmp/vol-${vol}.tar.gz"
        
        echo "      ✅ 卷 $vol 迁移完成"
    done
else
    echo "ℹ️  未配置需要迁移的命名卷，跳过此步骤。"
fi

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

# 确保网络也存在（compose up 会自动创建，但显式创建更稳妥）
docker network create fa_bridge 2>/dev/null || true

docker compose up -d

# 9️⃣ 清理旧服务器
echo "🧹 清理旧服务器临时文件..."
ssh_cmd "rm -f /tmp/prepare-docker.sh && sudo rm -rf /tmp/docker-migration"

echo ""
echo "=========================================="
echo "✅ 迁移完成！服务已启动。"
echo "=========================================="
echo "📂 工作目录: $WORK_DIR"
echo "📄 Compose 文件: $COMPOSE_FILE"
echo ""
echo "🔍 验证建议:"
echo "1. 检查容器状态: docker compose ps"
echo "2. 检查卷数据: docker volume ls"
echo "3. 查看日志: docker compose logs -f"
echo ""
