#!/bin/sh
# 针对 Scripts/docker_upgrade_helper.sh 的完整逻辑回归测试套件
# 验收标准：备份确实完整、恢复确实可用、失败确实停止、环境严格沙箱隔离
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HELPER_SCRIPT="$REPO_ROOT/Scripts/docker_upgrade_helper.sh"

# 创建受控隔离沙箱，绝对严禁写入宿主机 /etc、/opt 或 /
TEST_SANDBOX="$REPO_ROOT/tests/tmp_sandbox_$$"
MOCK_BIN="$TEST_SANDBOX/mock_bin"
SYS_ROOT="$TEST_SANDBOX/sys_root"
MOCK_STATE="$TEST_SANDBOX/mock_state"
export TEST_SANDBOX MOCK_BIN SYS_ROOT MOCK_STATE

mkdir -p "$MOCK_BIN" "$SYS_ROOT" "$MOCK_STATE"

cleanup() {
    rm -rf "$TEST_SANDBOX"
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# 初始化基础 Mock 命令体系（确保所有系统交互全部落入沙箱，严禁回退宿主命令）
# -----------------------------------------------------------------------------
cat << 'EOF' > "$MOCK_BIN/docker"
#!/bin/sh
echo "docker $*" >> "$MOCK_STATE/invocations.log"

cmd="$1"
shift || true

case "$cmd" in
    info)
        if [ -f "$MOCK_STATE/docker_fail_info" ]; then
            exit 1
        fi
        if [ "${1:-}" = "-f" ]; then
            fmt="${2:-}"
            case "$fmt" in
                *"Driver"*)
                    echo "overlay2"
                    exit 0
                    ;;
                *)
                    cat "$MOCK_STATE/docker_root_dir" 2>/dev/null || echo "/var/lib/docker"
                    exit 0
                    ;;
            esac
        fi
        echo "Docker Root Dir: $(cat "$MOCK_STATE/docker_root_dir" 2>/dev/null || echo "/var/lib/docker")"
        exit 0
        ;;
    ps)
        if [ -f "$MOCK_STATE/docker_fail_ps" ]; then
            exit 1
        fi
        case "$*" in
            *-q*|"-aq")
                cat "$MOCK_STATE/containers_list_ids" 2>/dev/null || true
                exit 0
                ;;
            *)
                cat "$MOCK_STATE/containers_list_formatted" 2>/dev/null || true
                exit 0
                ;;
        esac
        ;;
    inspect)
        if [ -f "$MOCK_STATE/docker_fail_inspect" ]; then
            exit 1
        fi
        if [ "${1:-}" = "-f" ]; then
            fmt="$2"
            cid="$3"
            case "$fmt" in
                *"Labels"*"com.docker.compose.project.working_dir"*)
                    cat "$MOCK_STATE/comp_workdir_$cid" 2>/dev/null || true
                    ;;
                *"Labels"*"com.docker.compose.project.config_files"*)
                    cat "$MOCK_STATE/comp_config_$cid" 2>/dev/null || true
                    ;;
                *"Labels"*"com.docker.compose.project"*)
                    cat "$MOCK_STATE/comp_project_$cid" 2>/dev/null || true
                    ;;
                *"Config.Image"*)
                    cat "$MOCK_STATE/cimg_$cid" 2>/dev/null || echo "alpine:latest"
                    ;;
                *"NetworkSettings.Networks"*)
                    cat "$MOCK_STATE/net_count_$cid" 2>/dev/null || echo "1"
                    ;;
                *"HostConfig.NetworkMode"*)
                    cat "$MOCK_STATE/cnet_$cid" 2>/dev/null || echo "bridge"
                    ;;
                *"RestartPolicy.Name"*)
                    cat "$MOCK_STATE/crestart_$cid" 2>/dev/null || echo "unless-stopped"
                    ;;
                *"Name"*)
                    cat "$MOCK_STATE/cname_$cid" 2>/dev/null || echo "/$cid"
                    ;;
                *"Privileged"*)
                    cat "$MOCK_STATE/cpriv_$cid" 2>/dev/null || echo "false"
                    ;;
                *"Config.User"*)
                    cat "$MOCK_STATE/cuser_$cid" 2>/dev/null || echo ""
                    ;;
                *"Config.WorkingDir"*)
                    cat "$MOCK_STATE/cworkdir_$cid" 2>/dev/null || echo ""
                    ;;
                *"Config.Hostname"*)
                    cat "$MOCK_STATE/chostname_$cid" 2>/dev/null || echo ""
                    ;;
                *"Config.Entrypoint"*)
                    cat "$MOCK_STATE/centrypoint_$cid" 2>/dev/null || echo ""
                    ;;
                *"PortBindings"*)
                    cat "$MOCK_STATE/cports_$cid" 2>/dev/null || cat "$MOCK_STATE/ports_$cid" 2>/dev/null || true
                    ;;
                *"Config.Env"*)
                    cat "$MOCK_STATE/cenvs_$cid" 2>/dev/null || cat "$MOCK_STATE/env_$cid" 2>/dev/null || echo "MYSQL_ROOT_PASSWORD=my_secret_pass_123"
                    ;;
                *"HostConfig.Binds"*)
                    cat "$MOCK_STATE/binds_$cid" 2>/dev/null || true
                    ;;
                *"Config.Cmd"*)
                    cat "$MOCK_STATE/ccmd_$cid" 2>/dev/null || cat "$MOCK_STATE/cmd_$cid" 2>/dev/null || echo ""
                    ;;
                *)
                    echo ""
                    ;;
            esac
            exit 0
        fi
        cat "$MOCK_STATE/inspect.json" 2>/dev/null || echo "[]"
        exit 0
        ;;
    network)
        if [ -f "$MOCK_STATE/docker_fail_network" ]; then
            exit 1
        fi
        echo "NETWORK ID   NAME      DRIVER    SCOPE"
        echo "112233445566   bridge    bridge    local"
        exit 0
        ;;
    diff)
        cat "$MOCK_STATE/diff_$1" 2>/dev/null || true
        exit 0
        ;;
    commit)
        if [ -f "$MOCK_STATE/docker_fail_commit" ]; then
            exit 1
        fi
        echo "sha256:mock_committed_image"
        exit 0
        ;;
    save)
        if [ -f "$MOCK_STATE/docker_fail_save" ]; then
            exit 1
        fi
        # 创建有效 tar 产物
        tar -cf "$3" -T /dev/null 2>/dev/null || touch "$3"
        exit 0
        ;;
    load)
        echo "Loaded image"
        exit 0
        ;;
    stop)
        if [ -f "$MOCK_STATE/docker_fail_stop" ]; then
            exit 1
        fi
        echo "$*" >> "$MOCK_STATE/stopped_containers.log"
        if [ -f "$MOCK_STATE/simulate_stop_data_flush" ]; then
            flush_target=$(cat "$MOCK_STATE/simulate_stop_data_flush")
            echo "post_stop_flushed_cold_data" > "$flush_target"
        fi
        exit 0
        ;;
    run)
        if [ -f "$MOCK_STATE/docker_fail_run" ]; then
            exit 1
        fi
        if echo "$*" | grep -q "connectivitycheck"; then
            if [ -f "$MOCK_STATE/docker_fail_egress" ]; then
                exit 1
            fi
            exit 0
        fi
        if echo "$*" | grep -q -- "-p 127.0.0.1:18888:80"; then
            if [ -f "$MOCK_STATE/docker_fail_port_mapping" ]; then
                echo "bad_cid"
                exit 0
            fi
            echo "mock_port_cid"
            exit 0
        fi
        exit 0
        ;;
    rm)
        exit 0
        ;;
    compose)
        if [ -f "$MOCK_STATE/compose_fail" ]; then
            exit 1
        fi
        echo "compose $* at $(pwd)" >> "$MOCK_STATE/compose_invocations.log"
        exit 0
        ;;
    exec)
        echo "docker exec $*" >> "$MOCK_STATE/invocations.log"
        if echo "$*" | grep -q "mysqldump"; then
            echo "-- MySQL dump simulated"
            echo "CREATE TABLE test_table (id INT);"
            exit 0
        elif echo "$*" | grep -q "pg_dumpall"; then
            echo "-- PostgreSQL dump simulated"
            exit 0
        elif echo "$*" | grep -q "redis-cli"; then
            echo "OK"
            exit 0
        fi
        exit 0
        ;;
    volume)
        echo "app_volume"
        exit 0
        ;;
    version)
        echo "29.6.1"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$MOCK_BIN/docker"

