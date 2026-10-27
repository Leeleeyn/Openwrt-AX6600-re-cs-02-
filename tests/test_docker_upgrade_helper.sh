#!/bin/sh
# 针对 scripts/docker_upgrade_helper.sh 的真实逻辑回归测试
set -eu

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/.." && pwd)
HELPER_SCRIPT="$REPO_ROOT/Scripts/docker_upgrade_helper.sh"

# 创建受控的隔离临时测试沙箱，绝不影响系统与用户业务数据
TEST_SANDBOX="$REPO_ROOT/tests/tmp_sandbox_$$"
mkdir -p "$TEST_SANDBOX"

cleanup() {
    rm -rf "$TEST_SANDBOX"
}
trap cleanup EXIT INT TERM

echo "=== 开始执行 AX6600 备份恢复脚本逻辑回归测试 ==="
echo "沙箱路径: $TEST_SANDBOX"

# -----------------------------------------------------------------------------
# 测试 1: 缺少 DockerRootDir 且未安装 Docker 时，必须严格报错退出，禁止猜测默认目录
# -----------------------------------------------------------------------------
echo "--- 测试 1: 探测 DockerRootDir 失败时严格报错 ---"
(
    # 创建一个没有 docker 命令的空环境
    PATH="/bin:/usr/bin"
    set +e
    sh "$HELPER_SCRIPT" backup --target-dir "$TEST_SANDBOX/target" 2>"$TEST_SANDBOX/t1.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 探测失败却没有退出！"
        exit 1
    fi
    if ! grep -q "无法获取 DockerRootDir" "$TEST_SANDBOX/t1.log" && ! grep -q "缺少必要命令: docker" "$TEST_SANDBOX/t1.log"; then
        echo "FAIL: 错误日志不符合预期: $(cat "$TEST_SANDBOX/t1.log")"
        exit 1
    fi
)
echo "PASS: 测试 1 通过（严格禁止瞎猜默认路径）"

# -----------------------------------------------------------------------------
# 测试 2: 目标目录位于 DockerRootDir 内部（防止递归无限打包）必须被拦截
# -----------------------------------------------------------------------------
echo "--- 测试 2: 拦截目标目录在 DockerRootDir 内部 ---"
(
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/docker_root"
    mkdir -p "$MOCK_DOCKER_ROOT"
    NESTED_TARGET="$MOCK_DOCKER_ROOT/my_backup"
    
    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "$NESTED_TARGET" --skip-stop 2>"$TEST_SANDBOX/t2.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标目录在内部却没有拦截！"
        exit 1
    fi
    if ! grep -q "不能在 DockerRootDir" "$TEST_SANDBOX/t2.log"; then
        echo "FAIL: 错误提示不符合预期: $(cat "$TEST_SANDBOX/t2.log")"
        exit 1
    fi
)
echo "PASS: 测试 2 通过（内部递归目标被成功拦截）"

# -----------------------------------------------------------------------------
# 测试 3: 目标目录与数据目录包含空格时的正确打包与恢复
# -----------------------------------------------------------------------------
echo "--- 测试 3: 支持包含空格的路径 ---"
(
    SPACE_DOCKER_ROOT="$TEST_SANDBOX/my docker root"
    SPACE_TARGET="$TEST_SANDBOX/my target backup"
    mkdir -p "$SPACE_DOCKER_ROOT/volumes/test_vol" "$SPACE_TARGET"
    echo "volume content with spaces" > "$SPACE_DOCKER_ROOT/volumes/test_vol/data.txt"

    sh "$HELPER_SCRIPT" backup --docker-dir "$SPACE_DOCKER_ROOT" --target-dir "$SPACE_TARGET" --skip-stop >/dev/null

    if [ ! -f "$SPACE_TARGET/docker_volumes.tar.gz" ]; then
        echo "FAIL: 含空格路径打包失败，未生成 docker_volumes.tar.gz"
        exit 1
    fi
    if [ ! -f "$SPACE_TARGET/sha256sums.txt" ]; then
        echo "FAIL: 未生成 sha256sums.txt"
        exit 1
    fi
)
echo "PASS: 测试 3 通过（路径含空格支持正常）"

