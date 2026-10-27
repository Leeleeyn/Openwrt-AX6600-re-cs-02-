#!/usr/bin/env bash
# Regression Test: Verify upgrade checks, Docker backup consistency, and NSS cleanup logic
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
GUIDE_FILE="$REPO_ROOT/Docs/AX6600保留配置升级与Docker备份恢复指南.md"
README_FILE="$REPO_ROOT/README.md"

echo "=== Running Upgrade & Backup Consistency Verification ==="

# Test 1: Guide existence and key sections verification
echo "--- Test 1: Verify Guide File and Essential Content ---"
if [ ! -f "$GUIDE_FILE" ]; then
    echo "FAIL: Guide file $GUIDE_FILE does not exist!" >&2
    exit 1
fi

REQUIRED_SECTIONS=(
    "误区一：“sysupgrade 保留配置绝不会影响 overlay 中的 Docker 数据”"
    "误区二：“雅典娜自带 64G/128G eMMC，随便刷入 160MB 的 PLUS 升级包”"
    "误区三：“原先只打包 /etc/docker 和 /etc/config/dockerman 就足够保护 Docker”"
    "rootfs|rootfs_1"
    "DockerRootDir"
    "firewall.qcanssecm"
    "test-net-probe"
    "socks5h://127.0.0.1"
)

for SEC in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -q "$SEC" "$GUIDE_FILE"; then
        echo "FAIL: Required section/keyword '$SEC' not found in $GUIDE_FILE!" >&2
        exit 1
    fi
done
echo "PASS: All essential sections and keywords verified in Guide."

# Test 2: Verify README references and warnings
echo "--- Test 2: Verify README References and Upgrade Guidance ---"
if ! grep -q "Docs/AX6600保留配置升级与Docker备份恢复指南.md" "$README_FILE"; then
    echo "FAIL: README.md does not reference the upgrade guide!" >&2
    exit 1
fi

if ! grep -q "目标分区红线" "$README_FILE"; then
    echo "FAIL: README.md missing target partition warning!" >&2
    exit 1
fi
echo "PASS: README.md correctly references guide and target partition warning."

# Test 3: Simulation of NSS firewall cleanup snippet
echo "--- Test 3: Simulation of NSS Firewall Cleanup Logic ---"
TMP_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t 'uci_test')"
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_CONFIG="$TMP_DIR/firewall"
cat << 'EOF' > "$MOCK_CONFIG"
config defaults
	option syn_flood '1'
	option input 'ACCEPT'
	option output 'ACCEPT'
	option forward 'REJECT'

config include 'qcanssecm'
	option path '/etc/firewall.d/qca-nss-ecm'
	option reload '1'

config rule 'user_ssh'
	option name 'Allow-SSH'
	option src 'wan'
	option proto 'tcp'
	option dest_port '22'
	option target 'ACCEPT'

config redirect 'user_port_forward'
	option name 'Web-Forward'
	option src 'wan'
	option proto 'tcp'
	option src_dport '8080'
	option dest_ip '192.168.10.100'
	option dest_port '80'
	option target 'DNAT'
EOF

# Mock uci tool using the mock config
cat << 'EOF' > "$TMP_DIR/uci"
#!/usr/bin/env bash
CONFIG_FILE="$UCI_CONFIG_FILE"
CMD="$1"
TARGET="${2:-}"

case "$CMD" in
    get)
        if [[ "$TARGET" == "firewall.qcanssecm" ]]; then
            if grep -q "config include 'qcanssecm'" "$CONFIG_FILE"; then
                exit 0
            fi
            exit 1
        fi
        exit 1
        ;;
    delete)
        if [[ "$TARGET" == "firewall.qcanssecm" ]]; then
            awk '
            BEGIN { skip=0 }
            /^config include '\''qcanssecm'\''/ { skip=1; next }
            /^config / && skip { skip=0 }
            !skip { print }
            ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            exit 0
        fi
        exit 1
        ;;
    commit)
        exit 0
        ;;
    show)
        cat "$CONFIG_FILE"
        exit 0
        ;;
    *)
        exit 1
        ;;
esac
EOF
chmod +x "$TMP_DIR/uci"

# Execute the cleanup logic from the guide
export UCI_CONFIG_FILE="$MOCK_CONFIG"
PATH="$TMP_DIR:$PATH"

if uci get firewall.qcanssecm >/dev/null 2>&1; then
    echo "Found firewall.qcanssecm, deleting..."
    uci delete firewall.qcanssecm
    uci commit firewall
fi

# Verify firewall.qcanssecm was deleted
if grep -q "config include 'qcanssecm'" "$MOCK_CONFIG"; then
    echo "FAIL: firewall.qcanssecm was not deleted!" >&2
    exit 1
fi

# Verify user custom rules were completely preserved
if ! grep -q "config rule 'user_ssh'" "$MOCK_CONFIG"; then
    echo "FAIL: User custom rule 'user_ssh' was erroneously deleted!" >&2
    exit 1
fi

if ! grep -q "config redirect 'user_port_forward'" "$MOCK_CONFIG"; then
    echo "FAIL: User custom redirect 'user_port_forward' was erroneously deleted!" >&2
    exit 1
fi

echo "PASS: NSS cleanup successfully removed only the legacy section and preserved user rules."

# Test 4: Simulation of DockerRootDir Mount Detection Logic
echo "--- Test 4: Docker Root Dir Mount Detection Classification ---"
classify_docker_mount() {
    local DOCKER_MNT="$1"
    if [ "$DOCKER_MNT" = "/overlay" ]; then
        echo "DANGER_OVERLAY"
    elif [[ "$DOCKER_MNT" == /mnt/* ]] || [ "$DOCKER_MNT" = "/opt" ]; then
        echo "SAFE_SEPARATE"
    else
        echo "OTHER"
    fi
}

RES1=$(classify_docker_mount "/overlay")
RES2=$(classify_docker_mount "/mnt/mmcblk0p27")
RES3=$(classify_docker_mount "/mnt/sda1")
RES4=$(classify_docker_mount "/opt")

if [ "$RES1" != "DANGER_OVERLAY" ]; then
    echo "FAIL: Expected /overlay to be classified as DANGER_OVERLAY, got $RES1" >&2
    exit 1
fi
if [ "$RES2" != "SAFE_SEPARATE" ] || [ "$RES3" != "SAFE_SEPARATE" ] || [ "$RES4" != "SAFE_SEPARATE" ]; then
    echo "FAIL: Separate mounts were misclassified!" >&2
    exit 1
fi
echo "PASS: DockerRootDir mount classification logic is sound."

echo "=== All Upgrade & Backup Consistency Tests Passed Successfully! ==="