cat << 'EOF' > "$MOCK_BIN/docker-compose"
#!/bin/sh
echo "docker-compose $* at $(pwd)" >> "$MOCK_STATE/compose_invocations.log"
echo "docker-compose $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/compose_fail" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$MOCK_BIN/docker-compose"

cat << 'EOF' > "$MOCK_BIN/df"
#!/bin/sh
echo "df $*" >> "$MOCK_STATE/invocations.log"
target=""
for arg; do
    target="$arg"
done
if [ -f "$MOCK_STATE/df_overlay_all" ] || [ -f "$MOCK_STATE/unmounted_$target" ] || echo "$target" | grep -q "unmounted"; then
    echo "Filesystem     1024-blocks   Used Available Capacity Mounted on"
    echo "overlayfs:/overlay 1048576 524288    524288      50% /"
    exit 0
fi
mode=$(cat "$MOCK_STATE/df_mode" 2>/dev/null || echo "usb")
case "$mode" in
    overlay)
        echo "Filesystem     1024-blocks   Used Available Capacity Mounted on"
        echo "overlayfs:/overlay 1048576 524288    524288      50% /"
        ;;
    tmpfs)
        echo "Filesystem     1024-blocks   Used Available Capacity Mounted on"
        echo "tmpfs              1048576 524288    524288      50% /tmp"
        ;;
    insufficient_space)
        echo "Filesystem     1024-blocks    Used Available Capacity Mounted on"
        echo "/dev/sda1         10485760 10485000       500     100% /mnt/sda1"
        ;;
    *)
        echo "Filesystem     1024-blocks    Used Available Capacity Mounted on"
        echo "/dev/sda1         10485760 1048576   9437184      10% /mnt/sda1"
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/df"

cat << 'EOF' > "$MOCK_BIN/fdisk"
#!/bin/sh
echo "fdisk $*" >> "$MOCK_STATE/invocations.log"
mode=$(cat "$MOCK_STATE/fdisk_mode" 2>/dev/null || echo "normal")
case "$mode" in
    dual_small_target)
        # rootfs 是 60MB (122880 sectors)，rootfs_1 是 512MB (1048576 sectors)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p2          2048        2559         512   0:BOOTCONFIG"
        echo "/dev/mmcblk0p13         2560       35327       32768   0:HLOS"
        echo "/dev/mmcblk0p14        35328       68095       32768   0:HLOS_1"
        echo "/dev/mmcblk0p15        68096      190975      122880   rootfs"
        echo "/dev/mmcblk0p16       190976     1239551     1048576   rootfs_1"
        ;;
    dual_large_both)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p2          2048        2559         512   0:BOOTCONFIG"
        echo "/dev/mmcblk0p13         2560       35327       32768   0:HLOS"
        echo "/dev/mmcblk0p14        35328       68095       32768   0:HLOS_1"
        echo "/dev/mmcblk0p15        68096     1116671     1048576   rootfs"
        echo "/dev/mmcblk0p16      1116672     2165247     1048576   rootfs_1"
        ;;
    missing_partitions)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p1          2048        4095        2048   boot"
        ;;
    *)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p2          2048        2559         512   0:BOOTCONFIG"
        echo "/dev/mmcblk0p13         2560       35327       32768   0:HLOS"
        echo "/dev/mmcblk0p14        35328       68095       32768   0:HLOS_1"
        echo "/dev/mmcblk0p15        68096     1116671     1048576   rootfs"
        echo "/dev/mmcblk0p16      1116672     2165247     1048576   rootfs_1"
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/fdisk"

cat << 'EOF' > "$MOCK_BIN/hexdump"
#!/bin/sh
echo "hexdump $*" >> "$MOCK_STATE/invocations.log"
target=""
for arg; do
    target="$arg"
done
if [ -f "$target" ]; then
    od_hex=$(od -An -tx1 -N 1 -j 148 "$target" 2>/dev/null | awk '{print $1}' || echo "00")
    if [ "$od_hex" = "01" ]; then
        echo "1|"
    elif [ "$od_hex" = "00" ]; then
        echo "0|"
    else
        echo "0|"
    fi
else
    echo "0|"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/hexdump"

cat << 'EOF' > "$MOCK_BIN/sysupgrade"
#!/bin/sh
echo "sysupgrade $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/sysupgrade_fail" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$MOCK_BIN/sysupgrade"

cat << 'EOF' > "$MOCK_BIN/nft"
#!/bin/sh
echo "nft $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/nft_has_flowtable_hw" ]; then
    echo "table inet fw4 { flowtable ft { hook ingress priority 0; devices = { eth0 }; flags = { hw_offload }; } }"
elif [ -f "$MOCK_STATE/nft_has_flowtable_sw" ] || [ -f "$MOCK_STATE/nft_has_flowtable" ]; then
    echo "table inet fw4 { flowtable ft { hook ingress priority 0; devices = { eth0 }; } }"
else
    echo "table inet fw4 { chain forward { type filter hook forward priority 0; drop; } }"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/nft"

cat << 'EOF' > "$MOCK_BIN/iptables"
#!/bin/sh
echo "iptables $*" >> "$MOCK_STATE/invocations.log"
if [ "${1:-}" = "-V" ]; then
    echo "iptables v1.8.10 (nf_tables)"
    exit 0
fi
if [ "${1:-}" = "-S" ] && [ "${2:-}" = "FORWARD" ]; then
    echo "-P FORWARD DROP"
    exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/iptables"

cat << 'EOF' > "$MOCK_BIN/jq"
#!/bin/sh
echo "jq $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/jq_fail" ]; then
    exit 1
fi
exit 0
EOF
chmod +x "$MOCK_BIN/jq"

cat << 'EOF' > "$MOCK_BIN/logread"
#!/bin/sh
echo "logread $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/logread_tls_error" ]; then
    echo "[ERROR] passwall2: TLS Handshake failed: certificate unknown"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/logread"

cat << 'EOF' > "$MOCK_BIN/dmesg"
#!/bin/sh
echo "dmesg $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/dmesg_ppe_error" ]; then
    echo "[ 1.234567] qcom-ppe 3a000000.ppe: probe failed with error -19"
else
    echo "[ 1.234567] qcom-ppe 3a000000.ppe: probed successfully"
fi
exit 0
EOF
chmod +x "$MOCK_BIN/dmesg"

cat << 'EOF' > "$MOCK_BIN/pgrep"
#!/bin/sh
echo "pgrep $*" >> "$MOCK_STATE/invocations.log"
target="$1"
[ "$target" = "-x" ] && target="$2"
if [ -f "$MOCK_STATE/pgrep_running_$target" ]; then
    echo "12345"
    exit 0
fi
exit 1
EOF
chmod +x "$MOCK_BIN/pgrep"

cat << 'EOF' > "$MOCK_BIN/curl"
#!/bin/sh
echo "curl $*" >> "$MOCK_STATE/invocations.log"
if [ -f "$MOCK_STATE/curl_fail" ]; then
    exit 1