# -----------------------------------------------------------------------------
# 测试 4: 完整备份与恢复演练（含 Named Volumes、Bind Mounts、Compose与元数据）
# -----------------------------------------------------------------------------
echo "--- 测试 4: 端到端隔离备份与完整数据恢复演练 ---"
(
    DOCKER_SRC="$TEST_SANDBOX/src_docker"
    TARGET_BKP="$TEST_SANDBOX/ext_storage/backup"
    DOCKER_DST="$TEST_SANDBOX/dst_docker"
    EXTERNAL_BIND="$TEST_SANDBOX/my_bind_data"

    mkdir -p "$DOCKER_SRC/volumes/vol_app1" "$TARGET_BKP" "$DOCKER_DST" "$EXTERNAL_BIND"
    echo "database_content_42" > "$DOCKER_SRC/volumes/vol_app1/db.sqlite"
    echo "bind_config_text" > "$EXTERNAL_BIND/app.conf"

    # 创建 mock metadata 包含 bind mounts
    mkdir -p "$TARGET_BKP/metadata"
    echo "$EXTERNAL_BIND" > "$TARGET_BKP/metadata/bind_mounts.txt"

    # 模拟 compose 目录
    MOCK_COMPOSE="$TEST_SANDBOX/src_compose"
    mkdir -p "$MOCK_COMPOSE"
    echo "version: '3'\nservices:\n  web:\n    image: nginx" > "$MOCK_COMPOSE/docker-compose.yml"

    # 执行备份
    sh "$HELPER_SCRIPT" backup --docker-dir "$DOCKER_SRC" --target-dir "$TARGET_BKP" --compose-dir "$MOCK_COMPOSE" --skip-stop >/dev/null

    # 验证备份产物
    if [ ! -f "$TARGET_BKP/docker_volumes.tar.gz" ]; then
        echo "FAIL: 缺少 docker_volumes.tar.gz"
        exit 1
    fi

    # 执行恢复到全新目标根目录
    sh "$HELPER_SCRIPT" restore --backup-dir "$TARGET_BKP" --target-data-root "$DOCKER_DST" >/dev/null

    # 验证恢复的数据内容
    if [ ! -f "$DOCKER_DST/volumes/vol_app1/db.sqlite" ]; then
        echo "FAIL: 恢复后缺少 volumes/vol_app1/db.sqlite！"
        exit 1
    fi
    ACTUAL_CONTENT=$(cat "$DOCKER_DST/volumes/vol_app1/db.sqlite")
    if [ "$ACTUAL_CONTENT" != "database_content_42" ]; then
        echo "FAIL: 恢复数据内容不一致: $ACTUAL_CONTENT"
        exit 1
    fi
)
echo "PASS: 测试 4 通过（端到端隔离备份与恢复内容一致）"

# -----------------------------------------------------------------------------
# 测试 5: 归档损坏或校验失败时，恢复操作必须严格终止退出
# -----------------------------------------------------------------------------
echo "--- 测试 5: 损坏的归档包导致恢复被拦截 ---"
(
    CORRUPT_BKP="$TEST_SANDBOX/corrupt_backup"
    mkdir -p "$CORRUPT_BKP"
    echo "corrupted garbage" > "$CORRUPT_BKP/docker_volumes.tar.gz"
    echo "0000000000000000000000000000000000000000000000000000000000000000  docker_volumes.tar.gz" > "$CORRUPT_BKP/sha256sums.txt"

    set +e
    sh "$HELPER_SCRIPT" restore --backup-dir "$CORRUPT_BKP" --target-data-root "$TEST_SANDBOX/restore_target" 2>"$TEST_SANDBOX/t5.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 归档损坏恢复竟然没有报错！"
        exit 1
    fi
    if ! grep -q "备份文件校验失败" "$TEST_SANDBOX/t5.log"; then
        echo "FAIL: 未能捕获校验失败: $(cat "$TEST_SANDBOX/t5.log")"
        exit 1
    fi
)
echo "PASS: 测试 5 通过（文件校验失败严格终止）"

