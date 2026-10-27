#!/bin/sh
# AX6600 Docker 备份、恢复与升级验证辅助脚本
# 兼容 OpenWrt POSIX sh / BusyBox ash 及 Linux/Bash 环境
set -eu

SYS_ROOT="${SYS_ROOT:-}"

log_info() {
    echo "[INFO] $*"
}

log_warn() {
    echo "[WARN] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

# 确保命令可用，不存在则报错退出
require_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        log_error "缺少必要命令: $1"
        exit 1
    }
}

# 获取带 SYS_ROOT 隔离前缀的系统路径
get_sys_path() {
    p="$1"
    if [ -n "$SYS_ROOT" ]; then
        echo "${SYS_ROOT%/}$p"
    else
        echo "$p"
    fi
}

# 解析带 SYS_ROOT 隔离前缀的真实宿主路径
resolve_bind_path() {
    raw_p="$1"
    if [ -n "$SYS_ROOT" ]; then
        case "$raw_p" in
            "$SYS_ROOT"*)
                echo "$raw_p"
                ;;
            *)
                if [ -e "${SYS_ROOT%/}$raw_p" ]; then
                    echo "${SYS_ROOT%/}$raw_p"
                else
                    echo "$raw_p"
                fi
                ;;
        esac
    else
        echo "$raw_p"
    fi
}

# 挂载安全性与存储介质类型核查
check_mount_safety() {
    target_path="$1"
    label="$2"

    if [ ! -d "$target_path" ]; then
        log_error "$label 目录不存在: $target_path"
        exit 1
    fi

    target_abs=$(cd "$target_path" && pwd -P)

    df_out=$(df -P "$target_abs" 2>/dev/null || true)
    if [ -z "$df_out" ]; then
        log_error "无法获取 $label 挂载信息 (df 失败)"
        exit 1
    fi

    mnt_dev=$(echo "$df_out" | awk 'NR==2{print $1}')
    avail_kb=$(echo "$df_out" | awk 'NR==2{print $4}')
    mnt_point=$(echo "$df_out" | awk 'NR==2{print $6}')

    log_info "$label 挂载信息: 挂载点=$mnt_point, 设备=$mnt_dev, 可用=${avail_kb}KB"

    # 严禁目标位于根分区、/overlay 或只读 rom
    if [ "$mnt_point" = "/" ] || [ "$mnt_point" = "/overlay" ] || [ "$mnt_point" = "/rom" ]; then
        log_error "$label 位于根文件系统或 /overlay ($mnt_point, 设备: $mnt_dev)！系统升级后将被重置，严禁在此操作！必须挂载外部独立存储介质。"
        exit 1
    fi

    # 严禁目标位于内部 overlayfs、tmpfs 或内存盘
    case "$mnt_dev" in
        *overlay*|rootfs|tmpfs|ramfs|shm)
            log_error "$label 存储设备为易失或升级重置设备 ($mnt_dev)，严禁在此操作！"
            exit 1
            ;;
    esac
}