fi
if echo "$*" | grep -q "127.0.0.1:18888"; then
    if [ -f "$MOCK_STATE/docker_fail_port_mapping" ]; then
        exit 1
    fi
    echo "HTTP/1.1 200 OK"
    echo ""
    echo "PORT_OK"
    exit 0
fi
exit 0
EOF
chmod +x "$MOCK_BIN/curl"

cat << 'EOF' > "$MOCK_BIN/uci"
#!/bin/sh
echo "uci $*" >> "$MOCK_STATE/invocations.log"
CONF_DIR="$SYS_ROOT/etc/config"
while [ $# -gt 0 ]; do
    case "$1" in
        -c)
            CONF_DIR="$2"
            shift 2
            ;;
        *)
            break
            ;;
    esac
done

cmd="$1"
shift || true
target="${1:-}"

case "$cmd" in
    get|-q)
        [ "$cmd" = "-q" ] && { cmd="$1"; target="${2:-}"; }
        case "$target" in
            firewall.qcanssecm)
                if [ -f "$CONF_DIR/firewall" ]; then
                    grep -A 2 "qcanssecm" "$CONF_DIR/firewall" | grep "config" | head -n 1 | awk '{print $2}' | tr -d "'" || exit 1
                    exit 0
                fi
                exit 1
                ;;
            firewall.qcanssecm.path)
                if [ -f "$CONF_DIR/firewall" ]; then
                    awk '
                        /config include .qcanssecm./ { in_sec=1; next }
                        in_sec && /^config / { in_sec=0 }
                        in_sec && /option path/ { print $3; exit }
                    ' "$CONF_DIR/firewall" | tr -d "'" || exit 1
                    exit 0
                fi
                exit 1
                ;;
            dockerd.globals.data_root)
                cat "$CONF_DIR/dockerd.data_root" 2>/dev/null || echo ""
                exit 0
                ;;
            *)
                exit 1
                ;;
        esac
        ;;
    set)
        key=$(echo "$target" | cut -d= -f1)
        val=$(echo "$target" | cut -d= -f2)
        if [ "$key" = "dockerd.globals.data_root" ]; then
            mkdir -p "$CONF_DIR"
            echo "$val" > "$CONF_DIR/dockerd.data_root"
        fi
        exit 0
        ;;
    delete)
        if [ "$target" = "firewall.qcanssecm" ] && [ -f "$CONF_DIR/firewall" ]; then
            awk '
                BEGIN { skip=0 }
                /config include .qcanssecm./ { skip=1; next }
                skip && /^config / { skip=0 }
                !skip { print }
            ' "$CONF_DIR/firewall" > "$CONF_DIR/firewall.tmp" && mv "$CONF_DIR/firewall.tmp" "$CONF_DIR/firewall"
        fi
        exit 0
        ;;
    commit)
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$MOCK_BIN/uci"

# 初始化服务管理脚本至沙箱目录内部
mkdir -p "$SYS_ROOT/etc/init.d" "$SYS_ROOT/etc/config" "$SYS_ROOT/etc/docker" "$SYS_ROOT/var/run" "$SYS_ROOT/proc"
cat << 'EOF' > "$SYS_ROOT/etc/init.d/dockerd"
#!/bin/sh
echo "init.d/dockerd $*" >> "$MOCK_STATE/invocations.log"
cmd="$1"
case "$cmd" in
    enabled)
        state=$(cat "$SYS_ROOT/etc/dockerd_enabled_flag" 2>/dev/null || echo "0")
        [ "$state" = "1" ] && exit 0
        exit 1
        ;;
    enable)
        echo "1" > "$SYS_ROOT/etc/dockerd_enabled_flag"
        exit 0
        ;;
    disable)
        echo "0" > "$SYS_ROOT/etc/dockerd_enabled_flag"
        exit 0
        ;;
    stop)
        if [ -f "$MOCK_STATE/init_stop_fail" ]; then
            exit 1
        fi
        rm -f "$SYS_ROOT/var/run/dockerd.pid"
        exit 0
        ;;
    start)
        if [ -f "$MOCK_STATE/init_start_fail" ]; then
            exit 1
        fi
        echo "12345" > "$SYS_ROOT/var/run/dockerd.pid"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$SYS_ROOT/etc/init.d/dockerd"

# 设置环境变量，强制 Mock 生效
export PATH="$MOCK_BIN:$PATH"

echo "=== 开始执行 AX6600 备份恢复与升级验证回归测试套件 ==="
echo "沙箱根路径: $TEST_SANDBOX"

# -----------------------------------------------------------------------------
# 测试 0: 验证测试套件隔离性（所有 mock 必须拦截）
# -----------------------------------------------------------------------------
echo "--- 测试 0: 测试环境隔离性验证 ---"
(
    if [ "$(which docker)" != "$MOCK_BIN/docker" ]; then
        echo "FAIL: docker 未被沙箱拦截！"
        exit 1
    fi
    if [ "$(which uci)" != "$MOCK_BIN/uci" ]; then
        echo "FAIL: uci 未被沙箱拦截！"
        exit 1
    fi
)
echo "PASS: 测试 0 通过（测试隔离性已确认，所有系统调用均被沙箱完全拦截）"

# -----------------------------------------------------------------------------
# 测试 1: dockerd 未运行或探测 DockerRootDir 失败时必须报错
# -----------------------------------------------------------------------------
echo "--- 测试 1: dockerd 未运行或探测 DockerRootDir 失败时严格报错 ---"
(
    touch "$MOCK_STATE/docker_fail_info"
    set +e
    sh "$HELPER_SCRIPT" backup --target-dir "$TEST_SANDBOX/t1_target" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t1.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/docker_fail_info"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: dockerd 探测失败时，backup 竟然返回成功！"
        exit 1
    fi
    if ! grep -q "无法连接 Docker 守护进程" "$TEST_SANDBOX/t1.log"; then
        echo "FAIL: 未报告预期的 dockerd 连接失败: $(cat "$TEST_SANDBOX/t1.log")"
        exit 1
    fi
)
echo "PASS: 测试 1 通过（连接 dockerd 失败严格阻断）"

# -----------------------------------------------------------------------------
# 测试 2: 目标目录在 DockerRootDir 内部时必须被拦截（防止递归打包）
# -----------------------------------------------------------------------------
echo "--- 测试 2: 拦截备份目标在 DockerRootDir 内部 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t2_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes" "$MOCK_DOCKER_ROOT/recursive_backup"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$MOCK_DOCKER_ROOT/recursive_backup" --sys-root "$SYS_ROOT" --skip-stop 2>"$TEST_SANDBOX/t2.log"
    ret=$?
    set -e

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标在 DockerRootDir 内部却没有拦截！"
        exit 1
    fi
    if ! grep -q "不能在 DockerRootDir" "$TEST_SANDBOX/t2.log"; then
        echo "FAIL: 未报告递归打包拦截: $(cat "$TEST_SANDBOX/t2.log")"
        exit 1
    fi
)
echo "PASS: 测试 2 通过（内部递归目录被成功拦截）"

# -----------------------------------------------------------------------------
# 测试 3: 外盘未挂载或备份目标位于 /overlay、/ 等重置位置时严格拒绝
# -----------------------------------------------------------------------------
echo "--- 测试 3: 外盘未挂载或位于 /overlay / tmpfs 时严格拒绝 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t3_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes"
    echo "overlay" > "$MOCK_STATE/df_mode"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$TEST_SANDBOX/t3_target" --sys-root "$SYS_ROOT" --skip-stop 2>"$TEST_SANDBOX/t3.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/df_mode"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标在 /overlay 上却没有拦截！"
        exit 1
    fi
    if ! grep -qiE "(位于根文件系统或.*overlay|存储设备为易失或升级重置设备)" "$TEST_SANDBOX/t3.log"; then
        echo "FAIL: 未能正确识别 /overlay: $(cat "$TEST_SANDBOX/t3.log")"
        exit 1
    fi
)
echo "PASS: 测试 3 通过（外盘未挂载、落入内部 overlay 被严格拒绝）"

