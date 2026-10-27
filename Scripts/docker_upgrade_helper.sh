#!/bin/sh
# AX6600 Docker 备份、恢复与升级验证辅助脚本
# 兼容 OpenWrt POSIX sh / BusyBox ash 及 Linux/Bash 环境
set -eu

log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

# 确保命令可用，不存在则报错
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "缺少必要命令: $1"
        exit 1
    }
}

# -----------------------------------------------------------------------------
# 1. 备份子命令 (backup)
# -----------------------------------------------------------------------------
do_backup() {
    TARGET_DIR=""
    DOCKER_ROOT_DIR=""
    COMPOSE_DIR=""
    SKIP_CONTAINER_STOP=0

    while [ $# -gt 0 ]; do
        case "$1" in
            --target-dir)
                TARGET_DIR="$2"
                shift 2
                ;;
            --docker-dir)
                DOCKER_ROOT_DIR="$2"
                shift 2
                ;;
            --compose-dir)
                COMPOSE_DIR="$2"
                shift 2
                ;;
            --skip-stop)
                SKIP_CONTAINER_STOP=1
                shift
                ;;
            *)
                log_error "未知参数: $1"
                exit 1
                ;;
        esac
    done

    if [ -z "$TARGET_DIR" ]; then
        log_error "必须使用 --target-dir 指定备份目标目录"
        exit 1
    fi

    # 1. 探测 DockerRootDir（在 dockerd 停止前获取，绝不猜测默认目录）
    if [ -z "$DOCKER_ROOT_DIR" ]; then
        require_cmd docker
        DOCKER_ROOT_DIR=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)
        if [ -z "$DOCKER_ROOT_DIR" ]; then
            log_error "无法获取 DockerRootDir，dockerd 可能未运行或未安装。请检查服务或显式通过 --docker-dir 传入。"
            exit 1
        fi
    fi

    if [ ! -d "$DOCKER_ROOT_DIR" ]; then
        log_error "DockerRootDir 目录不存在: $DOCKER_ROOT_DIR"
        exit 1
    fi
    log_info "确认 DockerRootDir: $DOCKER_ROOT_DIR"

    # 2. 检查备份目标目录挂载状态及路径合法性
    mkdir -p "$TARGET_DIR"
    # 获取真实绝对路径
    TARGET_ABS=$(cd "$TARGET_DIR" && pwd -P)
    DOCKER_ABS=$(cd "$DOCKER_ROOT_DIR" && pwd -P)

    # 检查目标目录是否在 DockerRootDir 内部（防止递归无限打包）
    case "$TARGET_ABS" in
        "$DOCKER_ABS"/*|"$DOCKER_ABS")
            log_error "备份目标目录 ($TARGET_ABS) 不能在 DockerRootDir ($DOCKER_ABS) 内部！"
            exit 1
            ;;
    esac

    # 检查挂载点，必须确认真实挂载，且不能是 /overlay 或内存盘
    require_cmd df
    MNT_POINT=$(df -P "$TARGET_ABS" | awk 'NR==2{print $6}')
    MNT_DEV=$(df -P "$TARGET_ABS" | awk 'NR==2{print $1}')
    log_info "目标目录所属挂载点: $MNT_POINT (设备: $MNT_DEV)"

    if [ "$MNT_POINT" = "/overlay" ]; then
        log_error "目标目录位于 /overlay，系统升级后将被重置，备份必须保存在外部独立存储介质！"
        exit 1
    fi
    if [ "$MNT_POINT" = "/tmp" ] || [ "$MNT_DEV" = "tmpfs" ]; then
        log_error "目标目录位于内存文件系统 ($MNT_DEV)，严禁将大容量 Docker 数据备份至内存！"
        exit 1
    fi

    # 检查剩余空间是否足够
    AVAIL_KB=$(df -P "$TARGET_ABS" | awk 'NR==2{print $4}')
    NEED_KB=1024
    if [ -d "$DOCKER_ROOT_DIR/volumes" ]; then
        VOL_KB=$(du -sk "$DOCKER_ROOT_DIR/volumes" 2>/dev/null | awk '{print $1}' || echo "1024")
        NEED_KB=$((VOL_KB + 10240)) # 留 10MB 冗余
    fi
    if [ "$AVAIL_KB" -lt "$NEED_KB" ]; then
        log_error "目标存储空间不足！可用: ${AVAIL_KB}KB，所需约: ${NEED_KB}KB"
        exit 1
    fi

    # 3. 记录 Docker 自启动状态并关闭自启动（防止升级后在空目录自启）
    AUTOSTART_FILE="$TARGET_ABS/docker_autostart.state"
    if [ -x "/etc/init.d/dockerd" ]; then
        if /etc/init.d/dockerd enabled 2>/dev/null; then
            echo "1" > "$AUTOSTART_FILE"
            log_info "已记录 Docker 为开机自启状态，升级前临时关闭自启..."
            /etc/init.d/dockerd disable || true
        else
            echo "0" > "$AUTOSTART_FILE"
            log_info "Docker 原本非开机自启"
        fi
    else
        echo "0" > "$AUTOSTART_FILE"
    fi

    # 4. 导出容器清单、挂载点、网络与配置
    META_DIR="$TARGET_ABS/metadata"
    mkdir -p "$META_DIR"

    if command -v docker >/dev/null 2>&1; then
        log_info "正在导出容器列表与元数据..."
        docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' > "$META_DIR/containers_list.txt" 2>/dev/null || true
        docker inspect $(docker ps -aq 2>/dev/null) > "$META_DIR/containers_inspect.json" 2>/dev/null || echo "[]" > "$META_DIR/containers_inspect.json"
        docker network ls > "$META_DIR/networks.txt" 2>/dev/null || true

        # 扫描所有外部 Bind Mounts
        grep -o '"Source": "[^"]*"' "$META_DIR/containers_inspect.json" 2>/dev/null | awk -F'"' '{print $4}' | sort -u > "$META_DIR/bind_mounts_raw.txt" || true
        # 过滤排除内部挂载（排除空、/proc、/sys、/dev 及 DockerRootDir 内部路径）
        : > "$META_DIR/bind_mounts.txt"
        while IFS= read -r mpath; do
            [ -z "$mpath" ] && continue
            case "$mpath" in
                /proc*|/sys*|/dev*|/etc/resolv.conf|/etc/hosts|/etc/hostname|"$DOCKER_ABS"*)
                    continue
                    ;;
                *)
                    if [ -e "$mpath" ]; then
                        echo "$mpath" >> "$META_DIR/bind_mounts.txt"
                    fi
                    ;;
            esac
        done < "$META_DIR/bind_mounts_raw.txt"
    fi

    # 5. 导出应用 Compose 文件与系统配置
    CONFIG_DIR="$TARGET_ABS/config"
    mkdir -p "$CONFIG_DIR"
    [ -d "/etc/docker" ] && cp -r /etc/docker "$CONFIG_DIR/" 2>/dev/null || true
    [ -f "/etc/config/dockerd" ] && cp /etc/config/dockerd "$CONFIG_DIR/" 2>/dev/null || true
    [ -f "/etc/config/dockerman" ] && cp /etc/config/dockerman "$CONFIG_DIR/" 2>/dev/null || true

    COMPOSE_STORE="$TARGET_ABS/compose"
    mkdir -p "$COMPOSE_STORE"
    # 如果指定了 compose 目录或存在常见目录，归档 compose
    if [ -n "$COMPOSE_DIR" ] && [ -d "$COMPOSE_DIR" ]; then
        cp -r "$COMPOSE_DIR"/* "$COMPOSE_STORE/" 2>/dev/null || true
    fi
    for cpath in /opt/docker /opt/compose /root/compose; do
        if [ -d "$cpath" ]; then
            mkdir -p "$COMPOSE_STORE/$(basename "$cpath")"
            cp -r "$cpath"/* "$COMPOSE_STORE/$(basename "$cpath")/" 2>/dev/null || true
        fi
    done

    # 6. 数据库一致性逻辑备份（若检测到运行中的数据库）
    DB_DIR="$TARGET_ABS/database_dump"
    mkdir -p "$DB_DIR"
    if command -v docker >/dev/null 2>&1; then
        for cid in $(docker ps -q 2>/dev/null); do
            cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')
            cimg=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null)
            case "$cimg" in
                *mysql*|*mariadb*)
                    log_info "检测到 MySQL/MariaDB 容器: $cname ($cimg)，执行一致性逻辑 Dump..."
                    # 尝试 mysqldump，若用户有设置 MYSQL_ROOT_PASSWORD
                    if docker exec "$cid" which mysqldump >/dev/null 2>&1; then
                        DUMP_FILE="$DB_DIR/${cname}_dump.sql"
                        if ! docker exec "$cid" sh -c 'mysqldump -u root --all-databases 2>/dev/null || mysqldump -u root -p"$MYSQL_ROOT_PASSWORD" --all-databases' > "$DUMP_FILE" 2>/dev/null; then
                            # 如果指定了数据库备份但失败，严禁继续
                            log_warn "无法免密 Dump 容器 $cname，请手动备份数据库后再执行停机。"
                        else
                            log_info "已成功导出数据库至: $DUMP_FILE"
                        fi
                    fi
                    ;;
                *postgres*)
                    log_info "检测到 PostgreSQL 容器: $cname ($cimg)，执行 pg_dumpall..."
                    if docker exec "$cid" which pg_dumpall >/dev/null 2>&1; then
                        DUMP_FILE="$DB_DIR/${cname}_dump.sql"
                        docker exec "$cid" pg_dumpall -U postgres > "$DUMP_FILE" 2>/dev/null || true
                    fi
                    ;;
            esac
        done
    fi

    # 7. 优雅停机（容器 -> 守护进程）
    if [ "$SKIP_CONTAINER_STOP" -eq 0 ] && command -v docker >/dev/null 2>&1; then
        RUNNING_CONTAINERS=$(docker ps -q 2>/dev/null || true)
        if [ -n "$RUNNING_CONTAINERS" ]; then
            log_info "正在停止运行中的 Docker 容器..."
            docker stop $RUNNING_CONTAINERS >/dev/null 2>&1 || true
        fi
        if [ -x "/etc/init.d/dockerd" ]; then
            log_info "停止 dockerd 服务..."
            /etc/init.d/dockerd stop >/dev/null 2>&1 || true
        fi
    fi

    # 8. 打包数据（Named Volumes 与 Bind Mounts）
    require_cmd tar
    log_info "正在归档 Named Volumes..."
    VOL_ARCHIVE="$TARGET_ABS/docker_volumes.tar.gz"
    if [ -d "$DOCKER_ROOT_DIR/volumes" ]; then
        tar -czf "$VOL_ARCHIVE" -C "$DOCKER_ROOT_DIR" volumes
    else
        # 创建空归档保持结构一致
        mkdir -p "$TARGET_ABS/.empty_vol/volumes"
        tar -czf "$VOL_ARCHIVE" -C "$TARGET_ABS/.empty_vol" volumes
        rm -rf "$TARGET_ABS/.empty_vol"
    fi

    # 检查归档可读性与完整性
    tar -tzf "$VOL_ARCHIVE" >/dev/null 2>&1 || {
        log_error "Named Volumes 归档验证失败，文件损坏！"
        exit 1
    }

    # 打包 Bind Mounts 数据
    BIND_ARCHIVE="$TARGET_ABS/docker_bind_mounts.tar.gz"
    if [ -s "$META_DIR/bind_mounts.txt" ]; then
        log_info "正在归档 Bind Mounts 数据..."
        tar -czf "$BIND_ARCHIVE" -T "$META_DIR/bind_mounts.txt" 2>/dev/null || true
        if [ -f "$BIND_ARCHIVE" ]; then
            tar -tzf "$BIND_ARCHIVE" >/dev/null 2>&1 || {
                log_error "Bind Mounts 归档验证失败！"
                exit 1
            }
        fi
    fi

    # 9. 生成 SHA256 校验和清单
    log_info "生成校验和..."
    require_cmd sha256sum
    (
        cd "$TARGET_ABS"
        sha256sum docker_volumes.tar.gz > sha256sums.txt
        if [ -f "docker_bind_mounts.tar.gz" ]; then
            sha256sum docker_bind_mounts.tar.gz >> sha256sums.txt
        fi
        if [ -f "metadata/containers_inspect.json" ]; then
            sha256sum metadata/containers_inspect.json >> sha256sums.txt
        fi
    )

    log_info "Docker 完整备份完成，校验清单位于: $TARGET_ABS/sha256sums.txt"
}

# -----------------------------------------------------------------------------
# 2. 恢复子命令 (restore)
# -----------------------------------------------------------------------------
do_restore() {
    BACKUP_DIR=""
    TARGET_DATA_ROOT=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --target-data-root)
                TARGET_DATA_ROOT="$2"
                shift 2
                ;;
            *)
                log_error "未知恢复参数: $1"
                exit 1
                ;;
        esac
    done

    if [ -z "$BACKUP_DIR" ] || [ -z "$TARGET_DATA_ROOT" ]; then
        log_error "恢复必须同时指定 --backup-dir 和 --target-data-root"
        exit 1
    fi

    if [ ! -d "$BACKUP_DIR" ]; then
        log_error "备份目录不存在: $BACKUP_DIR"
        exit 1
    fi

    # 1. 严格校验备份归档完整性
    require_cmd sha256sum
    require_cmd tar
    if [ ! -f "$BACKUP_DIR/sha256sums.txt" ] || [ ! -f "$BACKUP_DIR/docker_volumes.tar.gz" ]; then
        log_error "备份文件不完整（缺少 sha256sums.txt 或 docker_volumes.tar.gz）！"
        exit 1
    fi

    log_info "正在核对备份文件 SHA256 校验和..."
    (
        cd "$BACKUP_DIR"
        sha256sum -c sha256sums.txt
    ) || {
        log_error "备份文件校验失败，数据可能已损坏！"
        exit 1
    }

    # 2. 检查目标数据根挂载状态，不依赖升级前的旧环境变量
    mkdir -p "$TARGET_DATA_ROOT"
    TARGET_DATA_ABS=$(cd "$TARGET_DATA_ROOT" && pwd -P)
    require_cmd df
    MNT_POINT=$(df -P "$TARGET_DATA_ABS" | awk 'NR==2{print $6}')
    MNT_DEV=$(df -P "$TARGET_DATA_ABS" | awk 'NR==2{print $1}')
    log_info "目标 DataRoot 挂载点: $MNT_POINT (设备: $MNT_DEV)"

    if [ "$MNT_POINT" = "/overlay" ]; then
        log_warn "目标 DataRoot 位于 /overlay，若内部空间不足请考虑挂载外部盘。"
    fi
    if [ "$MNT_POINT" = "/tmp" ] || [ "$MNT_DEV" = "tmpfs" ]; then
        log_error "目标 DataRoot 位于内存系统，禁止恢复！"
        exit 1
    fi

    # 3. 恢复配置文件与 DataRoot 路径配置
    if [ -d "$BACKUP_DIR/config" ]; then
        log_info "正在恢复 Docker 配置文件..."
        [ -d "$BACKUP_DIR/config/etc_docker" ] && cp -r "$BACKUP_DIR/config/etc_docker" /etc/docker 2>/dev/null || true
        [ -f "$BACKUP_DIR/config/config_dockerd" ] && cp "$BACKUP_DIR/config/config_dockerd" /etc/config/dockerd 2>/dev/null || true
        [ -f "$BACKUP_DIR/config/config_dockerman" ] && cp "$BACKUP_DIR/config/config_dockerman" /etc/config/dockerman 2>/dev/null || true

        # 确保 /etc/config/dockerd 中的 data_root 正确指向新目标目录
        if command -v uci >/dev/null 2>&1 && [ -f "/etc/config/dockerd" ]; then
            uci set dockerd.globals.data_root="$TARGET_DATA_ABS" 2>/dev/null || true
            uci commit dockerd 2>/dev/null || true
        fi
        # 确保 /etc/docker/daemon.json 中 data-root 同步（若存在）
        if [ -f "/etc/docker/daemon.json" ] && command -v sed >/dev/null 2>&1; then
            sed -i "s|\"data-root\": *\"[^\"]*\"|\"data-root\": \"$TARGET_DATA_ABS\"|g" /etc/docker/daemon.json 2>/dev/null || true
        fi
    fi

    # 4. 恢复 Named Volumes
    log_info "正在恢复 Named Volumes 至: $TARGET_DATA_ABS..."
    tar -xzf "$BACKUP_DIR/docker_volumes.tar.gz" -C "$TARGET_DATA_ABS"

    # 5. 恢复 Bind Mounts 数据
    if [ -f "$BACKUP_DIR/docker_bind_mounts.tar.gz" ]; then
        log_info "正在恢复 Bind Mounts 数据至宿主机原路径..."
        tar -xzf "$BACKUP_DIR/docker_bind_mounts.tar.gz" -C / 2>/dev/null || true
    fi

    # 6. 恢复 Compose 编排文件
    if [ -d "$BACKUP_DIR/compose" ]; then
        log_info "正在恢复 Compose 编排文件..."
        for cdir in "$BACKUP_DIR/compose"/*; do
            if [ -d "$cdir" ]; then
                base_name=$(basename "$cdir")
                target_base="/opt/$base_name"
                mkdir -p "$target_base"
                cp -r "$cdir"/* "$target_base/" 2>/dev/null || true
            fi
        done
    fi

    # 7. 启动 dockerd 并恢复开机自启
    if [ -x "/etc/init.d/dockerd" ]; then
        log_info "正在启动 dockerd 服务..."
        /etc/init.d/dockerd start || {
            log_error "dockerd 启动失败，请检查系统日志 (logread)。"
            exit 1
        }

        # 检查原自启状态
        if [ -f "$BACKUP_DIR/docker_autostart.state" ]; then
            WAS_ENABLED=$(cat "$BACKUP_DIR/docker_autostart.state" 2>/dev/null || echo "0")
            if [ "$WAS_ENABLED" = "1" ]; then
                log_info "正在恢复 dockerd 开机自启..."
                /etc/init.d/dockerd enable || true
            fi
        fi
    fi

    # 8. 唤醒/拉起容器
    # 方式：优先使用恢复出来的 Compose 项目拉起；若无 compose，根据 metadata 清单进行重建提示
    log_info "正在检查恢复的容器服务..."
    if command -v docker-compose >/dev/null 2>&1; then
        find /opt -name "docker-compose.yml" -o -name "docker-compose.yaml" 2>/dev/null | while read -r comp_file; do
            cd "$(dirname "$comp_file")"
            log_info "在 $(pwd) 执行 docker-compose up -d..."
            docker-compose up -d 2>/dev/null || true
        done
    fi

    log_info "Docker 数据与配置恢复完成！"
}

# -----------------------------------------------------------------------------
# 3. 升级前唯一固件校验与容量预检 (precheck_image)
# -----------------------------------------------------------------------------
do_precheck_image() {
    IMAGE_PATH="${1:-}"
    if [ -z "$IMAGE_PATH" ]; then
        log_error "必须传入固件镜像文件路径"
        exit 1
    fi

    if [ ! -f "$IMAGE_PATH" ]; then
        log_error "固件文件不存在或匹配不唯一: $IMAGE_PATH"
        exit 1
    fi

    IMG_SIZE=$(wc -c < "$IMAGE_PATH")
    IMG_SIZE_MB=$((IMG_SIZE / 1024 / 1024))
    log_info "固件文件确认: $IMAGE_PATH (大小: ${IMG_SIZE_MB}MB, ${IMG_SIZE} 字节)"

    # 1. 检查固件头部兼容性（只读模拟检测）
    if command -v sysupgrade >/dev/null 2>&1; then
        log_info "执行 sysupgrade -T 格式与机型兼容性预检..."
        if ! sysupgrade -T "$IMAGE_PATH"; then
            log_error "固件与当前硬件平台不兼容，禁止刷入！"
            exit 1
        fi
        log_info "固件平台兼容性校验通过"
    fi

    # 2. 检查目标 rootfs 分区大小
    if [ -b "/dev/mmcblk0" ] && command -v fdisk >/dev/null 2>&1; then
        ROOTFS_SEC=$(fdisk -l /dev/mmcblk0 2>/dev/null | grep -E "rootfs|rootfs_1" | awk '{print $4}' | sort -n | tail -n 1 || true)
        if [ -n "$ROOTFS_SEC" ]; then
            # 扇区通常为 512 字节
            PART_BYTES=$((ROOTFS_SEC * 512))
            PART_MB=$((PART_BYTES / 1024 / 1024))
            log_info "检测到目标 rootfs 分区容量约: ${PART_MB}MB"
            # 必须预留至少 50MB 空间
            if [ "$PART_BYTES" -le "$((IMG_SIZE + 52428800))" ]; then
                log_error "目标分区容量 (${PART_MB}MB) 不足，刷入 ${IMG_SIZE_MB}MB 固件将无法保留充足 overlay！"
                exit 1
            fi
            log_info "目标分区容量安全校验通过"
        fi
    fi
}

# -----------------------------------------------------------------------------
# 4. 升级后 NSS 遗留项清理 (clean_nss)
# -----------------------------------------------------------------------------
do_clean_nss() {
    if ! command -v uci >/dev/null 2>&1; then
        log_info "非 OpenWrt 环境，跳过 UCI NSS 清理"
        return 0
    fi

    if uci -q get firewall.qcanssecm >/dev/null 2>&1; then
        SEC_TYPE=$(uci -q get firewall.qcanssecm || true)
        SCRIPT_PATH=$(uci -q get firewall.qcanssecm.path || true)
        log_info "发现 firewall.qcanssecm (类型: $SEC_TYPE, 路径: $SCRIPT_PATH)"

        # 仅当确认属于 include 且指向废弃 NSS/ECM 脚本时才删除，防止误删用户自定义规则
        case "$SCRIPT_PATH" in
            *nss*|*ecm*|/etc/firewall.nss*|"")
                log_info "确认属于废弃 NSS 防火墙钩子，执行安全清理..."
                uci delete firewall.qcanssecm
                uci commit firewall
                [ -x "/etc/init.d/firewall" ] && /etc/init.d/firewall reload >/dev/null 2>&1 || true
                log_info "NSS 废弃项已清理"
                ;;
            *)
                log_warn "firewall.qcanssecm 指向未知脚本 ($SCRIPT_PATH)，保留不做修改。"
                ;;
        esac
    else
        log_info "未检测到废弃 NSS 防火墙钩子"
    fi
}

# -----------------------------------------------------------------------------
# 5. 升级后运行时验收 (verify_runtime)
# -----------------------------------------------------------------------------
do_verify_runtime() {
    CHECK_TARGET="${1:-all}"
    FAILED=0

    # 1. 验证 PPE 硬件加速
    if [ "$CHECK_TARGET" = "all" ] || [ "$CHECK_TARGET" = "ppe" ]; then
        log_info "=== 验证 PPE 硬件加速与 Flowtable ==="
        PPE_OK=0
        if command -v nft >/dev/null 2>&1; then
            if nft list tables 2>/dev/null | grep -q "flowtable"; then
                PPE_OK=1
            fi
        fi
        if dmesg 2>/dev/null | grep -qiE "ppe|flowtable.*offload"; then
            PPE_OK=1
        fi

        if [ "$PPE_OK" -eq 1 ]; then
            log_info "PPE / Flowtable 硬件卸载状态: 已生效"
        else
            log_error "PPE / Flowtable 硬件卸载未检测到生效！"
            FAILED=1
        fi
    fi

    # 2. 验证 Docker 容器网络
    if [ "$CHECK_TARGET" = "all" ] || [ "$CHECK_TARGET" = "docker" ]; then
        log_info "=== 验证 Docker 网络与端口转发 ==="
        if command -v docker >/dev/null 2>&1; then
            if docker run --rm alpine ping -c 2 223.5.5.5 >/dev/null 2>&1; then
                log_info "Docker 容器出网与 NAT 转发测试: 正常"
            else
                log_error "Docker 容器网络出网测试失败！"
                FAILED=1
            fi
        else
            log_warn "Docker 未安装，跳过 Docker 网络测试"
        fi
    fi

    # 3. 验证 PassWall2 节点与代理连通性
    if [ "$CHECK_TARGET" = "all" ] || [ "$CHECK_TARGET" = "passwall" ]; then
        log_info "=== 验证 PassWall2 代理核心与握手 ==="
        PW_CORE=""
        # 定位实际运行的核心进程
        if pgrep -x sing-box >/dev/null 2>&1; then
            PW_CORE="sing-box"
        elif pgrep -x xray >/dev/null 2>&1; then
            PW_CORE="xray"
        fi

        if [ -n "$PW_CORE" ]; then
            log_info "PassWall2 当前活动核心: $PW_CORE"
            # 取得 socks 端口（默认 1080 或 1081）
            SOCKS_PORT=1080
            if [ -f "/var/etc/passwall2/TCP.json" ]; then
                PORT_FOUND=$(grep -o '"port": *[0-9]*' /var/etc/passwall2/TCP.json 2>/dev/null | head -n 1 | awk '{print $2}')
                [ -n "$PORT_FOUND" ] && SOCKS_PORT="$PORT_FOUND"
            fi
            log_info "正在通过本地 SOCKS 端口 ($SOCKS_PORT) 真实发起 TLS 握手测试..."
            if command -v curl >/dev/null 2>&1; then
                if curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" -m 10 -s -I https://www.google.com >/dev/null 2>&1; then
                    log_info "PassWall2 代理节点握手验证通过: 成功建立连接"
                else
                    log_error "PassWall2 代理握手失败，未能通过 SOCKS 端口连通目标！"
                    FAILED=1
                fi
            else
                log_warn "缺少 curl 命令，无法发起代理握手测试"
            fi
        else
            log_warn "PassWall2 核心未在运行，跳过代理连通性测试"
        fi
    fi

    if [ "$FAILED" -ne 0 ]; then
        log_error "运行时验收未完全通过，存在失败项！"
        exit 1
    fi
    log_info "运行时验收全部通过！"
}

# -----------------------------------------------------------------------------
# 主入口调度
# -----------------------------------------------------------------------------
case "${1:-}" in
    backup)
        shift
        do_backup "$@"
        ;;
    restore)
        shift
        do_restore "$@"
        ;;
    precheck)
        shift
        do_precheck_image "$@"
        ;;
    clean-nss)
        shift
        do_clean_nss "$@"
        ;;
    verify)
        shift
        do_verify_runtime "$@"
        ;;
    *)
        echo "用法: $0 {backup|restore|precheck|clean-nss|verify} [参数...]"
        exit 1
        ;;
esac