# 剩余空间核查
check_space_safety() {
    target_path="$1"
    need_kb="$2"
    target_abs=$(cd "$target_path" && pwd -P)
    avail_kb=$(df -P "$target_abs" | awk 'NR==2{print $4}')
    if [ -z "$avail_kb" ] || [ "$avail_kb" -lt "$need_kb" ]; then
        log_error "目标存储空间不足！可用: ${avail_kb:-0}KB，所需估算: ${need_kb}KB"
        exit 1
    fi
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
            --sys-root)
                SYS_ROOT="$2"
                shift 2
                ;;
            --skip-stop)
                SKIP_CONTAINER_STOP=1
                shift
                ;;
            *)
                log_error "未知备份参数: $1"
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
        if ! docker info >/dev/null 2>&1; then
            log_error "无法连接 Docker 守护进程，dockerd 可能未运行。请启动服务或显式通过 --docker-dir 传入。"
            exit 1
        fi
        DOCKER_ROOT_DIR=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)
        if [ -z "$DOCKER_ROOT_DIR" ]; then
            log_error "获取 DockerRootDir 为空，无法确认数据存储位置！"
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
    check_mount_safety "$TARGET_DIR" "备份目标目录"

    TARGET_ABS=$(cd "$TARGET_DIR" && pwd -P)
    DOCKER_ABS=$(cd "$DOCKER_ROOT_DIR" && pwd -P)

    # 检查目标目录是否在 DockerRootDir 内部（防止递归无限打包）
    case "$TARGET_ABS" in
        "$DOCKER_ABS"/*|"$DOCKER_ABS")
            log_error "备份目标目录 ($TARGET_ABS) 不能在 DockerRootDir ($DOCKER_ABS) 内部！"
            exit 1
            ;;
    esac

    # 备份恢复脚本自身到目标存储，确保升级重启后 /tmp 丢失时仍可直接执行恢复
    SCRIPT_SELF="$0"
    if [ -f "$SCRIPT_SELF" ]; then
        cp "$SCRIPT_SELF" "$TARGET_ABS/docker_upgrade_helper.sh"
        chmod +x "$TARGET_ABS/docker_upgrade_helper.sh"
        log_info "已保存升级恢复辅助脚本至: $TARGET_ABS/docker_upgrade_helper.sh"
    fi

    META_DIR="$TARGET_ABS/metadata"
    mkdir -p "$META_DIR"
    COMPOSE_STORE="$TARGET_ABS/compose"
    mkdir -p "$COMPOSE_STORE"
    STANDALONE_STORE="$TARGET_ABS/standalone"
    mkdir -p "$STANDALONE_STORE"
    COMPOSE_MANIFEST="$META_DIR/compose_manifest.tsv"
    : > "$COMPOSE_MANIFEST"
    STANDALONE_MANIFEST="$META_DIR/standalone_manifest.txt"
    : > "$STANDALONE_MANIFEST"
    BIND_MOUNTS_FILE="$META_DIR/bind_mounts.txt"
    : > "$BIND_MOUNTS_FILE"

    # 空间估算基准值（20MB 冗余）
    TOTAL_NEED_KB=20480

    # 3. 守护进程运行期间导出清单、网络与配置
    if command -v docker >/dev/null 2>&1; then
        log_info "正在导出容器列表与元数据..."
        if ! docker ps -a --format '{{.ID}}\t{{.Names}}\t{{.Image}}\t{{.Status}}' > "$META_DIR/containers_list.txt" 2>/dev/null; then
            log_error "执行 docker ps 失败，无法连接 Docker 守护进程！"
            exit 1
        fi

        C_IDS=$(docker ps -aq 2>/dev/null || true)
        if [ -n "$C_IDS" ]; then
            if ! docker inspect $C_IDS > "$META_DIR/containers_inspect.json" 2>/dev/null; then
                log_error "导出容器 inspect 信息失败！"
                exit 1
            fi
        else
            echo "[]" > "$META_DIR/containers_inspect.json"
        fi

        if ! docker network ls > "$META_DIR/networks.txt" 2>/dev/null; then
            log_error "导出网络列表失败！"
            exit 1
        fi

        # 处理 Compose 项目与独立容器
        if [ -n "$C_IDS" ]; then
            for cid in $C_IDS; do
                cname=$(docker inspect -f '{{.Name}}' "$cid" 2>/dev/null | tr -d '/')
                cimg=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>/dev/null || true)
                is_compose=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$cid" 2>/dev/null || true)
                comp_workdir=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$cid" 2>/dev/null || true)
                comp_config=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$cid" 2>/dev/null || true)

                if [ -n "$is_compose" ] && [ -n "$comp_workdir" ]; then
                    actual_workdir=$(resolve_bind_path "$comp_workdir")
                    if [ ! -d "$actual_workdir" ]; then
                        if [ -n "$comp_config" ]; then
                            actual_config=$(resolve_bind_path "$comp_config")
                            if [ -f "$actual_config" ]; then
                                actual_workdir=$(dirname "$actual_config")
                            fi
                        fi
                    fi

                    if [ -d "$actual_workdir" ]; then
                        if ! grep -q "^$is_compose	" "$COMPOSE_MANIFEST" 2>/dev/null; then
                            log_info "发现 Compose 项目: $is_compose (目录: $actual_workdir)"
                            router_workdir="$comp_workdir"
                            if [ -n "$SYS_ROOT" ]; then
                                router_workdir="${actual_workdir#$SYS_ROOT}"
                                router_workdir="/${router_workdir#/}"
                            fi
                            echo "$is_compose	$router_workdir	${comp_config:-$router_workdir/docker-compose.yml}" >> "$COMPOSE_MANIFEST"
                            # 打包整个项目目录（包含 .env 等隐藏文件）
                            tar -czf "$COMPOSE_STORE/${is_compose}.tar.gz" -C "$actual_workdir" . || {
                                log_error "归档 Compose 项目 $is_compose 失败！"
                                exit 1
                            }
                            c_kb=$(du -sk "$actual_workdir" 2>/dev/null | awk '{print $1}' || echo 0)
                            TOTAL_NEED_KB=$((TOTAL_NEED_KB + c_kb))
                        fi
                    else
                        log_error "Compose 项目 $is_compose 的工作目录 $comp_workdir 不存在，无法完整备份！"
                        exit 1
                    fi
                else
                    log_info "发现非 Compose 独立容器: $cname (镜像: $cimg)"
                    if [ -z "$cimg" ]; then
                        log_error "非 Compose 容器 $cname 缺失镜像信息，无法重建！"
                        exit 1
                    fi
                    echo "$cname" >> "$STANDALONE_MANIFEST"

                    # 检查可写层改动
                    has_diff=0
                    diff_out=$(docker diff "$cid" 2>/dev/null || true)
                    filtered_diff=$(echo "$diff_out" | grep -vE "^[ACD] (/tmp|/run|/var/log|/var/run|/dev)" || true)
                    img_for_run="$cimg"
                    if [ -n "$filtered_diff" ]; then
                        has_diff=1
                        log_info "容器 $cname 可写层存在变动，执行 commit 保存增量镜像快照..."
                        snap_tag="backup-snapshot-$cname:latest"
                        docker commit "$cid" "$snap_tag" || {
                            log_error "容器 $cname commit 快照失败！"
                            exit 1
                        }
                        docker save "$snap_tag" -o "$STANDALONE_STORE/image_${cname}.tar" || {
                            log_error "导出容器 $cname 快照镜像失败！"
                            exit 1
                        }
                        img_for_run="$snap_tag"
                        i_kb=$(du -sk "$STANDALONE_STORE/image_${cname}.tar" 2>/dev/null | awk '{print $1}' || echo 0)
                        TOTAL_NEED_KB=$((TOTAL_NEED_KB + i_kb))
                    fi

                    # 生成独立容器重建脚本
                    rec_script="$STANDALONE_STORE/recreate_${cname}.sh"
                    cnet=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid" 2>/dev/null || true)
                    crestart=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$cid" 2>/dev/null || true)
                    cpriv=$(docker inspect -f '{{.HostConfig.Privileged}}' "$cid" 2>/dev/null || true)

                    cat << EOF_REC > "$rec_script"
#!/bin/sh
set -e
echo "正在重建独立容器: $cname..."
docker rm -f "$cname" 2>/dev/null || true
EOF_REC
                    if [ "$has_diff" -eq 1 ]; then
                        echo "docker load -i \"\$STANDALONE_DIR/image_${cname}.tar\"" >> "$rec_script"
                    fi
                    run_line="docker run -d --name \"$cname\""
                    [ -n "$cnet" ] && [ "$cnet" != "default" ] && run_line="$run_line --net \"$cnet\""
                    [ -n "$crestart" ] && [ "$crestart" != "no" ] && run_line="$run_line --restart \"$crestart\""
                    [ "$cpriv" = "true" ] && run_line="$run_line --privileged"

                    binds=$(docker inspect -f '{{range .HostConfig.Binds}}{{.}} {{end}}' "$cid" 2>/dev/null || true)
                    for b in $binds; do
                        [ -n "$b" ] && run_line="$run_line -v \"$b\""
                    done

                    run_line="$run_line \"$img_for_run\""
                    echo "$run_line" >> "$rec_script"
                    chmod +x "$rec_script"
                fi
            done
        fi

        # 处理显式指定的 Compose 目录
        if [ -n "$COMPOSE_DIR" ] && [ -d "$COMPOSE_DIR" ]; then
            comp_abs=$(cd "$COMPOSE_DIR" && pwd -P)
            pname=$(basename "$comp_abs")
            if ! grep -q "^$pname	" "$COMPOSE_MANIFEST" 2>/dev/null; then
                log_info "归档显式指定的 Compose 目录: $comp_abs"
                echo "$pname	$comp_abs	$comp_abs/docker-compose.yml" >> "$COMPOSE_MANIFEST"
                tar -czf "$COMPOSE_STORE/${pname}.tar.gz" -C "$comp_abs" . || {
                    log_error "归档 Compose 目录 $comp_abs 失败！"
                    exit 1
                }
                c_kb=$(du -sk "$comp_abs" 2>/dev/null | awk '{print $1}' || echo 0)
                TOTAL_NEED_KB=$((TOTAL_NEED_KB + c_kb))
            fi
        fi

        # 扫描外部 Bind Mounts
        : > "$META_DIR/bind_mounts_raw.txt"
        grep -o '"Source": "[^"]*"' "$META_DIR/containers_inspect.json" 2>/dev/null | awk -F'"' '{print $4}' >> "$META_DIR/bind_mounts_raw.txt" || true
        grep -o '"/[^"]*:[^"]*"' "$META_DIR/containers_inspect.json" 2>/dev/null | awk -F'"' '{print $2}' | awk -F':' '{print $1}' >> "$META_DIR/bind_mounts_raw.txt" || true
        sort -u "$META_DIR/bind_mounts_raw.txt" -o "$META_DIR/bind_mounts_raw.txt" || true
        while IFS= read -r mpath; do
            [ -z "$mpath" ] && continue
            case "$mpath" in
                /proc*|/sys*|/dev*|/etc/resolv.conf|/etc/hosts|/etc/hostname|"$DOCKER_ABS"*)
                    continue
                    ;;
                *)
                    actual_path=$(resolve_bind_path "$mpath")
                    if [ -e "$actual_path" ]; then
                        echo "$mpath" >> "$BIND_MOUNTS_FILE"
                        b_kb=$(du -sk "$actual_path" 2>/dev/null | awk '{print $1}' || echo 0)
                        TOTAL_NEED_KB=$((TOTAL_NEED_KB + b_kb))
                    else
                        log_error "容器引用的外部挂载路径不存在: $mpath ，无法保证备份完整！"
                        exit 1
                    fi
                    ;;
            esac
        done < "$META_DIR/bind_mounts_raw.txt"
    fi

    # 计算 Named Volumes 容量
    if [ -d "$DOCKER_ROOT_DIR/volumes" ]; then
        v_kb=$(du -sk "$DOCKER_ROOT_DIR/volumes" 2>/dev/null | awk '{print $1}' || echo 0)
        TOTAL_NEED_KB=$((TOTAL_NEED_KB + v_kb))
    fi

    # 完整覆盖全部待备份数据的空间检查
    check_space_safety "$TARGET_ABS" "$TOTAL_NEED_KB"

    # 4. 记录原开机自启状态并在升级前安全禁用
    AUTOSTART_FILE="$TARGET_ABS/docker_autostart.state"
    INIT_DOCKERD="$(get_sys_path /etc/init.d/dockerd)"
    WAS_ENABLED="0"
    if [ -x "$INIT_DOCKERD" ]; then
        if "$INIT_DOCKERD" enabled 2>/dev/null; then
            WAS_ENABLED="1"
            echo "1" > "$AUTOSTART_FILE"
            log_info "已记录 Docker 为开机自启状态，升级前临时禁用自启以防在空目录误启动..."
            "$INIT_DOCKERD" disable || {
                log_error "无法禁用 dockerd 开机自启！"
                exit 1
            }
            if "$INIT_DOCKERD" enabled 2>/dev/null; then
                log_error "dockerd 自启禁用验证失败！"
                exit 1
            fi
        else
            echo "0" > "$AUTOSTART_FILE"
            log_info "Docker 原本非开机自启"
        fi
    else
        echo "0" > "$AUTOSTART_FILE"
    fi

    # 5. 优雅停机（容器 -> 守护进程）
    if [ "$SKIP_CONTAINER_STOP" -eq 0 ]; then
        if command -v docker >/dev/null 2>&1; then
            RUNNING=$(docker ps -q 2>/dev/null || true)
            if [ -n "$RUNNING" ]; then
                log_info "正在停止运行中的 Docker 容器以保证冷备一致性..."
                if ! docker stop $RUNNING >/dev/null; then
                    log_error "停止容器失败！无法保证冷备数据一致性。若需恢复原服务状态，请执行: $INIT_DOCKERD start"
                    [ "$WAS_ENABLED" = "1" ] && [ -x "$INIT_DOCKERD" ] && "$INIT_DOCKERD" enable 2>/dev/null || true
                    exit 1
                fi
            fi
        fi

        if [ -x "$INIT_DOCKERD" ]; then
            log_info "停止 dockerd 守护进程..."
            if ! "$INIT_DOCKERD" stop >/dev/null; then
                log_error "停止 dockerd 服务失败！"
                [ "$WAS_ENABLED" = "1" ] && "$INIT_DOCKERD" enable 2>/dev/null || true
                exit 1
            fi
            if pgrep -x dockerd >/dev/null 2>&1; then
                log_error "dockerd 进程未能成功停止！"
                [ "$WAS_ENABLED" = "1" ] && "$INIT_DOCKERD" enable 2>/dev/null || true
                exit 1
            fi
        fi
    fi

    # 6. 统一格式备份配置
    CONFIG_DIR="$TARGET_ABS/config"
    mkdir -p "$CONFIG_DIR"
    ETC_DIR="$(get_sys_path /etc)"
    CONFIG_DIR_HOST="$(get_sys_path /etc/config)"

    if [ -d "$ETC_DIR/docker" ]; then
        mkdir -p "$CONFIG_DIR/etc_docker"
        cp -r "$ETC_DIR/docker/." "$CONFIG_DIR/etc_docker/" || {
            log_error "备份 $ETC_DIR/docker 失败！"
            exit 1
        }
    fi
    if [ -f "$CONFIG_DIR_HOST/dockerd" ]; then
        cp "$CONFIG_DIR_HOST/dockerd" "$CONFIG_DIR/config_dockerd" || {
            log_error "备份 $CONFIG_DIR_HOST/dockerd 失败！"
            exit 1
        }
    fi
    if [ -f "$CONFIG_DIR_HOST/dockerman" ]; then
        cp "$CONFIG_DIR_HOST/dockerman" "$CONFIG_DIR/config_dockerman" || {
            log_error "备份 $CONFIG_DIR_HOST/dockerman 失败！"
            exit 1
        }
    fi

    # 7. 归档 Named Volumes 并校验完整性
    require_cmd tar
    VOL_ARCHIVE="$TARGET_ABS/docker_volumes.tar.gz"
    if [ -d "$DOCKER_ROOT_DIR/volumes" ]; then
        log_info "正在归档 Named Volumes..."
        tar -czf "$VOL_ARCHIVE" -C "$DOCKER_ROOT_DIR" volumes || {
            log_error "Named Volumes 归档打包失败！"
            exit 1
        }
        tar -tzf "$VOL_ARCHIVE" >/dev/null 2>&1 || {
            log_error "Named Volumes 归档验证失败，文件损坏！"
            exit 1
        }
        TAR_VOL_LIST=$(tar -tzf "$VOL_ARCHIVE")
        for vitem in "$DOCKER_ROOT_DIR/volumes"/*; do
            [ -e "$vitem" ] || continue
            vbase=$(basename "$vitem")
            if ! echo "$TAR_VOL_LIST" | grep -q "volumes/$vbase"; then
                log_error "Named Volumes 归档遗漏了 volume: $vbase！"
                exit 1
            fi
        done
    else
        mkdir -p "$TARGET_ABS/.empty_vol/volumes"
        tar -czf "$VOL_ARCHIVE" -C "$TARGET_ABS/.empty_vol" volumes
        rm -rf "$TARGET_ABS/.empty_vol"
        tar -tzf "$VOL_ARCHIVE" >/dev/null 2>&1 || {
            log_error "创建空 Volumes 归档失败！"
            exit 1
        }
    fi

    # 8. 归档 Bind Mounts 并校验完整性
    BIND_ARCHIVE="$TARGET_ABS/docker_bind_mounts.tar.gz"
    if [ -s "$BIND_MOUNTS_FILE" ]; then
        log_info "正在归档外部 Bind Mounts 数据..."
        TAR_FILE_LIST="$META_DIR/tar_bind_list.txt"
        : > "$TAR_FILE_LIST"
        if [ -n "$SYS_ROOT" ]; then
            while IFS= read -r mpath; do
                [ -z "$mpath" ] && continue
                actual_p=$(resolve_bind_path "$mpath")
                rel_p="${actual_p#$SYS_ROOT}"
                rel_p="${rel_p#/}"
                echo "$rel_p" >> "$TAR_FILE_LIST"
            done < "$BIND_MOUNTS_FILE"
            tar -czf "$BIND_ARCHIVE" -C "$SYS_ROOT" -T "$TAR_FILE_LIST" || {
                log_error "Bind Mounts 归档打包失败！"
                exit 1
            }
        else
            tar -czf "$BIND_ARCHIVE" -C / -T "$BIND_MOUNTS_FILE" || {
                log_error "Bind Mounts 归档打包失败！"
                exit 1
            }
        fi

        tar -tzf "$BIND_ARCHIVE" >/dev/null 2>&1 || {
            log_error "Bind Mounts 归档验证失败，文件损坏！"
            exit 1
        }
        TAR_BIND_LIST=$(tar -tzf "$BIND_ARCHIVE")
        while IFS= read -r mpath; do
            [ -z "$mpath" ] && continue
            actual_p=$(resolve_bind_path "$mpath")
            if [ -n "$SYS_ROOT" ]; then
                rel_p="${actual_p#$SYS_ROOT}"
                rel_p="${rel_p#/}"
            else
                rel_p="${mpath#/}"
            fi
            if ! echo "$TAR_BIND_LIST" | grep -q "$rel_p"; then
                log_error "Bind Mounts 归档遗漏文件或目录: $mpath ！"
                exit 1
            fi
        done < "$BIND_MOUNTS_FILE"
    fi

    # 9. 生成 SHA256 校验和清单
    log_info "生成 SHA256 校验和..."
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
            --sys-root)
                SYS_ROOT="$2"
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

    # 2. 确认恢复端数据盘真实挂载，严禁解压到内部 /overlay
    mkdir -p "$TARGET_DATA_ROOT"
    check_mount_safety "$TARGET_DATA_ROOT" "目标 DataRoot 目录"
    TARGET_DATA_ABS=$(cd "$TARGET_DATA_ROOT" && pwd -P)

    # 3. 恢复前确认 dockerd 已停止
    INIT_DOCKERD="$(get_sys_path /etc/init.d/dockerd)"
    if pgrep -x dockerd >/dev/null 2>&1; then
        log_error "dockerd 守护进程正在运行中！恢复数据与配置前必须确保 dockerd 已停止！"
        exit 1
    fi

    # 4. 恢复统一命名的配置文件并同步 DataRoot
    ETC_DIR="$(get_sys_path /etc)"
    CONFIG_DIR_HOST="$(get_sys_path /etc/config)"
    CONFIG_SRC="$BACKUP_DIR/config"

    if [ -d "$CONFIG_SRC" ]; then
        log_info "正在恢复 Docker 配置文件..."
        mkdir -p "$ETC_DIR/docker" "$CONFIG_DIR_HOST"

        if [ -d "$CONFIG_SRC/etc_docker" ]; then
            cp -r "$CONFIG_SRC/etc_docker/." "$ETC_DIR/docker/" || { log_error "恢复 etc_docker 失败！"; exit 1; }
        elif [ -d "$CONFIG_SRC/docker" ]; then
            cp -r "$CONFIG_SRC/docker/." "$ETC_DIR/docker/" || { log_error "恢复 docker 失败！"; exit 1; }
        fi

        if [ -f "$CONFIG_SRC/config_dockerd" ]; then
            cp "$CONFIG_SRC/config_dockerd" "$CONFIG_DIR_HOST/dockerd" || { log_error "恢复 config_dockerd 失败！"; exit 1; }
        elif [ -f "$CONFIG_SRC/dockerd" ]; then
            cp "$CONFIG_SRC/dockerd" "$CONFIG_DIR_HOST/dockerd" || { log_error "恢复 dockerd 失败！"; exit 1; }
        fi

        if [ -f "$CONFIG_SRC/config_dockerman" ]; then
            cp "$CONFIG_SRC/config_dockerman" "$CONFIG_DIR_HOST/dockerman" || { log_error "恢复 config_dockerman 失败！"; exit 1; }
        elif [ -f "$CONFIG_SRC/dockerman" ]; then
            cp "$CONFIG_SRC/dockerman" "$CONFIG_DIR_HOST/dockerman" || { log_error "恢复 dockerman 失败！"; exit 1; }
        fi

        # 同步 UCI 中的 data_root 为新目标目录
        if command -v uci >/dev/null 2>&1 && [ -f "$CONFIG_DIR_HOST/dockerd" ]; then
            UCI_CMD="uci"
            [ -n "$SYS_ROOT" ] && UCI_CMD="uci -c $CONFIG_DIR_HOST"
            $UCI_CMD set dockerd.globals.data_root="$TARGET_DATA_ABS" || { log_error "UCI 设置 data_root 失败"; exit 1; }
            $UCI_CMD commit dockerd || { log_error "UCI commit dockerd 失败"; exit 1; }
        fi

        # 同步 daemon.json
        if [ -f "$ETC_DIR/docker/daemon.json" ] && command -v sed >/dev/null 2>&1; then
            sed -i "s|\"data-root\": *\"[^\"]*\"|\"data-root\": \"$TARGET_DATA_ABS\"|g" "$ETC_DIR/docker/daemon.json"
        fi
    fi

    # 5. 恢复 Named Volumes
    log_info "正在恢复 Named Volumes 至: $TARGET_DATA_ABS..."
    tar -xzf "$BACKUP_DIR/docker_volumes.tar.gz" -C "$TARGET_DATA_ABS" || {
        log_error "解压 Named Volumes 失败！"
        exit 1
    }

    # 6. 恢复 Bind Mounts 数据至宿主机原路径
    if [ -f "$BACKUP_DIR/docker_bind_mounts.tar.gz" ]; then
        log_info "正在恢复 Bind Mounts 数据至原路径..."
        DEST_ROOT="/"
        [ -n "$SYS_ROOT" ] && DEST_ROOT="$SYS_ROOT"
        tar -xzf "$BACKUP_DIR/docker_bind_mounts.tar.gz" -C "$DEST_ROOT" || {
            log_error "解压 Bind Mounts 失败！"
            exit 1
        }
    fi

    # 7. 恢复 Compose 编排项目至原路径（严禁全部改放 /opt）
    COMPOSE_MANIFEST="$BACKUP_DIR/metadata/compose_manifest.tsv"
    if [ -f "$COMPOSE_MANIFEST" ]; then
        log_info "正在恢复 Compose 编排文件至原路径..."
        while IFS='	' read -r proj_name orig_dir config_file || [ -n "$proj_name" ]; do
            [ -z "$proj_name" ] && continue
            proj_tar="$BACKUP_DIR/compose/${proj_name}.tar.gz"
            if [ -f "$proj_tar" ]; then
                dest_dir="$orig_dir"
                [ -n "$SYS_ROOT" ] && dest_dir="${SYS_ROOT%/}$orig_dir"
                mkdir -p "$dest_dir"
                tar -xzf "$proj_tar" -C "$dest_dir" || {
                    log_error "恢复 Compose 项目 $proj_name 失败！"
                    exit 1
                }
                log_info "已恢复 Compose 项目 [$proj_name] 到原路径: $dest_dir"
            fi
        done < "$COMPOSE_MANIFEST"
    fi

    # 8. 启动 dockerd 并按原记录恢复开机自启
    if [ -x "$INIT_DOCKERD" ]; then
        log_info "正在启动 dockerd 服务..."
        "$INIT_DOCKERD" start || {
            log_error "启动 dockerd 服务失败！请检查系统日志。"
            exit 1
        }

        # 等待 dockerd 响应
        if command -v docker >/dev/null 2>&1; then
            WAIT_N=0
            while [ $WAIT_N -lt 15 ]; do
                if docker info >/dev/null 2>&1; then
                    break
                fi
                WAIT_N=$((WAIT_N + 1))
                sleep 1
            done
            if [ $WAIT_N -ge 15 ]; then
                log_error "dockerd 启动后未在预期时间内响应！"
                exit 1
            fi
        fi

        if [ -f "$BACKUP_DIR/docker_autostart.state" ]; then
            WAS_ENABLED=$(cat "$BACKUP_DIR/docker_autostart.state" 2>/dev/null || echo "0")
            if [ "$WAS_ENABLED" = "1" ]; then
                log_info "正在恢复 dockerd 开机自启..."
                "$INIT_DOCKERD" enable || {
                    log_error "恢复 dockerd 自启动失败！"
                    exit 1
                }
            fi
        fi
    fi

    # 9. 仅拉起本次备份记录的 Compose 项目（禁止扫描整个 /opt）
    if [ -f "$COMPOSE_MANIFEST" ]; then
        while IFS='	' read -r proj_name orig_dir config_file || [ -n "$proj_name" ]; do
            [ -z "$proj_name" ] && continue
            dest_dir="$orig_dir"
            [ -n "$SYS_ROOT" ] && dest_dir="${SYS_ROOT%/}$orig_dir"
            if [ -d "$dest_dir" ]; then
                log_info "启动记录的 Compose 项目: $proj_name ($dest_dir)..."
                if command -v docker-compose >/dev/null 2>&1; then
                    (cd "$dest_dir" && docker-compose up -d) || {
                        log_error "启动 Compose 项目 $proj_name 失败！"
                        exit 1
                    }
                elif command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
                    (cd "$dest_dir" && docker compose up -d) || {
                        log_error "启动 Compose 项目 $proj_name 失败！"
                        exit 1
                    }
                fi
            fi
        done < "$COMPOSE_MANIFEST"
    fi

    # 重建独立容器
    if [ -d "$BACKUP_DIR/standalone" ]; then
        STANDALONE_DIR="$BACKUP_DIR/standalone"
        for rscript in "$STANDALONE_DIR"/recreate_*.sh; do
            [ -f "$rscript" ] || continue
            log_info "执行独立容器重建: $(basename "$rscript")..."
            STANDALONE_DIR="$STANDALONE_DIR" sh "$rscript" || {
                log_error "重建容器脚本 $(basename "$rscript") 执行失败！"
                exit 1
            }
        done
    fi

    log_info "Docker 数据与服务已完整恢复成功！"
}

# -----------------------------------------------------------------------------
# 3. 升级前唯一固件校验与双分区容量预检 (precheck_image)
# -----------------------------------------------------------------------------
do_precheck_image() {
    IMAGE_PATH=""
    EXPECTED_SHA=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --image)
                IMAGE_PATH="$2"
                shift 2
                ;;
            --sha256)
                EXPECTED_SHA="$2"
                shift 2
                ;;
            --sys-root)
                SYS_ROOT="$2"
                shift 2
                ;;
            -*)
                log_error "未知参数: $1"
                exit 1
                ;;
            *)
                if [ -z "$IMAGE_PATH" ]; then
                    IMAGE_PATH="$1"
                elif [ -z "$EXPECTED_SHA" ]; then
                    EXPECTED_SHA="$1"
                fi
                shift
                ;;
        esac
    done

    if [ -z "$IMAGE_PATH" ]; then
        log_error "必须传入固件镜像文件路径 (--image)"
        exit 1
    fi

    if [ ! -f "$IMAGE_PATH" ]; then
        log_error "固件文件不存在或匹配不唯一: $IMAGE_PATH"
        exit 1
    fi

    IMG_SIZE=$(wc -c < "$IMAGE_PATH")
    IMG_SIZE_MB=$((IMG_SIZE / 1024 / 1024))
    log_info "固件文件确认: $IMAGE_PATH (大小: ${IMG_SIZE_MB}MB, ${IMG_SIZE} 字节)"

    # 核对 SHA256 校验和
    if [ -n "$EXPECTED_SHA" ]; then
        require_cmd sha256sum
        ACTUAL_SHA=$(sha256sum "$IMAGE_PATH" | awk '{print $1}')
        if [ "$ACTUAL_SHA" != "$EXPECTED_SHA" ]; then
            log_error "固件 SHA256 校验不匹配！预期: $EXPECTED_SHA，实际: $ACTUAL_SHA"
            exit 1
        fi
        log_info "固件 SHA256 校验通过: $ACTUAL_SHA"
    fi

    # 检查固件机型与格式兼容性
    require_cmd sysupgrade
    log_info "执行 sysupgrade -T 格式与机型兼容性预检..."
    if ! sysupgrade -T "$IMAGE_PATH"; then
        log_error "固件与当前硬件平台不兼容，禁止刷入！"
        exit 1
    fi
    log_info "固件平台兼容性校验通过"

    # 检查目标分区容量（严格核验升级目标，绝不能盲目取两者中较大的一个）
    require_cmd fdisk

    MMC_DEV="/dev/mmcblk0"
    PROC_CMDLINE="$(get_sys_path /proc/cmdline)"

    FDISK_OUT=$(fdisk -l "$MMC_DEV" 2>/dev/null || true)
    if [ -z "$FDISK_OUT" ]; then
        log_error "无法读取 eMMC 分区表信息 ($MMC_DEV)，禁止盲刷！"
        exit 1
    fi

    ACTIVE_ROOT=""
    if [ -f "$PROC_CMDLINE" ]; then
        ACTIVE_ROOT=$(grep -o 'root=[^ ]*' "$PROC_CMDLINE" | cut -d= -f2 || true)
    fi

    ROOTFS_SEC=$(echo "$FDISK_OUT" | grep -E "[[:space:]]rootfs[[:space:]]*$" | awk '{print $4}' || true)
    ROOTFS1_SEC=$(echo "$FDISK_OUT" | grep -E "[[:space:]]rootfs_1[[:space:]]*$" | awk '{print $4}' || true)

    if [ -z "$ROOTFS_SEC" ] && [ -z "$ROOTFS1_SEC" ]; then
        ROOTFS_SEC=$(echo "$FDISK_OUT" | grep -w "rootfs" | awk '{print $4}' | head -n 1 || true)
        ROOTFS1_SEC=$(echo "$FDISK_OUT" | grep -w "rootfs_1" | awk '{print $4}' | head -n 1 || true)
    fi

    if [ -z "$ROOTFS_SEC" ] && [ -z "$ROOTFS1_SEC" ]; then
        log_error "未能在分区表中找到 rootfs/rootfs_1 分区信息，目标分区不明，禁止放行！"
        exit 1
    fi

    TARGET_SEC=""
    TARGET_PART=""
    if [ -n "$ACTIVE_ROOT" ]; then
        case "$ACTIVE_ROOT" in
            *rootfs_1*)
                TARGET_PART="rootfs (对侧待升级目标)"
                TARGET_SEC="$ROOTFS_SEC"
                ;;
            *rootfs*)
                TARGET_PART="rootfs_1 (对侧待升级目标)"
                TARGET_SEC="$ROOTFS1_SEC"
                ;;
        esac
    fi

    # 若无法确定目标分区，取候选分区中较小者（严禁取大），确保安全边际
    if [ -z "$TARGET_SEC" ]; then
        if [ -n "$ROOTFS_SEC" ] && [ -n "$ROOTFS1_SEC" ]; then
            if [ "$ROOTFS_SEC" -le "$ROOTFS1_SEC" ]; then
                TARGET_SEC="$ROOTFS_SEC"
                TARGET_PART="rootfs (较小分区)"
            else
                TARGET_SEC="$ROOTFS1_SEC"
                TARGET_PART="rootfs_1 (较小分区)"
            fi
        elif [ -n "$ROOTFS_SEC" ]; then
            TARGET_SEC="$ROOTFS_SEC"
            TARGET_PART="rootfs"
        else
            TARGET_SEC="$ROOTFS1_SEC"
            TARGET_PART="rootfs_1"
        fi
    fi

    TARGET_BYTES=$((TARGET_SEC * 512))
    TARGET_MB=$((TARGET_BYTES / 1024 / 1024))
    log_info "核验目标升级分区 [$TARGET_PART] 扇区数: $TARGET_SEC (容量: ${TARGET_MB}MB)"

    MIN_REQUIRED_BYTES=$((IMG_SIZE + 52428800))
    MIN_REQUIRED_MB=$((MIN_REQUIRED_BYTES / 1024 / 1024))
    if [ "$TARGET_BYTES" -le "$MIN_REQUIRED_BYTES" ]; then
        log_error "目标分区容量 (${TARGET_MB}MB) 不足！刷入 ${IMG_SIZE_MB}MB 固件需至少 ${MIN_REQUIRED_MB}MB 空间以保留充足 overlay！"
        exit 1
    fi
    log_info "目标分区容量安全校验通过 (${TARGET_MB}MB > ${MIN_REQUIRED_MB}MB)"
}

# -----------------------------------------------------------------------------
# 4. 升级后 NSS 遗留项清理 (clean_nss)
# -----------------------------------------------------------------------------
do_clean_nss() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --sys-root)
                SYS_ROOT="$2"
                shift 2
                ;;
            *)
                shift
                ;;
        esac
    done

    require_cmd uci

    CONFIG_DIR_HOST="$(get_sys_path /etc/config)"
    INIT_FIREWALL="$(get_sys_path /etc/init.d/firewall)"
    UCI_CMD="uci"
    [ -n "$SYS_ROOT" ] && UCI_CMD="uci -c $CONFIG_DIR_HOST"

    if $UCI_CMD -q get firewall.qcanssecm >/dev/null 2>&1; then
        SEC_TYPE=$($UCI_CMD -q get firewall.qcanssecm || true)
        SCRIPT_PATH=$($UCI_CMD -q get firewall.qcanssecm.path || true)
        log_info "发现 firewall.qcanssecm (节类型: $SEC_TYPE, 路径: $SCRIPT_PATH)"

        # 必须同时满足：节类型为 include，路径精确匹配已确认的旧 NSS 脚本。空路径、未知路径或同名 rule 绝不删除
        if [ "$SEC_TYPE" != "include" ]; then
            log_warn "firewall.qcanssecm 节类型为 '$SEC_TYPE' (非 include)，属于自定义规则，严禁删除！"
            return 0
        fi

        if [ -z "$SCRIPT_PATH" ]; then
            log_warn "firewall.qcanssecm path 为空，未知目标，保留不做修改。"
            return 0
        fi

        case "$SCRIPT_PATH" in
            /etc/firewall.d/qca-nss-ecm|/etc/firewall.d/qca-nss|/etc/firewall.nss|/etc/init.d/qca-nss-ecm)
                log_info "确认属于已废弃旧版 NSS include 脚本 ($SCRIPT_PATH)，执行安全清理..."
                $UCI_CMD delete firewall.qcanssecm
                $UCI_CMD commit firewall
                [ -x "$INIT_FIREWALL" ] && "$INIT_FIREWALL" reload >/dev/null 2>&1 || true
                log_info "NSS 废弃 include 项已成功清理。"
                ;;
            *)
                log_warn "firewall.qcanssecm 指向未知脚本 ($SCRIPT_PATH)，保留不做修改。"
                ;;
        esac
    else
        log_info "未检测到废弃 NSS 防火墙钩子 (firewall.qcanssecm)"
    fi
}

# -----------------------------------------------------------------------------
# 5. 升级后运行时验收 (verify_runtime)
# -----------------------------------------------------------------------------
do_verify_runtime() {
    CHECK_TARGET="all"

    while [ $# -gt 0 ]; do
        case "$1" in
            --sys-root)
                SYS_ROOT="$2"
                shift 2
                ;;
            all|ppe|docker|passwall)
                CHECK_TARGET="$1"
                shift
                ;;
            *)
                log_error "未知验收参数: $1"
                exit 1
                ;;
        esac
    done

    FAILED=0

    # 1. 验证 PPE 硬件加速与 Flowtable
    if [ "$CHECK_TARGET" = "all" ] || [ "$CHECK_TARGET" = "ppe" ]; then
        log_info "=== 验证 PPE 硬件加速与 Flowtable ==="
        PPE_OK=0
        if command -v nft >/dev/null 2>&1; then
            if nft list tables 2>/dev/null | grep -q "flowtable" || nft list ruleset 2>/dev/null | grep -q "flowtable"; then
                PPE_OK=1
            fi
        fi

        DMESG_TEXT=$(dmesg 2>/dev/null || true)
        if echo "$DMESG_TEXT" | grep -qiE "(ppe|flowtable).*(fail|error|disabled|cannot|timed out)"; then
            log_error "dmesg 检测到 PPE/Flowtable 初始化失败或报错日志，硬件加速未正常生效！"
            PPE_OK=0
        fi

        if [ "$PPE_OK" -eq 1 ]; then
            log_info "PPE / Flowtable 硬件卸载状态: 已生效"
        else
            log_error "PPE / Flowtable 硬件卸载未检测到生效或驱动报错！"
            FAILED=1
        fi
    fi

    # 2. 验证 Docker 网络与端口转发
    if [ "$CHECK_TARGET" = "all" ] || [ "$CHECK_TARGET" = "docker" ]; then
        log_info "=== 验证 Docker 容器出网与端口映射 ==="
        if ! command -v docker >/dev/null 2>&1; then
            log_error "Docker 未安装或命令不可用！"
            FAILED=1
        else
            # 2a. 出网 TCP / HTTP 测试
            log_info "测试 Docker 容器外网出网 (TCP/HTTP)..."
            if docker run --rm alpine sh -c "wget -q -T 5 -O - http://connectivitycheck.gstatic.com/generate_204 || wget -q -T 5 -O - http://www.baidu.com" >/dev/null 2>&1; then
                log_info "Docker 容器外网出网测试: 正常"
            else
                log_error "Docker 容器外网出网测试失败！"
                FAILED=1
            fi

            # 2b. 端口映射测试
            log_info "测试 Docker 端口映射与 NAT 转发..."
            PORT_OK=0
            CID=$(docker run -d -p 127.0.0.1:18888:80 alpine sh -c "echo -e 'HTTP/1.1 200 OK\r\n\r\nPORT_OK' | nc -l -p 80" 2>/dev/null || true)
            if [ -n "$CID" ]; then
                sleep 1
                RESP=$(curl -m 3 -s http://127.0.0.1:18888 2>/dev/null || wget -q -T 3 -O - http://127.0.0.1:18888 2>/dev/null || true)
                if echo "$RESP" | grep -q "PORT_OK"; then
                    PORT_OK=1
                    log_info "Docker 容器端口映射与本地访问: 正常"
                fi
                docker rm -f "$CID" >/dev/null 2>&1 || true
            fi
            if [ "$PORT_OK" -ne 1 ]; then
                log_error "Docker 端口映射验证失败！"
                FAILED=1
            fi
        fi
    fi

    # 3. 验证 PassWall2 节点与代理连通性
    if [ "$CHECK_TARGET" = "all" ] || [ "$CHECK_TARGET" = "passwall" ]; then
        log_info "=== 验证 PassWall2 代理核心与握手 ==="
        PW_CORE=""
        if pgrep -x sing-box >/dev/null 2>&1; then
            PW_CORE="sing-box"
        elif pgrep -x xray >/dev/null 2>&1; then
            PW_CORE="xray"
        fi

        if [ -z "$PW_CORE" ]; then
            log_error "PassWall2 核心进程 (sing-box / xray) 未在运行！"
            FAILED=1
        else
            log_info "PassWall2 活动核心: $PW_CORE"
            VAR_PW_DIR="$(get_sys_path /var/etc/passwall2)"
            SOCKS_PORT=""
            if [ -d "$VAR_PW_DIR" ]; then
                for cfg in "$VAR_PW_DIR"/*.json; do
                    [ -f "$cfg" ] || continue
                    PORT_MATCH=$(grep -o '"port": *[0-9]*' "$cfg" 2>/dev/null | head -n 1 | awk '{print $2}' || true)
                    if [ -n "$PORT_MATCH" ]; then
                        SOCKS_PORT="$PORT_MATCH"
                        break
                    fi
                done
            fi

            if [ -z "$SOCKS_PORT" ]; then
                log_error "未能从实际配置中定位 PassWall2 SOCKS 端口 (禁止盲猜默认 1080)！"
                FAILED=1
            else
                log_info "定位到活动核心 SOCKS 端口: $SOCKS_PORT"
                if ! command -v curl >/dev/null 2>&1; then
                    log_error "缺少 curl 工具，无法发起 SOCKS 代理握手测试！"
                    FAILED=1
                else
                    log_info "通过本地 SOCKS 端口 ($SOCKS_PORT) 发起真实 TLS 握手测试..."
                    if curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" -m 10 -s -I https://www.google.com >/dev/null 2>&1; then
                        log_info "PassWall2 代理握手验证成功！"
                    else
                        log_error "PassWall2 代理握手失败，未能通过 SOCKS 端口建立连接！"
                        FAILED=1
                    fi
                fi
            fi
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