# -----------------------------------------------------------------------------
# 测试 4: 空间估算覆盖全量数据与可用空间不足拦截
# -----------------------------------------------------------------------------
echo "--- 测试 4: 空间不足时严格拦截 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t4_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes/v1"
    echo "large_data" > "$MOCK_DOCKER_ROOT/volumes/v1/file"
    echo "insufficient_space" > "$MOCK_STATE/df_mode"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$TEST_SANDBOX/t4_target" --sys-root "$SYS_ROOT" --skip-stop 2>"$TEST_SANDBOX/t4.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/df_mode"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 空间不足却没有拦截！"
        exit 1
    fi
    if ! grep -q "目标存储空间不足" "$TEST_SANDBOX/t4.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t4.log")"
        exit 1
    fi
)
echo "PASS: 测试 4 通过（空间不足严格拒绝备份）"

# -----------------------------------------------------------------------------
# 测试 5: 关键步骤失败必须停止（无盲目 || true）
# -----------------------------------------------------------------------------
echo "--- 测试 5: 停机失败或服务异常时严格停止并恢复自启 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t5_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes"
    echo "1" > "$SYS_ROOT/etc/dockerd_enabled_flag"
    echo "c_test" > "$MOCK_STATE/containers_list_ids"
    echo "c_test" > "$MOCK_STATE/cname_c_test"
    touch "$MOCK_STATE/docker_fail_stop"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$TEST_SANDBOX/t5_target" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t5.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/docker_fail_stop" "$MOCK_STATE/containers_list_ids"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 容器停止失败却没有终止备份！"
        exit 1
    fi
    if ! grep -q "停止容器失败" "$TEST_SANDBOX/t5.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t5.log")"
        exit 1
    fi
)
echo "PASS: 测试 5 通过（关键步骤失败立即停止并报错）"

# -----------------------------------------------------------------------------
# 测试 6: tar 生成了可读但缺文件的部分归档，仍必须失败
# -----------------------------------------------------------------------------
echo "--- 测试 6: 归档缺漏文件时严格报错 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t6_docker"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes/vol_missing"
    echo "data" > "$MOCK_DOCKER_ROOT/volumes/vol_missing/file.txt"

    mkdir -p "$TEST_SANDBOX/t6_target/metadata"
    cat << 'EOF' > "$MOCK_STATE/inspect.json"
[
  {
    "Id": "c6",
    "Name": "/c6",
    "Config": { "Image": "test:latest" },
    "HostConfig": { "Binds": ["/non/existent/host/path:/container/path"] }
  }
]
EOF
    echo "c6" > "$MOCK_STATE/containers_list_ids"
    echo "c6" > "$MOCK_STATE/cname_c6"

    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$TEST_SANDBOX/t6_target" --sys-root "$SYS_ROOT" --skip-stop 2>"$TEST_SANDBOX/t6.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/inspect.json" "$MOCK_STATE/containers_list_ids"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 外部挂载文件缺失却没有报错！"
        exit 1
    fi
    if ! grep -q "外部挂载路径不存在" "$TEST_SANDBOX/t6.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t6.log")"
        exit 1
    fi
)
echo "PASS: 测试 6 通过（归档文件缺失被准确识别阻断）"

