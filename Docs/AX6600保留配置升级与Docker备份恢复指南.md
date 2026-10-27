# 京东云 AX6600 雅典娜 保留配置升级与 Docker 备份恢复指南

本指南专为运行 OpenWrt / ImmortalWrt 的京东云 AX6600（雅典娜 RE-CS-02）路由器编写，适用于从旧版固件（如 Linux 5.4 / 6.1 内核、NSS 闭源加速）升级至最新 Linux 6.18 LTS 内核（Qualcomm PPE 开源硬件加速 + firewall4）固件，涵盖升级前只读体检、Docker 全量数据备份、保留配置平滑升级、NSS 遗留项清理、以及升级后服务验收全流程。

---

## 目录
- [一、升级架构须知与三大误区纠正](#一升级架构须知与三大误区纠正)
- [二、升级前只读体检（路由器终端执行）](#二升级前只读体检路由器终端执行)
  - [1. 设备型号与当前固件检查](#1-设备型号与当前固件检查)
  - [2. 目标分区与空间核对（核心红线）](#2-目标分区与空间核对核心红线)
  - [3. Docker 运行状态与存储路径探测](#3-docker-运行状态与存储路径探测)
  - [4. Docker 数据存储位置归属判定](#4-docker-数据存储位置归属判定)
  - [5. 新固件校验值与兼容性预检](#5-新固件校验值与兼容性预检)
- [三、Docker 与应用数据完整备份方案](#三docker-与应用数据完整备份方案)
  - [1. 数据库应用一致性逻辑热备](#1-数据库应用一致性逻辑热备)
  - [2. 优雅停机顺序与影响说明](#2-优雅停机顺序与影响说明)
  - [3. 容器配置、清单与编排文件导出](#3-容器配置清单与编排文件导出)
  - [4. Named Volumes 与数据持久层备份（流式导出）](#4-named-volumes-与数据持久层备份流式导出)
  - [5. 备份归档完整性与校验验证](#5-备份归档完整性与校验验证)
- [四、保留配置升级与系统恢复标准流程 (SOP)](#四保留配置升级与系统恢复标准流程-sop)
  - [步骤 1：升级前检查与备份归档完毕](#步骤-1升级前检查与备份归档完毕)
  - [步骤 2：执行保留配置刷入](#步骤-2执行保留配置刷入)
  - [步骤 3：首次启动安全接管（防空目录覆盖）](#步骤-3首次启动安全接管防空目录覆盖)
  - [步骤 4：继承配置核验与 NSS 遗留项精准清理](#步骤-4继承配置核验与-nss-遗留项精准清理)
  - [步骤 5：软硬件加速与网络连通性核验](#步骤-5软硬件加速与网络连通性核验)
  - [步骤 6：Docker 数据挂载恢复与服务唤醒](#步骤-6docker-数据挂载恢复与服务唤醒)
- [五、升级后核心功能验收与排错方法](#五升级后核心功能验收与排错方法)
  - [1. Docker 防火墙后端与网络链路验证](#1-docker-防火墙后端与网络链路验证)
  - [2. PassWall2 节点平滑迁移与真实代理核验](#2-passwall2-节点平滑迁移与真实代理核验)

---

## 一、升级架构须知与三大误区纠正

本项目固件基于 **Linux 6.18 LTS** 内核，底层全面迁移至 **Qualcomm PPE 开源硬件加速** 驱动与 **Linux 原生 Flowtable 硬件卸载**（`kmod-nft-offload`），并搭载内嵌于 firewall4 的 **SONiC FullCone NAT1**。在进行系统升级前，请必须认清以下技术事实：

> [!CAUTION]
> ### 误区一：“sysupgrade 保留配置绝不会影响 overlay 中的 Docker 数据”【严重错误】
> - **底层机制**：OpenWrt 的 `sysupgrade` 机制在刷写 squashfs 固件时，即使勾选了“保留配置”（`sysupgrade -c`），保留的也仅仅是 `/etc/sysupgrade.conf` 中声明的文件及系统默认注册的配置文件（打包进 `/tmp/sysupgrade.tgz`）。在固件烧录后，**内部 Flash 的 overlay 分区会被格式化或重置**，之后再将备份的配置文件解包释放。
> - **灾难后果**：若用户的 Docker Root Dir 位于内部 Flash 的 overlay（默认 `/overlay/docker` 或未迁移的 `/var/lib/docker`），**直接升级将导致 Docker 镜像、容器、卷、可写层数据被彻底格式化清空**！必须在升级前完整备份到外部 PC 或独立存储介质。

> [!WARNING]
> ### 误区二：“雅典娜自带 64G/128G eMMC，随便刷入 160MB 的 PLUS 升级包”【严重错误】
> - **底层机制**：`sysupgrade` 写入的是特定的系统分区（`rootfs` 或 `rootfs_1`），**不能根据整机 eMMC 总容量判断能否刷入**。
> - **容量红线**：原厂默认分区表的 `rootfs` 分区仅分配了 **60MB**。而本项目 **PLUS 版升级包解压后约 152.35MB**。如果路由器仍在使用原厂 60MB 分区表，直接刷入 PLUS 版固件将导致**写入溢出、固件损坏或无法启动**！
> - **前置要求**：必须在刷机前通过终端确认当前设备已刷入双分区扩容 GPT 分区表（如 `rootfs512M` 或 `1024M`），确保目标系统分区容量大于 200MB 且留有充足的 overlay 缓冲空间。

> [!NOTE]
> ### 误区三：“原先只打包 /etc/docker 和 /etc/config/dockerman 就足够保护 Docker”【不完整】
> - `/etc/docker` 和 `/etc/config/dockerman` 仅保存了 Docker 守护进程的启动参数与 LuCI 界面配置。
> - 真正的业务核心：容器编排文件（`docker-compose.yml`、`.env`）、容器数据卷（`Named Volumes`）、本地持久化挂载（`Bind Mounts`）以及运行中数据库的事务数据必须按照规范单独执行应用级热备与归档导出。

---

## 二、升级前只读体检（路由器终端执行）

在进行任何升级操作前，请通过 SSH 连接至雅典娜路由器，逐行执行以下只读检查命令，确认环境健康度。

### 1. 设备型号与当前固件检查
```bash
# 确认设备型号
cat /tmp/sysinfo/model 2>/dev/null || cat /proc/cpuinfo | grep 'machine'

# 查看当前运行固件版本、内核与主机环境
ubus call system board
cat /etc/openwrt_release
uname -a
```

### 2. 目标分区与空间核对（核心红线）
核实当前启动分区与升级目标分区大小，严防原厂 60MB 分区刷入 PLUS 导致变砖：
```bash
# 查看当前活动根分区挂载点（观察 root= 指向 mmcblk0p18 还是 p20）
cat /proc/cmdline

# 查看 eMMC 各系统分区扇区分配与容量
lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,PARTLABEL /dev/mmcblk0 2>/dev/null || fdisk -l /dev/mmcblk0

# 专门检查 rootfs 与 rootfs_1 分区容量
fdisk -l /dev/mmcblk0 | grep -E "rootfs|rootfs_1"
```
**容量判定规则**：
- 若输出中 `rootfs` 与 `rootfs_1` 的容量为 `60M` 或小于 `200M`：**严禁刷入 PLUS 版固件！** 请先按照《刷机救砖教程》刷入 512M 或以上双分区分区表，或仅选择小于 35MB 的 `PURE` 纯净版。
- 若容量为 `512M`、`1024M` 或 `2048M`：目标分区空间充裕，可安全承载约 160MB 的 PLUS 升级镜像并保留足够的系统读写空间。

### 3. Docker 运行状态与存储路径探测
```bash
# 检查 Docker 版本与守护程序信息
docker version 2>/dev/null || echo "Docker 未运行或未安装"
docker info 2>/dev/null | grep -E "Server Version|Storage Driver|Docker Root Dir"

# 检查当前运行中与已停止的所有容器
docker ps -a --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Image}}"

# 检查数据卷 (Volumes)
docker volume ls

# 检查所有容器的挂载点映射 (Bind Mounts 与 Volumes)
for c in $(docker ps -aq 2>/dev/null); do
    echo "=== 容器: $(docker inspect -f '{{.Name}}' $c) ==="
    docker inspect -f '{{range .Mounts}}  [{{.Type}}] {{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' "$c"
done
```

### 4. Docker 数据存储位置归属判定
确定 Docker 数据实际存放位置，评估数据丢失风险：
```bash
DOCKER_DIR=$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2}')
[ -z "$DOCKER_DIR" ] && DOCKER_DIR="/var/lib/docker"

echo "当前 DockerRootDir 为: $DOCKER_DIR"
df -h "$DOCKER_DIR"

DOCKER_MNT=$(df -P "$DOCKER_DIR" | awk 'NR==2{print $6}')
DOCKER_DEV=$(df -P "$DOCKER_DIR" | awk 'NR==2{print $1}')
echo ">>> 存储设备: $DOCKER_DEV | 挂载点: $DOCKER_MNT <<<"

if [ "$DOCKER_MNT" = "/overlay" ]; then
    echo "⚠️【高危警告】DockerRootDir 位于内部 overlay！sysupgrade 升级时此目录必被清空，升级前必须导出备份到电脑！"
elif [[ "$DOCKER_MNT" == /mnt/* ]] || [ "$DOCKER_MNT" = "/opt" ]; then
    echo "✅【独立存储】DockerRootDir 位于独立挂载分区（$DOCKER_MNT），sysupgrade 不会覆写该分区，但升级后必须先核对挂载再启动 Docker！"
else
    echo "ℹ️ DockerRootDir 挂载位置为: $DOCKER_MNT"
fi
```

### 5. 新固件校验值与兼容性预检
下载新版固件（如 `...plus-sysupgrade.bin`）到路由器 `/tmp` 目录后：
```bash
# 1. 计算固件 SHA256 哈希
sha256sum /tmp/*.bin

# 2. 与 Release 发布的 sha256sums.txt 进行比对，确保传输 100% 完整无损

# 3. 兼容性只读模拟检测（-T 参数仅验证固件头部与机型适配，绝不触发刷写）
sysupgrade -T /tmp/*-sysupgrade.bin
```
若命令输出包含 `Device jdcloud,re-cs-02 not supported by image` 或返回错误，严禁继续强行刷入！

---

## 三、Docker 与应用数据完整备份方案

### 1. 数据库应用一致性逻辑热备
冷打包正在运行的数据库文件可能导致事务锁死或损坏。在停机前，对常见容器数据库执行逻辑 Dump：
```bash
# 创建临时备份暂存目录（若有外接 USB 介质请存入 /mnt/sda1，严禁存入内存 /tmp）
BACKUP_DIR="/mnt/mmcblk0p27/backup_pre_upgrade"
mkdir -p "$BACKUP_DIR"

# MySQL / MariaDB 容器逻辑备份示例
if docker ps | grep -qi mysql; then
    MYSQL_ID=$(docker ps | grep -i mysql | awk '{print $1}')
    docker exec "$MYSQL_ID" mysqldump -uroot -p<数据库密码> --all-databases --single-transaction --quick > "$BACKUP_DIR/mysql_all_dump.sql"
    echo "MySQL 逻辑备份已完成: $BACKUP_DIR/mysql_all_dump.sql"
fi

# PostgreSQL 容器逻辑备份示例
if docker ps | grep -qi postgres; then
    PG_ID=$(docker ps | grep -i postgres | awk '{print $1}')
    docker exec "$PG_ID" pg_dumpall -U <postgres用户> > "$BACKUP_DIR/pg_all_dump.sql"
    echo "PostgreSQL 逻辑备份已完成: $BACKUP_DIR/pg_all_dump.sql"
fi

# Redis 容器持久化触发示例
if docker ps | grep -qi redis; then
    REDIS_ID=$(docker ps | grep -i redis | awk '{print $1}')
    docker exec "$REDIS_ID" redis-cli save
    echo "Redis 内存快照保存已触发"
fi
```

### 2. 优雅停机顺序与影响说明
数据导出后，按顺序停用容器与服务：
1. **停止全部容器**：
   ```bash
   docker stop $(docker ps -q)
   ```
   *影响说明*：向所有容器发送 `SIGTERM` 信号，给应用预留 10 秒优雅关停与落盘时间，随后停止运行。
2. **确认容器已全部离线**：
   ```bash
   docker ps
   # 输出表头且无容器运行时表示正常
   ```
3. **挂起 dockerd 守护进程**：
   ```bash
   /etc/init.d/dockerd stop
   ```
   *影响说明*：释放存储驱动（overlay2）对文件系统的占用，确保后续打包读出的一致性。

### 3. 容器配置、清单与编排文件导出
```bash
# 导出容器清单与详细 inspect 配置快照
docker ps -a --no-trunc > "$BACKUP_DIR/docker_containers_list.txt"
docker inspect $(docker ps -aq) > "$BACKUP_DIR/docker_inspect_all.json"

# 导出 docker-compose 目录（若有）
[ -d /opt/docker ] && cp -rf /opt/docker "$BACKUP_DIR/opt_docker"
[ -d /etc/docker/compose ] && cp -rf /etc/docker/compose "$BACKUP_DIR/etc_docker_compose"
```

### 4. Named Volumes 与数据持久层备份（流式导出）

> [!CAUTION]
> **介质安全红线**：
> 1. 雅典娜内存仅 1GB，**严禁将大体积 Docker 镜像与数据打包到 `/tmp`**，否则必因内存耗尽（OOM）导致死机崩溃！
> 2. **绝不能把唯一备份存放在内部 `/overlay`**！
> 3. 推荐使用方案 A（通过 SSH 管道流式落盘到局域网电脑）或方案 B（写入独立的 USB / 外接硬盘）。

#### 【方案 A：PC 终端执行流式网络导出（最安全，推荐）】
在你的电脑（Windows PowerShell / Linux / macOS 终端）中执行，直接将路由器中的数据打包并实时写入电脑硬盘：
```bash
# 在个人电脑终端执行：
ssh root@192.168.10.1 "tar -czf - /etc/config/dockerd /etc/config/dockerman /etc/docker /opt /mnt/mmcblk0p27/backup_pre_upgrade $(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2}') 2>/dev/null" > ax6600_docker_backup_$(date +%Y%m%d).tar.gz
```

#### 【方案 B：备份至路由器外置 USB / 独立未格分区】
若接有 USB 移动硬盘（挂载于 `/mnt/sda1`）：
```bash
USB_TARGET="/mnt/sda1/docker_backup_$(date +%Y%m%d)"
mkdir -p "$USB_TARGET"

# 打包配置与数据库 dump
tar -czvf "$USB_TARGET/docker_meta_and_dump.tar.gz" /etc/config/dockerd /etc/config/dockerman /etc/docker "$BACKUP_DIR"

# 打包 Named Volumes
DOCKER_VOLUMES_DIR="$DOCKER_DIR/volumes"
if [ -d "$DOCKER_VOLUMES_DIR" ]; then
    tar -czvf "$USB_TARGET/docker_volumes.tar.gz" -C "$DOCKER_DIR" volumes
fi
```

### 5. 备份归档完整性与校验验证
备份生成后，必须立刻校验归档完整性，严防解压时报 CRC 损坏：
```bash
# 验证 tar 包可读性（无报错即表示归档完好）
tar -tzvf "$USB_TARGET/docker_meta_and_dump.tar.gz" >/dev/null && echo "配置归档: 校验通过"
tar -tzvf "$USB_TARGET/docker_volumes.tar.gz" >/dev/null && echo "数据卷归档: 校验通过"

# 生成 SHA256 校验清单
sha256sum "$USB_TARGET"/*.tar.gz > "$USB_TARGET/sha256sums.txt"
cat "$USB_TARGET/sha256sums.txt"
```

---

## 四、保留配置升级与系统恢复标准流程 (SOP)

### 步骤 1：升级前检查与备份归档完毕
确认已完成第二节与第三节全部步骤，确认固件 SHA256 吻合且备份已转移至电脑或外部存储。

### 步骤 2：执行保留配置刷入
```bash
# 检查 /etc/sysupgrade.conf 保留清单，确认无多余的体积膨胀条目
cat /etc/sysupgrade.conf

# 命令行执行保留配置升级（-c 明确保留配置，-v 详细进度）
sysupgrade -c -v /tmp/*-sysupgrade.bin
```
刷写过程路由器前面板 LED 会闪烁，刷写完成后会自动重启，请勿切断电源。

### 步骤 3：首次启动安全接管（防空目录覆盖）
系统重启就绪后，通过 SSH 或 Web 界面重新登录路由器（默认 IP `192.168.10.1`）。

> [!IMPORTANT]
> **关键防护**：在确认外置/独立数据分区挂载就绪前，**严禁启动 Docker**！否则 Docker 会在空的本地挂载点重新生成元数据，导致后续挂载发生路径冲突或覆盖旧数据！
```bash
# 立即确保 Docker 服务处于停止状态
/etc/init.d/dockerd stop 2>/dev/null || true
/etc/init.d/dockerd disable 2>/dev/null || true

# 检查数据分区挂载状态
lsblk
df -h

# 如果独立存储分区（如 /dev/mmcblk0p27 或 /dev/sda1）尚未挂载：
block mount
# 再次核验挂载点是否存在
df -h | grep -E "storage|sda|mmcblk0p27"
```

### 步骤 4：继承配置核验与 NSS 遗留项精准清理
保留配置升级会继承用户的网络、Wi-Fi、DHCP、防火墙与大部分插件配置。
但从 NSS 旧固件迁移时，可能残留指向已失效 NSS 脚本的防火墙条目，必须精准清理，**切勿覆盖整份旧防火墙配置**：
```bash
# 1. 备份当前继承的防火墙配置
cp /etc/config/firewall /etc/config/firewall.bak.$(date +%Y%m%d%H%M)

# 2. 检查是否存在 NSS 专用的 qcanssecm 配置节
uci show firewall.qcanssecm 2>/dev/null

# 3. 若存在，仅删除对应遗留节，绝不破坏用户现有的端口转发、出入站及自定义规则：
if uci get firewall.qcanssecm >/dev/null 2>&1; then
    echo "发现旧版 NSS 遗留防火墙节 firewall.qcanssecm，正在精准清理..."
    uci delete firewall.qcanssecm
    uci commit firewall
    /etc/init.d/firewall reload
    echo "清理完成，防火墙已安全热重载。"
else
    echo "未发现 firewall.qcanssecm 遗留节，跳过。"
fi
```

### 步骤 5：软硬件加速与网络连通性核验
1. **网络连通性确认**：
   - 验证 WAN 口 IP 获取：`ifstatus wan`
   - 验证局域网终端上网与 DNS 解析：`ping -c 3 223.5.5.5`，`nslookup openwrt.org`
2. **PPE 与 Flowtable 硬件加速确认**：
   - 进入 Web 管理后台「网络」→「防火墙」，确认「软件流程分流」与「硬件流程卸载 (PPE Flowtable)」均已勾选。
   - 终端核验内核模块加载与流表状态：
     ```bash
     lsmod | grep -E "nft_offload|flow_offload"
     # 观察 PPE 硬件流表计数（内网大流量传输或下载时数值递增）
     cat /sys/kernel/debug/3a000000.ppe/active_flows 2>/dev/null || echo "PPE 驱动处于就绪状态"
     ```

### 步骤 6：Docker 数据挂载恢复与服务唤醒
1. 确认存储分区已稳定挂载在预期路径（例如 `/mnt/mmcblk0p27`）。
2. 核对 `/etc/config/dockerd` 中的 `data_root`（DockerRootDir）是否正确指向该挂载点。
3. 若先前数据完整保存在该独立分区，无需重新解压；若在内部 overlay 被格式化，需从备份归档中还原 volumes 与配置：
   ```bash
   # 若需要还原 volumes：
   tar -xzf /mnt/sda1/docker_backup_*/docker_volumes.tar.gz -C "$DOCKER_DIR"
   ```
4. 恢复 Docker 自启动并拉起守护进程：
   ```bash
   /etc/init.d/dockerd enable
   /etc/init.d/dockerd start
   ```
5. 启动容器并导入数据库逻辑数据（若有）：
   ```bash
   docker start $(docker ps -aq)
   docker ps
   # 若之前导出了 SQL，进入对应容器执行恢复：
   # docker exec -i <mysql_container> mysql -uroot -p<密码> < /path/to/mysql_all_dump.sql
   ```

---

## 五、升级后核心功能验收与排错方法

### 1. Docker 防火墙后端与网络链路验证

> [!WARNING]
> **排错提示**：OpenWrt 上的 Docker 会在 Linux 内核中使用 iptables/nftables 规则。不同构建中 Docker 可能通过 `iptables-nft` 兼容层运行，**绝对不能硬编码 `nft list chain inet fw4 DOCKER` 作为唯一判断依据**！

#### ① 识别防火墙后端与链检查
```bash
# 检查当前防火墙后端类型
if command -v iptables >/dev/null; then
    echo "=== 检查 iptables NAT 表中的 DOCKER 链 ==="
    iptables -t nat -L DOCKER -n -v 2>/dev/null || iptables -t nat -S DOCKER 2>/dev/null

    echo "=== 检查 iptables FILTER 表中的 DOCKER 链 ==="
    iptables -t filter -L DOCKER -n -v 2>/dev/null || iptables -t filter -S DOCKER 2>/dev/null
fi

if command -v nft >/dev/null; then
    echo "=== 检查 nftables 相关链 ==="
    nft list table ip nat 2>/dev/null | grep -A 8 "chain DOCKER" || true
    nft list table ip filter 2>/dev/null | grep -A 8 "chain DOCKER" || true
fi
```

#### ② 容器 4 步网络端到端验收
```bash
# 1. 运行临时轻量测试容器并映射端口 8088
docker run -d --name test-net-probe -p 8088:80 nginx:alpine 2>/dev/null || \
docker run -d --name test-net-probe -p 8088:80 httpd:alpine 2>/dev/null || \
docker run -d --name test-net-probe -p 8088:80 busybox httpd -f -p 80

# 2. 验证容器出网能力 (Egress)
docker exec test-net-probe ping -c 2 223.5.5.5 || docker exec test-net-probe wget -q -O - http://www.baidu.com | head -n 3
echo "容器出网能力: 正常"

# 3. 验证 LAN 侧端口映射与 NAT 回流 (Ingress / Loopback)
curl -I http://192.168.10.1:8088 --connect-timeout 3
echo "LAN 访问映射端口: 正常"

# 4. 验证 WAN 边界拦截策略 (WAN Ingress Block)
# 确认 filter 表 DOCKER-USER / FORWARD 链正常阻断未经授权的外网直接访问
iptables -t filter -L FORWARD -n -v 2>/dev/null | head -15

# 清理测试容器
docker rm -f test-net-probe
```

---

### 2. PassWall2 节点平滑迁移与真实代理核验

#### ① 检查继承的旧节点配置
```bash
# 检查旧节点数据结构与加密类型
uci show passwall2 | grep -E "\.type=|\.protocol=|\.address=|\.port="
```

#### ② 最小平滑迁移策略
如果升级后发现旧节点无法读取或代理无法连通（由于核心组件版本升级与语法更新）：
- **保留关键字段**：记录旧节点的服务器域名/IP（`address`）、服务端口（`port`）、用户凭据（`uuid` / `password`）、传输协议（`transport`：如 ws/grpc/tcp）、TLS 参数（`tls` / `sni` / `alpn` / `fingerprint`）。
- **新建同类节点**：在 Web 界面选择对应核心（推荐 `sing-box` 或 `Xray`），以相同参数新建节点，避免因旧节点底层废弃字段导致守护进程启动报错。

#### ③ 核心配置文件语法核验
```bash
# 查找 PassWall2 实际生成的客户端配置文件
LATEST_CFG=$(ls -t /var/etc/passwall2/*.json 2>/dev/null | head -1)

if [ -n "$LATEST_CFG" ]; then
    echo "当前代理核心配置文件路径: $LATEST_CFG"
    # 使用 jq 检查 JSON 语法是否完全合法
    if command -v jq >/dev/null; then
        jq empty "$LATEST_CFG" && echo "代理配置文件 JSON 语法: 校验通过"
    fi
fi

# 检查核心运行进程
ps | grep -E "xray|sing-box" | grep -v grep
```

#### ④ 真实代理网络与 TLS 握手鉴权验证

> [!CAUTION]
> **真实性警告**：单纯的 TCP Ping 或 HTTP 延时测试**绝不能证明** TLS 握手、用户认证与节点流量解密成功（Ping 仅能证明网络路由可达，握手失败时依然可以产生延时数值）。

必须通过实际发起到被阻断站点的 HTTPS 请求来验证真实数据转发与出口 IP：
```bash
# 1. 指定本地 SOCKS5 代理端口进行带 TLS 握手的 HTTPS 深度请求（假设本地端口 1082）
curl -x socks5h://127.0.0.1:1082 -I https://www.google.com --connect-timeout 6 -v

# 2. 查询当前代理节点的公网出口 IP（必须与服务器节点 IP 一致）
curl -x socks5h://127.0.0.1:1082 -s https://api.ipify.org && echo ""

# 3. 验证国内直连分流是否穿透正常（直连百度）
curl -I https://www.baidu.com --connect-timeout 5

# 4. 检查 PassWall2 核心日志，确认无 TLS Handshake Failed 或 Invalid User 报错
logread -e passwall2 | tail -25
```
若上述测试均通过且核心日志无握手报错，则证明 PassWall2 节点平滑继承与出海分流验收通过！