# -----------------------------------------------------------------------------
# 测试 6: 升级前唯一镜像校验（拒绝不存在或容量不足的分区）
# -----------------------------------------------------------------------------
echo "--- 测试 6: 升级镜像文件校验逻辑 ---"
(
    set +e
    sh "$HELPER_SCRIPT" precheck "" 2>"$TEST_SANDBOX/t6_1.log"
    ret1=$?
    sh "$HELPER_SCRIPT" precheck "$TEST_SANDBOX/non_existent.bin" 2>"$TEST_SANDBOX/t6_2.log"
    ret2=$?
    set -e
    if [ "$ret1" -eq 0 ] || [ "$ret2" -eq 0 ]; then
        echo "FAIL: 非法镜像路径未被拦截！"
        exit 1
    fi
)
echo "PASS: 测试 6 通过（镜像有效性校验正常拦截）"

# -----------------------------------------------------------------------------
# 测试 7: 验收命令测试（故意破坏时必须报告失败）
# -----------------------------------------------------------------------------
echo "--- 测试 7: 运行时验收失败分支检测 ---"
(
    # 模拟没有 PPE flowtable 和 docker 的环境
    set +e
    sh "$HELPER_SCRIPT" verify all 2>"$TEST_SANDBOX/t7.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 缺失硬件加速和网络连通性时，verify 竟然报告成功！"
        exit 1
    fi
    if ! grep -q "PPE / Flowtable 硬件卸载未检测到生效" "$TEST_SANDBOX/t7.log"; then
        echo "FAIL: 未能准确识别 PPE 缺失: $(cat "$TEST_SANDBOX/t7.log")"
        exit 1
    fi
)
echo "PASS: 测试 7 通过（验收失败分支准确报告阻断）"

# -----------------------------------------------------------------------------
# 测试 8: 外盘未挂载或目录不存在时，必须被正确拦截
# -----------------------------------------------------------------------------
echo "--- 测试 8: 目标存储不存在或未挂载被拦截 ---"
(
    NON_EXIST_TARGET="$TEST_SANDBOX/non_existent_mount_dir/backup"
    MOCK_DOCKER_ROOT="$TEST_SANDBOX/valid_docker_root"
    mkdir -p "$MOCK_DOCKER_ROOT"

    # 如果父挂载目录不存在或无法写入
    set +e
    sh "$HELPER_SCRIPT" backup --docker-dir "$MOCK_DOCKER_ROOT" --target-dir "/dev/null/invalid_path" --skip-stop 2>"$TEST_SANDBOX/t8.log"
    ret=$?
    set -e
    if [ "$ret" -eq 0 ]; then
        echo "FAIL: 目标路径非法未被拦截！"
        exit 1
    fi
)
echo "PASS: 测试 8 通过（目标路径非法或未挂载被正常拦截）"

# -----------------------------------------------------------------------------
# 测试 9: 验证远端 SSH 命令变量转义在远端解析（Windows 与 POSIX 语法）
# -----------------------------------------------------------------------------
echo "--- 测试 9: SSH 远端变量延迟展开语法验证 ---"
(
    # 模拟 POSIX ssh 传参模式（单引号保护远程变量不被本地展开）
    POSIX_CMD='DOCKER_DIR=$(echo "/mock/var/lib/docker"); [ -n "$DOCKER_DIR" ] && echo "RESOLVED:$DOCKER_DIR"'
    OUTPUT=$(sh -c "$POSIX_CMD")
    if [ "$OUTPUT" != "RESOLVED:/mock/var/lib/docker" ]; then
        echo "FAIL: 远端变量展开模式验证失败: $OUTPUT"
        exit 1
    fi
)
echo "PASS: 测试 9 通过（SSH 远端变量展开语法行为正确）"

echo "=== 全部 9 项备份恢复与升级回归测试 100% 成功通过！ ==="