# -----------------------------------------------------------------------------
# 测试 7: 端到端完整隔离备份与恢复演练（含数据库热备、.env、原路径、独立容器重建与配置统一）
# -----------------------------------------------------------------------------
echo "--- 测试 7: 端到端隔离备份与完整数据恢复演练 ---"
(
    SRC_DOCKER="$SYS_ROOT/var/lib/docker"
    DST_DOCKER="$TEST_SANDBOX/dst_docker"
    BKP_STORE="$TEST_SANDBOX/bkp_external/docker_bkp"
    ROUTER_BIND="/my_bind_dir"
    EXT_BIND="$SYS_ROOT$ROUTER_BIND"
    ROUTER_COMPOSE="/my_apps/custom_compose_path"
    SRC_COMPOSE="$SYS_ROOT$ROUTER_COMPOSE"
    SRC_COMPOSE_DATA="$SRC_COMPOSE/data"

    mkdir -p "$SRC_DOCKER/volumes/app_volume" "$DST_DOCKER" "$BKP_STORE" "$EXT_BIND/data" "$SRC_COMPOSE_DATA"
    echo "important_vol_data_99" > "$SRC_DOCKER/volumes/app_volume/data.bin"
    echo "bind_config_val=1" > "$EXT_BIND/app.env"
    echo "bind_sub_val=2" > "$EXT_BIND/data/sub.txt"
    echo "pre_stop_compose_data" > "$SRC_COMPOSE_DATA/state.txt"

    # 设置停机冷数据落盘模拟：停机时容器落盘更新数据，确保冷备归档抓取到最新持久化数据
    echo "$SRC_COMPOSE_DATA/state.txt" > "$MOCK_STATE/simulate_stop_data_flush"

    # 创建 Compose 项目（必须包含 .env 隐藏文件）
    cat << 'EOF' > "$SRC_COMPOSE/docker-compose.yml"
version: '3.8'
services:
  web:
    image: nginx:alpine
    env_file: .env
EOF
    echo "SECRET_TOKEN=xyz_token_secret_123" > "$SRC_COMPOSE/.env"

    # 配置系统配置文件
    echo '{"data-root":"/old/root"}' > "$SYS_ROOT/etc/docker/daemon.json"
    echo "package dockerd" > "$SYS_ROOT/etc/config/dockerd"
    echo "package dockerman" > "$SYS_ROOT/etc/config/dockerman"
    echo "1" > "$SYS_ROOT/etc/dockerd_enabled_flag"

    # 设置 Mock 容器状态：包含 1 个 Compose 容器、1 个独立容器、1 个运行中 MySQL 数据库容器
    cat << EOF > "$MOCK_STATE/inspect.json"
[
  {
    "Id": "comp_cid",
    "Name": "/web_service",
    "Config": {
      "Image": "nginx:alpine",
      "Labels": {
        "com.docker.compose.project": "my_proj",
        "com.docker.compose.project.working_dir": "$ROUTER_COMPOSE",
        "com.docker.compose.project.config_files": "$ROUTER_COMPOSE/docker-compose.yml"
      }
    },
    "HostConfig": {
      "Binds": ["$ROUTER_BIND:/app/config", "$ROUTER_COMPOSE/data:/app/data"]
    }
  },
  {
    "Id": "standalone_cid",
    "Name": "/standalone_app",
    "Config": {
      "Image": "redis:alpine",
      "Labels": {}
    },
    "HostConfig": {
      "NetworkMode": "bridge",
      "RestartPolicy": { "Name": "always" },
      "Privileged": true,
      "Binds": ["$ROUTER_BIND/data:/data"]
    }
  },
  {
    "Id": "mysql_cid",
    "Name": "/mysql_db",
    "Config": {
      "Image": "mysql:8.0",
      "Labels": {}
    },
    "HostConfig": {
      "NetworkMode": "bridge",
      "RestartPolicy": { "Name": "unless-stopped" },
      "Privileged": false,
      "Binds": []
    }
  }
]
EOF
    echo -e "comp_cid\nstandalone_cid\nmysql_cid" > "$MOCK_STATE/containers_list_ids"
    echo "my_proj" > "$MOCK_STATE/comp_project_comp_cid"
    echo "$ROUTER_COMPOSE" > "$MOCK_STATE/comp_workdir_comp_cid"
    echo "$ROUTER_COMPOSE/docker-compose.yml" > "$MOCK_STATE/comp_config_comp_cid"
    echo "nginx:alpine" > "$MOCK_STATE/cimg_comp_cid"
    echo "web_service" > "$MOCK_STATE/cname_comp_cid"
    echo -e "$ROUTER_BIND:/app/config\n$ROUTER_COMPOSE/data:/app/data" > "$MOCK_STATE/binds_comp_cid"

    echo "redis:alpine" > "$MOCK_STATE/cimg_standalone_cid"
    echo "standalone_app" > "$MOCK_STATE/cname_standalone_cid"
    echo "C /etc/redis.conf" > "$MOCK_STATE/diff_standalone_cid"
    echo "bridge" > "$MOCK_STATE/cnet_standalone_cid"
    echo "always" > "$MOCK_STATE/crestart_standalone_cid"
    echo "true" > "$MOCK_STATE/cpriv_standalone_cid"
    echo "1000" > "$MOCK_STATE/cuser_standalone_cid"
    echo "/workspace" > "$MOCK_STATE/cworkdir_standalone_cid"
    echo "standalone-host" > "$MOCK_STATE/chostname_standalone_cid"
    echo "/entrypoint.sh" > "$MOCK_STATE/centrypoint_standalone_cid"
    echo "0.0.0.0:8080:80/tcp" > "$MOCK_STATE/cports_standalone_cid"
    echo "STANDALONE_SECRET=super_secret_token_456" > "$MOCK_STATE/cenvs_standalone_cid"
    echo "$ROUTER_BIND/data:/data" > "$MOCK_STATE/binds_standalone_cid"
    printf 'redis-server\n--protected-mode\nno\n' > "$MOCK_STATE/ccmd_standalone_cid"

    echo "mysql:8.0" > "$MOCK_STATE/cimg_mysql_cid"
    echo "mysql_db" > "$MOCK_STATE/cname_mysql_cid"

    # 1. 执行全量备份（不传 --skip-stop，走完整真实停机冷备流）
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$SRC_DOCKER" \
        --target-dir "$BKP_STORE" \
        --sys-root "$SYS_ROOT" >/dev/null

    # 验证备份目录自包含 helper 脚本（解决重启后 /tmp 丢失问题）
    if [ ! -x "$BKP_STORE/docker_upgrade_helper.sh" ]; then
        echo "FAIL: 备份目录未包含可执行的 docker_upgrade_helper.sh！"
        exit 1
    fi

    # 验证配置文件统一命名的正确性
    if [ ! -d "$BKP_STORE/config/etc_docker" ] || [ ! -f "$BKP_STORE/config/config_dockerd" ] || [ ! -f "$BKP_STORE/config/config_dockerman" ]; then
        echo "FAIL: 备份配置命名不规范或缺失！"
        exit 1
    fi

    # 验证应用级数据库热备文件已生成并记录在校验列表中
    if [ ! -f "$BKP_STORE/databases/mysql_mysql_db.sql" ]; then
        echo "FAIL: 未自动生成 MySQL 逻辑热备文件！"
        exit 1
    fi
    if ! grep -q "databases/mysql_mysql_db.sql" "$BKP_STORE/sha256sums.txt"; then
        echo "FAIL: sha256sums.txt 遗漏数据库转储校验记录！"
        exit 1
    fi

    # 验证统一清单 backup_manifest.txt 覆盖所有关键产物
    if [ ! -f "$BKP_STORE/backup_manifest.txt" ]; then
        echo "FAIL: 未生成统一备份清单 backup_manifest.txt！"
        exit 1
    fi
    for req_item in "compose/my_proj.tar.gz" "standalone/recreate_standalone_app.sh" "standalone/image_standalone_app.tar" "docker_volumes.tar.gz" "docker_bind_mounts.tar.gz"; do
        if ! grep -q "$req_item" "$BKP_STORE/backup_manifest.txt"; then
            echo "FAIL: backup_manifest.txt 缺失项目: $req_item"
            exit 1
        fi
        if ! grep -q "$req_item" "$BKP_STORE/sha256sums.txt"; then
            echo "FAIL: sha256sums.txt 遗漏项目校验: $req_item"
            exit 1
        fi
    done

    # 验证 Compose 备份包含 .env
    tar -tzf "$BKP_STORE/compose/my_proj.tar.gz" | grep -q "\.env" || {
        echo "FAIL: Compose 打包漏掉了隐藏文件 .env！"
        exit 1
    }

    # 验证独立容器生成了重建脚本与快照镜像
    REC_SCRIPT="$BKP_STORE/standalone/recreate_standalone_app.sh"
    if [ ! -f "$REC_SCRIPT" ] || [ ! -f "$BKP_STORE/standalone/image_standalone_app.tar" ]; then
        echo "FAIL: 独立容器重建脚本或快照镜像未生成！"
        exit 1
    fi

    # 严格校验独立容器重建脚本内容覆盖所有参数: -e, -p, -v, --net, --restart, --privileged, -u, -w, -h, --entrypoint, Cmd
    REC_CONTENT=$(cat "$REC_SCRIPT")
    for flag_pat in \
        '--name "standalone_app"' \
        '--net "bridge"' \
        '--restart "always"' \
        '--privileged' \
        '-u "1000"' \
        '-w "/workspace"' \
        '-h "standalone-host"' \
        '--entrypoint "/entrypoint.sh"' \
        '-p "0.0.0.0:8080:80/tcp"' \
        '-e "STANDALONE_SECRET=super_secret_token_456"' \
        "-v \"$ROUTER_BIND/data:/data\"" \
        '"backup-snapshot-standalone_app:latest"' \
        '"redis-server"' \
        '"--protected-mode"' \
        '"no"'; do
        if ! echo "$REC_CONTENT" | grep -F -q -- "$flag_pat"; then
            echo "FAIL: 独立容器重建脚本遗漏参数: $flag_pat"
            echo "重建脚本全文: $REC_CONTENT"
            exit 1
        fi
    done

    # 模拟系统升级（清空沙箱内的旧系统配置、删除原 Compose 目录、停止服务）
    rm -rf "$SRC_COMPOSE" "$EXT_BIND" "$SYS_ROOT/etc/docker" "$SYS_ROOT/etc/config"
    mkdir -p "$SYS_ROOT/etc/config"
    touch "$SYS_ROOT/etc/config/dockerd"
    echo "0" > "$SYS_ROOT/etc/dockerd_enabled_flag"
    : > "$MOCK_STATE/compose_invocations.log"

    # 2. 执行恢复操作到全新数据盘目录
    sh "$BKP_STORE/docker_upgrade_helper.sh" restore \
        --backup-dir "$BKP_STORE" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" >/dev/null

    # 验证数据完整性与属性
    if [ ! -f "$DST_DOCKER/volumes/app_volume/data.bin" ]; then
        echo "FAIL: Named Volumes 未恢复到目标 DataRoot！"
        exit 1
    fi
    ACTUAL_DATA=$(cat "$DST_DOCKER/volumes/app_volume/data.bin")
    if [ "$ACTUAL_DATA" != "important_vol_data_99" ]; then
        echo "FAIL: 恢复的数据内容损坏或不一致: $ACTUAL_DATA"
        exit 1
    fi

    # 验证 Bind Mounts 恢复到原路径
    if [ ! -f "$EXT_BIND/app.env" ] || [ ! -f "$EXT_BIND/data/sub.txt" ]; then
        echo "FAIL: Bind Mounts 未恢复到原始宿主路径！"
        exit 1
    fi
    if [ "$(cat "$EXT_BIND/app.env")" != "bind_config_val=1" ]; then
        echo "FAIL: Bind Mounts 文件内容不一致！"
        exit 1
    fi

    # 验证 Compose 恢复到了原始目录，而不是全部改放 /opt
    if [ ! -f "$SRC_COMPOSE/docker-compose.yml" ] || [ ! -f "$SRC_COMPOSE/.env" ]; then
        echo "FAIL: Compose 未恢复到原始目录或缺少 .env！"
        exit 1
    fi
    if ! grep -q "SECRET_TOKEN=xyz_token_secret_123" "$SRC_COMPOSE/.env"; then
        echo "FAIL: 恢复的 .env 内容损坏！"
        exit 1
    fi

    # 验证冷备覆盖顺序：Compose 先解压、Bind Mounts 后解压，确保冷备持久化数据绝不被旧数据覆盖
    if [ ! -f "$SRC_COMPOSE_DATA/state.txt" ]; then
        echo "FAIL: Compose 内部挂载数据文件缺失！"
        exit 1
    fi
    if [ "$(cat "$SRC_COMPOSE_DATA/state.txt")" != "post_stop_flushed_cold_data" ]; then
        echo "FAIL: 恢复后数据未保持停机后的冷备状态（被旧 Compose 覆盖）: $(cat "$SRC_COMPOSE_DATA/state.txt")"
        exit 1
    fi

    # 验证只拉起了记录的项目，且启动参数包含 -p、-f 与 --env-file
    if ! grep -q "$SRC_COMPOSE" "$MOCK_STATE/compose_invocations.log"; then
        echo "FAIL: Compose 项目未在原始恢复路径拉起！"
        exit 1
    fi
    if ! grep -q -- "-p my_proj" "$MOCK_STATE/compose_invocations.log"; then
        echo "FAIL: Compose 启动命令遗漏项目名称参数 (-p)！"
        exit 1
    fi
    if ! grep -q -- "--env-file" "$MOCK_STATE/compose_invocations.log"; then
        echo "FAIL: Compose 启动命令遗漏环境变量文件参数 (--env-file)！"
        exit 1
    fi

    # 验证配置文件成功恢复且 data_root 被同步
    if [ ! -f "$SYS_ROOT/etc/config/dockerman" ]; then
        echo "FAIL: /etc/config/dockerman 未恢复！"
        exit 1
    fi
    ACTUAL_DATA_ROOT=$(cat "$SYS_ROOT/etc/config/dockerd.data_root" 2>/dev/null || echo "")
    if [ "$ACTUAL_DATA_ROOT" != "$DST_DOCKER" ]; then
        echo "FAIL: UCI dockerd.globals.data_root 未同步更新为目标 DataRoot ($ACTUAL_DATA_ROOT)！"
        exit 1
    fi

    # 验证开机自启状态正确恢复
    if [ "$(cat "$SYS_ROOT/etc/dockerd_enabled_flag")" != "1" ]; then
        echo "FAIL: dockerd 开机自启动未能正确恢复！"
        exit 1
    fi
)
echo "PASS: 测试 7 通过（端到端隔离全量备份、数据库热备、还原、原路径校验与自启恢复全部一致）"

