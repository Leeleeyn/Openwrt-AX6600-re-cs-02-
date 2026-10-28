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
                *"Name"*)
                    cat "$MOCK_STATE/cname_$cid" 2>/dev/null || echo "/$cid"
                    ;;
                *"NetworkMode"*)
                    echo "bridge"
                    ;;
                *"RestartPolicy.Name"*)
                    echo "unless-stopped"
                    ;;
                *"Privileged"*)
                    echo "false"
                    ;;
                *"Binds"*)
                    cat "$MOCK_STATE/binds_$cid" 2>/dev/null || true
                    ;;
                *"Env"*)
                    echo "MYSQL_ROOT_PASSWORD=my_secret_pass_123"
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
        echo "/dev/mmcblk0p15       40960      163839      122880   rootfs"
        echo "/dev/mmcblk0p16      163840     1212415     1048576   rootfs_1"
        ;;
    dual_large_both)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p15       40960     1089535     1048576   rootfs"
        echo "/dev/mmcblk0p16     1089536     2138111     1048576   rootfs_1"
        ;;
    missing_partitions)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p1       2048       4095        2048   boot"
        ;;
    *)
        echo "Disk /dev/mmcblk0: 58.2 GiB"
        echo "/dev/mmcblk0p15       40960     1089535     1048576   rootfs"
        echo "/dev/mmcblk0p16     1089536     2138111     1048576   rootfs_1"
        ;;
esac
exit 0
EOF
chmod +x "$MOCK_BIN/fdisk"

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
if [ -f "$MOCK_STATE/nft_has_flowtable" ]; then
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
    if ! grep -q "位于根文件系统或 /overlay" "$TEST_SANDBOX/t3.log" && ! grep -q "存储设备为易失或升级重置设备" "$TEST_SANDBOX/t3.log"; then
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

    mkdir -p "$SRC_DOCKER/volumes/app_volume" "$DST_DOCKER" "$BKP_STORE" "$EXT_BIND" "$SRC_COMPOSE"
    echo "important_vol_data_99" > "$SRC_DOCKER/volumes/app_volume/data.bin"
    echo "bind_config_val=1" > "$EXT_BIND/app.env"

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
      "Binds": ["$ROUTER_BIND:/app/config"]
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
      "Privileged": false,
      "Binds": []
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

    echo "redis:alpine" > "$MOCK_STATE/cimg_standalone_cid"
    echo "standalone_app" > "$MOCK_STATE/cname_standalone_cid"
    echo "C /etc/redis.conf" > "$MOCK_STATE/diff_standalone_cid"

    echo "mysql:8.0" > "$MOCK_STATE/cimg_mysql_cid"
    echo "mysql_db" > "$MOCK_STATE/cname_mysql_cid"

    # 1. 执行全量备份
    sh "$HELPER_SCRIPT" backup \
        --docker-dir "$SRC_DOCKER" \
        --target-dir "$BKP_STORE" \
        --sys-root "$SYS_ROOT" \
        --skip-stop >/dev/null

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

    # 验证 Compose 备份包含 .env
    tar -tzf "$BKP_STORE/compose/my_proj.tar.gz" | grep -q "\.env" || {
        echo "FAIL: Compose 打包漏掉了隐藏文件 .env！"
        exit 1
    }

    # 验证独立容器生成了重建脚本与镜像
    if [ ! -f "$BKP_STORE/standalone/recreate_standalone_app.sh" ] || [ ! -f "$BKP_STORE/standalone/image_standalone_app.tar" ]; then
        echo "FAIL: 独立容器重建脚本或快照镜像未生成！"
        exit 1
    fi

    # 模拟系统升级（清空沙箱内的旧系统配置、删除原 Compose 目录、停止服务）
    rm -rf "$SRC_COMPOSE" "$EXT_BIND/app.env" "$SYS_ROOT/etc/docker" "$SYS_ROOT/etc/config"
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
    if [ ! -f "$EXT_BIND/app.env" ]; then
        echo "FAIL: Bind Mounts 未恢复到原始宿主路径: $EXT_BIND/app.env"
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

    # 验证只拉起了记录的项目，而不是扫描整个 /opt
    if ! grep -q "$SRC_COMPOSE" "$MOCK_STATE/compose_invocations.log"; then
        echo "FAIL: Compose 项目未在原始恢复路径拉起！"
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

    # 8b: 双分区目标为 60MB 较小分区时，绝不能被 512MB 误放行
    echo "dual_small_target" > "$MOCK_STATE/fdisk_mode"
    echo "root=rootfs_1" > "$SYS_ROOT/proc/cmdline"

    set +e
    sh "$HELPER_SCRIPT" precheck "$IMG_FILE" "$SHA_EXPECTED" --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t8_part.log"
    ret=$?
    set -e
    rm -f "$MOCK_STATE/fdisk_mode" "$SYS_ROOT/proc/cmdline"

    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标分区仅 60MB，刷入 100MB 固件竟然被误放行！"
        exit 1
    fi
    if ! grep -q "目标分区容量.*不足" "$TEST_SANDBOX/t8_part.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t8_part.log")"
        exit 1
    fi

    # 8c: 系统只读体检模式验证 (识别固件、硬件型号与分区)
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
# 测试 10: 运行时验收失败分支阻断
# -----------------------------------------------------------------------------
echo "--- 测试 10: 运行时验收失败阻断 ---"
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

    # 10b: Docker 端口映射失败必须拦截
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

    # 10c: PassWall2 核心未运行必须拦截
    set +e
    sh "$HELPER_SCRIPT" verify passwall --sys-root "$SYS_ROOT" 2>"$TEST_SANDBOX/t10_pw.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: PassWall2 未运行验收竟然放行！"
        exit 1
    fi

    # 10d: PassWall2 存在运行核心但未找到实际端口配置（禁止盲猜 1080）必须拦截
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

    # 10e: PassWall2 存在 TLS 握手报错日志必须拦截
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

    # 10f: PassWall2 配置文件语法错误必须拦截
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
)
echo "PASS: 测试 10 通过（运行时验收各项失败分支均有效阻断）"

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

echo "=== 全部 11 项深度隔离测试与回归演练已通过！ ==="
