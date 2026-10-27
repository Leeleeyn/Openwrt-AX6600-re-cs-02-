# 京东云 AX6600 雅典娜 保留配置升级与 Docker 备份恢复指南

本指南适用于京东云 AX6600（雅典娜 RE-CS-02）从旧版固件升级至 Linux 6.18 LTS（Qualcomm PPE + firewall4）固件。提供升级前容量体检、Docker 全量备份与恢复、NSS 遗留项清理及运行时验收命令。

---

## 一、升级前红线与只读检查

### 1. 目标分区容量核对（严禁 60MB 原厂分区刷入 PLUS）
```bash
# 查看 eMMC rootfs 分区大小
fdisk -l /dev/mmcblk0 | grep -E "rootfs|rootfs_1"
```
- **容量判定**：若待升级目标 `rootfs` 分区仅为 `60M` 或小于 `200M`，**严禁刷入 PLUS 版**（升级包解压后约 152.35MB，会溢出损坏）；请先刷入扩容分区表或选择 35MB 的 `PURE` 版。
- 双分区机型必须确认实际待升级的对侧分区大小，绝不能盲目取两者中较大的一个。若分区为 `512M` 或更大，可安全刷入。

### 2. 单一镜像文件校验与机型预检
定义唯一的 `IMAGE` 变量，拒绝通配符多匹配，并核对 SHA256 校验和：
```bash
IMAGE="/tmp/ones20250-owrt-plus-ipq60xx-jdcloud_re-cs-02-squashfs-sysupgrade-26.10.27-01.38.58.bin"

[ ! -f "$IMAGE" ] && { echo "固件文件不存在: $IMAGE"; exit 1; }
sha256sum "$IMAGE"
sysupgrade -T "$IMAGE" || { echo "机型兼容性校验未通过，禁止刷入"; exit 1; }
```

### 3. Docker 路径与存储位置确认
```bash
# 必须在 dockerd 运行状态下探测真实 DockerRootDir，禁止猜测默认路径
DOCKER_ROOT=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null)
[ -z "$DOCKER_ROOT" ] && { echo "无法获取 DockerRootDir，dockerd 未运行"; exit 1; }

echo "当前 DockerRootDir: $DOCKER_ROOT"
df -h "$DOCKER_ROOT"
```
> **注意**：`sysupgrade` 即使保留配置，内部 flash 的 `/overlay` 分区仍会被重置。若 DockerRootDir 位于 `/overlay`，升级会导致容器数据被清空，升级前必须导出备份到外部介质或电脑。

---

## 二、Docker 全量备份流程（停机前导出元数据与配置）

备份工具使用项目内的 `Scripts/docker_upgrade_helper.sh`。备份目标必须是外部真实挂载介质（如 `/mnt/sda1`），空间充足且不在 `/overlay` 或 `/tmp` 内。

备份脚本会自动将自身复制到备份目录（`$TARGET_DIR/docker_upgrade_helper.sh`），保证升级重启后 `/tmp` 丢失时外部存储仍存有恢复工具。

### 1. 路由器本地执行
```bash
# 1. 将仓库 Scripts/docker_upgrade_helper.sh 上传至路由器 /tmp
chmod +x /tmp/docker_upgrade_helper.sh

# 2. 执行备份（自动探测 Docker 路径、导出容器与 Compose 配置包括 .env、生成独立容器重建脚本、停机归档 Named Volumes 与 Bind Mounts、生成 SHA256 校验）
/tmp/docker_upgrade_helper.sh backup --target-dir /mnt/sda1/docker_backup_$(date +%Y%m%d)
```

### 2. 跨平台 SSH 远程触发单行命令（确保变量在路由器端解析）

#### Linux / macOS 终端
```bash
ssh root@192.168.1.1 'sh -c "
set -e
TARGET=/mnt/sda1/docker_backup_\$(date +%Y%m%d)
/tmp/docker_upgrade_helper.sh backup --target-dir \"\$TARGET\"
"'
```

#### Windows PowerShell 终端
```powershell
$cmd = @'
set -e
TARGET=/mnt/sda1/docker_backup_$(date +%Y%m%d)
/tmp/docker_upgrade_helper.sh backup --target-dir "$TARGET"
'@
ssh root@192.168.1.1 "sh -c '$cmd'"
```

---

## 三、保留配置刷入与 NSS 遗留项清理

### 1. 执行保留配置刷入
```bash
IMAGE="/tmp/ones20250-owrt-plus-ipq60xx-jdcloud_re-cs-02-squashfs-sysupgrade-26.10.27-01.38.58.bin"
sysupgrade -c -v "$IMAGE"
```