# -----------------------------------------------------------------------------
# 测试 8: 镜像预检与双分区容量安全核验（严禁取大）
# -----------------------------------------------------------------------------
echo "--- 测试 8: 镜像校验与双分区容量安全预检 ---"
(
    IMG_FILE="$TEST_SANDBOX/test_fw.bin"
    head -c 104857600 /dev/zero > "$IMG_FILE"
    SHA_EXPECTED=$(sha256sum "$IMG_FILE" | awk '{print $1}')

    # 8a: SHA256 不匹配时必须被拦截
    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "0000000000000000000000000000000000000000000000000000000000000000" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t8_sha.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: SHA256 错误未被拦截！"
        exit 1
    fi

    # 8b: 0:BOOTCONFIG 偏移 148 为 0 时，目标分区为 0:HLOS 与 rootfs (60MB 较小分区)，绝不能被 512MB 误放行
    echo "dual_small_target" > "$MOCK_STATE/fdisk_mode"
    mkdir -p "$SYS_ROOT/dev"
    head -c 148 /dev/zero > "$SYS_ROOT/dev/mmcblk0p2"
    printf '\x00' >> "$SYS_ROOT/dev/mmcblk0p2"
    head -c 363 /dev/zero >> "$SYS_ROOT/dev/mmcblk0p2"

    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "$SHA_EXPECTED" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t8_part.log"
    ret=$?
    set -e

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标分区仅 60MB，刷入 100MB 固件竟然被误放行！"
        exit 1
    fi
    if ! grep -qiE "(目标分区容量.*不足|容量仅为.*小于 200MB 安全阈值)" "$TEST_SANDBOX/t8_part.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t8_part.log")"
        exit 1
    fi

    # 8c: 0:BOOTCONFIG 偏移 148 为 1 时，目标分区为 0:HLOS_1 与 rootfs_1 (512MB 较大分区)，100MB 固件应当放行
    head -c 148 /dev/zero > "$SYS_ROOT/dev/mmcblk0p2"
    printf '\x01' >> "$SYS_ROOT/dev/mmcblk0p2"
    head -c 363 /dev/zero >> "$SYS_ROOT/dev/mmcblk0p2"

    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "$SHA_EXPECTED" --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t8_part_ok.log" 2>&1
    ret=$?
    set -e
    rm -f "$MOCK_STATE/fdisk_mode" "$SYS_ROOT/dev/mmcblk0p2"

    if [ "$ret" -ne 0 ]; then
        echo "FAIL: 目标分区为 512MB rootfs_1，刷入 100MB 固件却被误拦截: $(cat "$TEST_SANDBOX/t8_part_ok.log")"
        exit 1
    fi
    if ! grep -q "目标根文件系统: \[rootfs_1\]" "$TEST_SANDBOX/t8_part_ok.log"; then
        echo "FAIL: 未正确选中 rootfs_1 作为目标分区: $(cat "$TEST_SANDBOX/t8_part_ok.log")"
        exit 1
    fi

    # 8d: 系统只读体检模式验证 (识别固件、硬件型号与分区)
    echo "DISTRIB_DESCRIPTION='OpenWrt 23.05-SNAPSHOT'" > "$SYS_ROOT/etc/openwrt_release"
    mkdir -p "$SYS_ROOT/tmp/sysinfo"
    echo "JDCloud AX6600 (RE-CS-02)" > "$SYS_ROOT/tmp/sysinfo/model"
    sh "$HELPER_SCRIPT" precheck --system-only --sys-root "$SYS_ROOT" > "$TEST_SANDBOX/t8_sys.log"
    if ! grep -q "当前固件: OpenWrt 23.05-SNAPSHOT" "$TEST_SANDBOX/t8_sys.log"; then
        echo "FAIL: 系统预检未能正确识别固件描述！"
        exit 1
    fi
    if ! grep -q "设备型号: JDCloud AX6600" "$TEST_SANDBOX/t8_sys.log"; then
        echo "FAIL: 系统预检未能正确识别设备型号！"
        exit 1
    fi
)
echo "PASS: 测试 8 通过（镜像预检严格，系统只读体检输出完整，双分区未误取较大者）"

# -----------------------------------------------------------------------------
# 测试 9: NSS 清理严格匹配（节类型为 include 且路径精确匹配，并自动备份旧配置）
# -----------------------------------------------------------------------------
echo "--- 测试 9: NSS 清理精确匹配与安全性 ---"
(
    cat << 'EOF' > "$SYS_ROOT/etc/config/firewall"
config defaults
	option syn_flood '1'

config include 'qcanssecm'
	option path '/etc/firewall.d/qca-nss-ecm'

config rule 'qcanssecm'
	option name 'Allow-Custom'
	option target 'ACCEPT'

config include 'custom_user_nss'
	option path '/etc/my_nss_hook.sh'
EOF

    # 执行清理
    sh "$HELPER_SCRIPT" clean-nss --sys-root "$SYS_ROOT" >/dev/null

    # 验证自动备份存在
    if ! ls "$SYS_ROOT/etc/config"/firewall.bak.* >/dev/null 2>&1; then
        echo "FAIL: clean-nss 未在修改前自动创建防火墙配置备份！"
        exit 1
    fi

    # 验证结果：只有旧 include 被删，同名 rule 和自定义 include 完好
    if grep -q "/etc/firewall.d/qca-nss-ecm" "$SYS_ROOT/etc/config/firewall"; then
        echo "FAIL: 废弃 include 未被清理！"
        exit 1
    fi
    if ! grep -q "config rule 'qcanssecm'" "$SYS_ROOT/etc/config/firewall"; then
        echo "FAIL: 同名 config rule 被误删！"
        exit 1
    fi
    if ! grep -q "config include 'custom_user_nss'" "$SYS_ROOT/etc/config/firewall"; then
        echo "FAIL: 自定义用户 include 被误删！"
        exit 1
    fi
)
echo "PASS: 测试 9 通过（NSS 清理精准保护自定义规则，备份防火墙配置并清除废弃 include）"

# -----------------------------------------------------------------------------
# 测试 10: 运行时验收失败分支阻断与精确参数提取
# -----------------------------------------------------------------------------
echo "--- 测试 10: 运行时验收失败阻断与精准提取 ---"
(
    # 10a: dmesg 报错且无 flowtable 时必须拦截
    touch "$MOCK_STATE/dmesg_ppe_error"
    set +e
    sh "$HELPER_SCRIPT" verify ppe --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_ppe.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/dmesg_ppe_error"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PPE probe 报错验收竟然放行！"
        exit 1
    fi

    # 10b: 仅有纯软件 flowtable 缺乏 hw_offload 硬件卸载标志时必须拦截
    touch "$MOCK_STATE/nft_has_flowtable_sw"
    set +e
    sh "$HELPER_SCRIPT" verify ppe --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_ppe_sw.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/nft_has_flowtable_sw"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 纯软件 flowtable 缺乏 hw_offload 标志竟然被放行！"
        exit 1
    fi
    if ! grep -q "缺少 hw_offload 硬件卸载标志" "$TEST_SANDBOX/t10_ppe_sw.log"; then
        echo "FAIL: 纯软件 flowtable 报错信息不符合预期: $(cat "$TEST_SANDBOX/t10_ppe_sw.log")"
        exit 1
    fi

    # 10c: flowtable 包含 hw_offload 且无 dmesg 报错时验证通过
    touch "$MOCK_STATE/nft_has_flowtable_hw"
    set +e
    sh "$HELPER_SCRIPT" verify ppe --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t10_ppe_hw.log" 2>&1
    ret=$?
    set -e
    rm -f "$MOCK_STATE/nft_has_flowtable_hw"
    if [ "$ret" -ne 0 ]; then
        echo "FAIL: PPE 硬件加速 (hw_offload) 验收未通过: $(cat "$TEST_SANDBOX/t10_ppe_hw.log")"
        exit 1
    fi
    if ! grep -q "PPE 硬件加速状态: 已生效" "$TEST_SANDBOX/t10_ppe_hw.log"; then
        echo "FAIL: PPE 硬件加速成功提示信息异常: $(cat "$TEST_SANDBOX/t10_ppe_hw.log")"
        exit 1
    fi

    # 10d: Docker 端口映射失败必须拦截
    touch "$MOCK_STATE/docker_fail_port_mapping"
    set +e
    sh "$HELPER_SCRIPT" verify docker --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_docker.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/docker_fail_port_mapping"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: Docker 端口映射失败验收竟然放行！"
        exit 1
    fi

    # 10e: PassWall2 核心未运行必须拦截
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_pw.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PassWall2 未运行验收竟然放行！"
        exit 1
    fi

    # 10f: PassWall2 存在运行核心但未找到实际端口配置（禁止盲猜 1080）必须拦截
    touch "$MOCK_STATE/pgrep_running_sing-box"
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_pw_port.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/pgrep_running_sing-box"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PassWall2 端口缺失盲猜 1080 竟然放行！"
        exit 1
    fi

    # 10g: PassWall2 存在 TLS 握手报错日志必须拦截
    touch "$MOCK_STATE/pgrep_running_sing-box"
    mkdir -p "$SYS_ROOT/var/etc/passwall2"
    echo '{"inbounds":[{"port":1080}]}' > "$SYS_ROOT/var/etc/passwall2/TCP.json"
    touch "$MOCK_STATE/logread_tls_error"
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_pw_tls.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/pgrep_running_sing-box" "$MOCK_STATE/logread_tls_error"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PassWall2 日志存在 TLS 握手错误却验收放行！"
        exit 1
    fi

    # 10h: PassWall2 配置文件语法错误必须拦截
    touch "$MOCK_STATE/pgrep_running_sing-box"
    touch "$MOCK_STATE/jq_fail"
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_pw_jq.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/pgrep_running_sing-box" "$MOCK_STATE/jq_fail"
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PassWall2 配置文件 JSON 语法错误却放行！"
        exit 1
    fi

    # 10i: PassWall2 配置文件 outbounds 在前且包含远程端口时，必须精准提取 inbounds 本地 socks 端口 (禁止误抓 outbounds 8443)
    touch "$MOCK_STATE/pgrep_running_sing-box"
    cat << 'EOF_PW' > "$SYS_ROOT/var/etc/passwall2/TCP.json"
{
  "outbounds": [
    {
      "type": "shadowsocks",
      "tag": "proxy-out",
      "server": "198.51.100.1",
      "server_port": 8443
    }
  ],
  "inbounds": [
    {
      "type": "socks",
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "listen_port": 1080
    }
  ]
}
EOF_PW
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" >"$TEST_SANDBOX/t10_pw_inb.log" 2>&1
    ret=$?
    set -e
    rm -f "$MOCK_STATE/pgrep_running_sing-box" "$SYS_ROOT/var/etc/passwall2/TCP.json"
    if [ "$ret" -ne 0 ]; then
        echo "FAIL: PassWall2 正确提取 inbounds 端口后握手竟然失败: $(cat "$TEST_SANDBOX/t10_pw_inb.log")"
        exit 1
    fi
    if ! grep -q "定位到活动核心 SOCKS 本地监听端口: 1080" "$TEST_SANDBOX/t10_pw_inb.log"; then
        echo "FAIL: 未能定位到 1080 或误提取了 8443: $(cat "$TEST_SANDBOX/t10_pw_inb.log")"
        exit 1
    fi
)
echo "PASS: 测试 10 通过（运行时验收各项失败分支均有效阻断，inbounds 端口精准提取，硬件 flowtable 校验完整）"

# -----------------------------------------------------------------------------
# 测试 11: 验证资源清理安全不越界
# -----------------------------------------------------------------------------
echo "--- 测试 11: 验证测试沙箱隔离与清理范围 ---"
(
    if [ ! -d "$TEST_SANDBOX" ]; then
        echo "FAIL: 沙箱路径异常！"
        exit 1
    fi
)
echo "PASS: 测试 11 通过（沙箱清理逻辑安全受控）"