### 2. 重启后清理废弃 NSS 防火墙配置
系统重启后，检查并清理失效的 NSS 钩子（核对节类型为 `include` 且脚本路径精确匹配旧版脚本，严禁删除同名 rule、redirect 或自定义 include）：
```bash
# 直接使用备份盘中的 helper 执行清理
/mnt/sda1/docker_backup_*/docker_upgrade_helper.sh clean-nss
```
或直接通过 UCI 核对后清理：
```bash
if uci -q get firewall.qcanssecm >/dev/null; then
    SEC_TYPE=$(uci -q get firewall.qcanssecm || true)
    SCRIPT_PATH=$(uci -q get firewall.qcanssecm.path || true)
    if [ "$SEC_TYPE" = "include" ]; then
        case "$SCRIPT_PATH" in
            /etc/firewall.d/qca-nss-ecm|/etc/firewall.d/qca-nss|/etc/firewall.nss)
                echo "清理废弃 NSS 钩子: firewall.qcanssecm"
                uci delete firewall.qcanssecm
                uci commit firewall
                /etc/init.d/firewall reload
                ;;
        esac
    fi
fi
```

---

## 四、Docker 完整恢复流程

升级完成后，先确认外部数据盘已真实挂载，使用备份目录中的 helper 执行恢复（不依赖升级前的临时文件或旧环境变量）：

```bash
# 1. 确认外置存储挂载（不能只看路径存在，必须核对挂载点与设备）
df -h | grep /mnt/sda1 || mount /mnt/sda1

# 2. 执行完整数据与服务恢复
# 自动校验 sha256sums.txt，恢复配置与 data-root，释放 volumes 与 bind mounts 至宿主原路径，仅拉起记录的项目并按原记录恢复自启
/mnt/sda1/docker_backup_*/docker_upgrade_helper.sh restore \
    --backup-dir /mnt/sda1/docker_backup_20261027 \
    --target-data-root /mnt/sda1/docker_data
```

---

## 五、升级后运行时验收

升级与数据恢复后，运行以下验收命令核实核心功能：

```bash
# 推荐使用 helper 统一验收
/mnt/sda1/docker_backup_*/docker_upgrade_helper.sh verify all
```

或手动执行分步验收：

```bash
# 1. 验证 PPE 硬件加速与 Flowtable
if nft list tables | grep -q "flowtable"; then
    echo "PPE Flowtable 卸载已生效"
else
    echo "ERROR: PPE Flowtable 未生效" >&2
    exit 1
fi

# 2. 验证 Docker 容器出网与端口转发
if docker run --rm alpine sh -c "wget -q -T 5 -O - http://connectivitycheck.gstatic.com/generate_204 || wget -q -T 5 -O - http://www.baidu.com" >/dev/null 2>&1; then
    echo "Docker 容器出网正常"
else
    echo "ERROR: Docker 容器网络出网异常" >&2
    exit 1
fi

CID=$(docker run -d -p 127.0.0.1:18888:80 alpine sh -c "echo -e 'HTTP/1.1 200 OK\r\n\r\nPORT_OK' | nc -l -p 80")
sleep 1
RESP=$(curl -m 3 -s http://127.0.0.1:18888 || true)
docker rm -f "$CID" >/dev/null 2>&1 || true
if ! echo "$RESP" | grep -q "PORT_OK"; then
    echo "ERROR: Docker 端口映射转发异常" >&2
    exit 1
fi
echo "Docker 端口映射转发正常"

# 3. 验证 PassWall2 实际代理核心与真实握手
PW_CORE=""
pgrep -x sing-box >/dev/null && PW_CORE="sing-box"
pgrep -x xray >/dev/null && PW_CORE="xray"

if [ -n "$PW_CORE" ]; then
    echo "PassWall2 活动核心: $PW_CORE"
    SOCKS_PORT=""
    for cfg in /var/etc/passwall2/*.json; do
        [ -f "$cfg" ] || continue
        PORT_FOUND=$(grep -o '"port": *[0-9]*' "$cfg" | head -n 1 | awk '{print $2}' || true)
        [ -n "$PORT_FOUND" ] && { SOCKS_PORT="$PORT_FOUND"; break; }
    done
    [ -z "$SOCKS_PORT" ] && { echo "ERROR: 无法定位 PassWall2 实际 SOCKS 端口" >&2; exit 1; }
    echo "活动核心本地 SOCKS 端口: $SOCKS_PORT"
    curl --socks5-hostname "127.0.0.1:$SOCKS_PORT" -m 10 -s -I https://www.google.com >/dev/null || {
        echo "ERROR: PassWall2 真实代理握手失败" >&2
        exit 1
    }
    echo "PassWall2 代理连通正常"
else
    echo "ERROR: PassWall2 核心未运行" >&2
    exit 1
fi
```