# -----------------------------------------------------------------------------
# 测试 12: 备份清单篡改与关键文件缺失严格阻断恢复
# -----------------------------------------------------------------------------
echo "--- 测试 12: 备份完整性、缺失项与哈希篡改拦截验证 ---"
(
    BKP_STORE="$TEST_SANDBOX/bkp_external/docker_bkp"
    DST_DOCKER="$TEST_SANDBOX/dst_docker"
    T12_BKP="$TEST_SANDBOX/t12_bkp"
    rm -rf "$T12_BKP"
    cp -r "$BKP_STORE" "$T12_BKP"

    # 12a: 关键文件缺失 (删除 docker_volumes.tar.gz) 必须被拦截
    rm -f "$T12_BKP/docker_volumes.tar.gz"
    set +e
    sh "$T12_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T12_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t12_missing.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 缺失 docker_volumes.tar.gz 时恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(关键备份文件缺失|缺少|校验失败)" "$TEST_SANDBOX/t12_missing.log"; then
        echo "FAIL: 缺失文件报错信息异常: $(cat "$TEST_SANDBOX/t12_missing.log")"
        exit 1
    fi

    # 12b: 文件哈希篡改 (篡改 docker_bind_mounts.tar.gz 内容) 必须被 sha256 校验拦截
    rm -rf "$T12_BKP"
    cp -r "$BKP_STORE" "$T12_BKP"
    echo "tampered_corrupted_data" >> "$T12_BKP/docker_bind_mounts.tar.gz"
    set +e
    sh "$T12_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T12_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t12_hash.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 备份文件哈希被篡改时恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(sha256|哈希|校验失败)" "$TEST_SANDBOX/t12_hash.log"; then
        echo "FAIL: 哈希篡改报错信息异常: $(cat "$TEST_SANDBOX/t12_hash.log")"
        exit 1
    fi

    # 12c: 清单中记录的 Compose 项目包缺失必须被拦截
    rm -rf "$T12_BKP"
    cp -r "$BKP_STORE" "$T12_BKP"
    rm -f "$T12_BKP/compose/my_proj.tar.gz"
    set +e
    sh "$T12_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T12_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t12_comp_missing.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 缺失 Compose 归档时恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(关键备份文件缺失|缺失|校验失败)" "$TEST_SANDBOX/t12_comp_missing.log"; then
        echo "FAIL: 缺失 Compose 归档报错信息异常: $(cat "$TEST_SANDBOX/t12_comp_missing.log")"
        exit 1
    fi
)
echo "PASS: 测试 12 通过（备份清单缺失项与哈希篡改均被严格拦截阻断恢复）"

# -----------------------------------------------------------------------------
# 测试 13: 恢复目标设备挂载安全性校验（DataRoot、Compose 路径、Bind 路径未挂载外部盘严格拦截）
# -----------------------------------------------------------------------------
echo "--- 测试 13: 恢复阶段全目标路径挂载安全性核验 ---"
(
    BKP_STORE="$TEST_SANDBOX/bkp_external/docker_bkp"
    DST_DOCKER="$TEST_SANDBOX/dst_docker"
    T13_BKP="$TEST_SANDBOX/t13_bkp"
    rm -rf "$T13_BKP"
    cp -r "$BKP_STORE" "$T13_BKP"
    mkdir -p "$SYS_ROOT/mnt/unmounted_disk"

    # 13a: TARGET_DATA_ROOT 位于未挂载路径 (fallback 到 overlay /) 时拦截
    set +e
    sh "$T13_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T13_BKP" \
        --target-data-root "$TEST_SANDBOX/unmounted_external_disk/docker" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t13_dataroot.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: DataRoot 位于未挂载路径恢复竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(位于根文件系统或内部 /overlay|易失或升级重置设备)" "$TEST_SANDBOX/t13_dataroot.log"; then
        echo "FAIL: DataRoot 挂载安全报错信息异常: $(cat "$TEST_SANDBOX/t13_dataroot.log")"
        exit 1
    fi

    # 13b: Compose 项目目标目录位于未挂载路径时拦截
    rm -rf "$T13_BKP"
    cp -r "$BKP_STORE" "$T13_BKP"
    printf 'unmounted_proj\t/mnt/unmounted_disk/my_app\t/mnt/unmounted_disk/my_app/docker-compose.yml\n' > "$T13_BKP/metadata/compose_manifest.tsv"
    tar -czf "$T13_BKP/compose/unmounted_proj.tar.gz" -T /dev/null 2>/dev/null || touch "$T13_BKP/compose/unmounted_proj.tar.gz"
    (
        cd "$T13_BKP"
        rm -f sha256sums.txt backup_manifest.txt
        find . -type f | sort | while IFS= read -r f; do
            clean_f="${f#./}"
            sha256sum "$clean_f"
        done > sha256sums.txt
        echo "manifest" > backup_manifest.txt
        sha256sum backup_manifest.txt >> sha256sums.txt
    )

    set +e
    sh "$T13_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T13_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t13_compose.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: Compose 恢复目标位于未挂载路径时竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(位于根文件系统或内部 /overlay|易失或升级重置设备)" "$TEST_SANDBOX/t13_compose.log"; then
        echo "FAIL: Compose 挂载安全报错信息异常: $(cat "$TEST_SANDBOX/t13_compose.log")"
        exit 1
    fi

    # 13c: Bind Mount 目标目录位于未挂载路径时拦截
    rm -rf "$T13_BKP"
    cp -r "$BKP_STORE" "$T13_BKP"
    echo "/mnt/unmounted_disk/bind_data" >> "$T13_BKP/metadata/bind_mounts.txt"
    (
        cd "$T13_BKP"
        rm -f sha256sums.txt backup_manifest.txt
        find . -type f | sort | while IFS= read -r f; do
            clean_f="${f#./}"
            sha256sum "$clean_f"
        done > sha256sums.txt
        echo "manifest" > backup_manifest.txt
        sha256sum backup_manifest.txt >> sha256sums.txt
    )

    set +e
    sh "$T13_BKP/docker_upgrade_helper.sh" restore \
        --backup-dir "$T13_BKP" \
        --target-data-root "$DST_DOCKER" \
        --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t13_bind.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: Bind Mount 恢复目标位于未挂载路径时竟然放行！"
        exit 1
    fi
    if ! grep -qiE "(位于根文件系统或内部 /overlay|易失或升级重置设备)" "$TEST_SANDBOX/t13_bind.log"; then
        echo "FAIL: Bind Mount 挂载安全报错信息异常: $(cat "$TEST_SANDBOX/t13_bind.log")"
        exit 1
    fi
)
echo "PASS: 测试 13 通过（恢复阶段 DataRoot、Compose、Bind 目标路径未挂载外部盘全部被严格拦截）"

# -----------------------------------------------------------------------------
# 测试 14: 独立容器多网络拓扑备份阻断
# -----------------------------------------------------------------------------
echo "--- 测试 14: 独立容器连接多个网络备份阻断 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/t14_docker"
    T14_TARGET="$TEST_SANDBOX/t14_target"
    mkdir -p "$MOCK_DOCKER_ROOT/volumes" "$T14_TARGET"

    echo "multi_net_cid" > "$MOCK_STATE/containers_list_ids"
    echo "multi_net_app" > "$MOCK_STATE/cname_multi_net_cid"
    echo "alpine:latest" > "$MOCK_STATE/cimg_multi_net_cid"
    echo "2" > "$MOCK_STATE/net_count_multi_net_cid"

    set +e
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$MOCK_DOCKER_ROOT" \
        --target-dir "$T14_TARGET" \
        --sys-root "$SYS_ROOT" \
        --skip-stop 2>"$TEST_SANDBOX/t14.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/containers_list_ids" "$MOCK_STATE/net_count_multi_net_cid"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 连接多个网络的独立容器备份竟然放行！"
        exit 1
    fi
    if ! grep -q "连接了多个网络" "$TEST_SANDBOX/t14.log"; then
        echo "FAIL: 多网络报错信息不符合预期: $(cat "$TEST_SANDBOX/t14.log")"
        exit 1
    fi
)
echo "PASS: 测试 14 通过（连接多个网络的独立容器在备份阶段被成功阻断并提示迁移编排）"

echo "=== 全部 14 项深度隔离测试与回归演练已通过！ ==="
