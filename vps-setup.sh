#!/bin/bash

# ====================================================
# 全能系统初始化与优化脚本 （自定义版）
# 功能：VPS一键初始化
# ====================================================

# --- 定义颜色变量 ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- 初始化状态数组 ---
SUCCESS_TASKS=()
FAILED_TASKS=()

# --- 辅助函数：记录结果 ---
# 参数 1: 任务描述
# 参数 2: 状态码 (0 成功, 其他 失败)
log_result() {
    if [ $2 -eq 0 ]; then
        echo -e "${GREEN}✔ [成功] $1${NC}"
        SUCCESS_TASKS+=("$1")
    else
        echo -e "${RED}✖ [失败] $1 - 请检查上方错误日志${NC}"
        FAILED_TASKS+=("$1")
    fi
    echo "----------------------------------------------------"
}

# 检查是否为 root 用户
if [ "$EUID" -ne 0 ]; then
  echo -e "${RED}错误：请使用 root 权限运行此脚本！(sudo -i)${NC}"
  exit 1
fi

clear
echo -e "${CYAN}=== 开始执行系统初始化与优化  ===${NC}"
echo "----------------------------------------------------"

# ================= 1. 优化系统更新源并更新系统 =================
echo -e "${YELLOW}1. 正在更新系统软件包列表并升级...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y && apt-get full-upgrade -y
log_result "系统更新与升级" $?

# ================= 2. 清理系统垃圾文件 =================
echo -e "${YELLOW}2. 正在清理系统垃圾文件...${NC}"
apt-get autoremove -y && apt-get clean && rm -rf /var/lib/apt/lists/*
log_result "清理系统垃圾" $?

# ================= 11. 安装基础工具 (提前安装以供后续使用) =================
# 将第11项调整顺序，确保工具可用
echo -e "${YELLOW}3. 安装基础工具 (wget git sudo tar unzip socat btop nano vim)...${NC}"
# 尝试更新一下索引以防刚才清理过头
apt-get update -y > /dev/null 2>&1
apt-get install -y wget git sudo tar unzip socat btop nano vim dnsutils curl iptables-persistent
log_result "安装基础常用工具" $?

# ================= 3. 设置虚拟内存 1G =================
echo -e "${YELLOW}4. 检查并设置 Swap (虚拟内存)...${NC}"
SWAP_RESULT=0
if grep -q "swap" /proc/swaps; then
    echo -e "${GREEN}Swap 已存在，跳过创建。${NC}"
    SUCCESS_TASKS+=("设置虚拟内存 (已存在)")
else
    fallocate -l 1G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=1024
    if [ $? -eq 0 ]; then
        chmod 600 /swapfile
        mkswap /swapfile
        swapon /swapfile
        echo '/swapfile none swap sw 0 0' >> /etc/fstab
        log_result "设置虚拟内存 (1G)" 0
    else
        log_result "设置虚拟内存" 1
    fi
fi

# ================= 4. 启动 fail2ban =================
echo -e "${YELLOW}5. 配置 Fail2ban 防御 SSH 暴力破解...${NC}"
apt-get install -y fail2ban
if [ $? -eq 0 ]; then
    cp /etc/fail2ban/jail.conf /etc/fail2ban/jail.local
    # 确保 sshd 启用
    if ! grep -q "^\[sshd\]" /etc/fail2ban/jail.local; then
        echo -e "\n[sshd]\nenabled = true" >> /etc/fail2ban/jail.local
    else
        # 简单替换启用
        sed -i '/^\[sshd\]$/a enabled = true' /etc/fail2ban/jail.local
    fi
    systemctl enable fail2ban
    systemctl restart fail2ban
    log_result "Fail2ban 安装与启动" $?
else
    log_result "Fail2ban 安装" 1
fi

# ================= 5. 配置 Iptables 开放所有端口 =================
echo -e "${YELLOW}6. 配置 Iptables (开放所有端口)...${NC}"
# 清空规则
iptables -F
iptables -X
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT
netfilter-persistent save
log_result "Iptables 开放全端口" $?

# ================= 7. 开启 BBR 加速 =================
echo -e "${YELLOW}7. 检测并尝试开启 BBR 加速...${NC}"

BBR_SKIPPED_REASON=""
BBR_ENABLED=0

# 0) 检测虚拟化类型（KVM 通常可控内核；LXC/OpenVZ 常见不可控内核）
VIRT_TYPE="$(systemd-detect-virt 2>/dev/null || echo unknown)"

case "$VIRT_TYPE" in
  lxc|openvz|container)
    BBR_SKIPPED_REASON="当前虚拟化环境为 $VIRT_TYPE（通常为容器共享宿主内核），可能无法启用 BBR"
    ;;
  *)
    ;;
esac

# 1) 如未提前判定为容器限制，则尝试加载 tcp_bbr 模块（若内建则无需模块）
if [ -z "$BBR_SKIPPED_REASON" ]; then
    if modprobe tcp_bbr 2>/dev/null; then
        :
    else
        # modprobe 失败不一定代表不能用（可能内建 y），继续用 available 列表判定
        :
    fi

    # 2) 判断内核是否提供 bbr（关键判定）
    AVAILABLE_CC="$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null || true)"
    if echo "$AVAILABLE_CC" | grep -qw bbr; then
        # 3) 写入持久化配置（使用 sysctl.d，避免重复追加 /etc/sysctl.conf）
        cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

        # 4) 持久化模块加载（若内建也无害）
        cat >/etc/modules-load.d/bbr.conf <<'EOF'
tcp_bbr
EOF

        # 5) 应用（用 --system 更贴近开机加载顺序）
        sysctl --system >/dev/null 2>&1

        # 6) 立即再强制写一次，避免被其它文件覆盖（以当前执行时为准）
        sysctl -w net.core.default_qdisc=fq >/dev/null 2>&1
        sysctl -w net.ipv4.tcp_congestion_control=bbr >/dev/null 2>&1

        # 7) 验证
        CUR_CC="$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || true)"
        CUR_QDISC="$(sysctl -n net.core.default_qdisc 2>/dev/null || true)"

        if [ "$CUR_CC" = "bbr" ]; then
            echo -e "${GREEN}已启用 BBR：tcp_congestion_control=${CUR_CC}；default_qdisc=${CUR_QDISC}${NC}"
            BBR_ENABLED=1
        else
            BBR_SKIPPED_REASON="检测到 bbr 可用（available: ${AVAILABLE_CC}），但设置后仍未生效（当前: ${CUR_CC}）。可能被其他 sysctl 配置覆盖或内核策略限制。"
        fi
    else
        BBR_SKIPPED_REASON="当前内核未提供 bbr（available: ${AVAILABLE_CC}）。无法启用 BBR"
    fi
fi

# 8) 记录结果：成功/跳过但继续
if [ "$BBR_ENABLED" -eq 1 ]; then
    log_result "开启 BBR 加速" 0
else
    echo -e "${YELLOW}跳过启用 BBR：${BBR_SKIPPED_REASON}${NC}"
    SUCCESS_TASKS+=("开启 BBR 加速 (已跳过：${BBR_SKIPPED_REASON})")
    echo "----------------------------------------------------"
fi

# ================= 8. 设置时区 =================
echo -e "${YELLOW}8. 设置时区为 Asia/Shanghai...${NC}"
timedatectl set-timezone Asia/Shanghai
log_result "设置时区 (上海)" $?

# ================= 9. 优化 DNS =================
echo -e "${YELLOW}9. 配置 DNS (1.1.1.1, 8.8.8.8, 223.5.5.5)...${NC}"
# 先解锁，防止之前被锁过
chattr -i /etc/resolv.conf 2>/dev/null
cp /etc/resolv.conf /etc/resolv.conf.bak
cat > /etc/resolv.conf <<EOF
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 223.5.5.5
EOF
# 锁定文件
chattr +i /etc/resolv.conf
log_result "优化 DNS 地址" $?

# ================= 10. IPv4 优先 =================
echo -e "${YELLOW}10. 设置网络 IPv4 优先...${NC}"
sed -i 's/#precedence ::ffff:0:0\/96  100/precedence ::ffff:0:0\/96  100/' /etc/gai.conf
log_result "设置 IPv4 优先" $?


# ====================================================
# 最终汇总报告
# ====================================================
echo ""
echo -e "${CYAN}==============================================${NC}"
echo -e "${CYAN}             脚本执行结果汇总             ${NC}"
echo -e "${CYAN}==============================================${NC}"

if [ ${#SUCCESS_TASKS[@]} -gt 0 ]; then
    echo -e "${GREEN}✅ 执行成功的项目：${NC}"
    for task in "${SUCCESS_TASKS[@]}"; do
        echo -e "   - $task"
    done
fi

echo ""

if [ ${#FAILED_TASKS[@]} -gt 0 ]; then
    echo -e "${RED}❌ 执行失败的项目（请检查日志）：${NC}"
    for task in "${FAILED_TASKS[@]}"; do
        echo -e "   - $task"
    done
else
    echo -e "${GREEN}🎉 完美！没有发现执行失败的项目。${NC}"
fi

echo -e "${CYAN}==============================================${NC}"
echo -e "${YELLOW}建议：请重启服务器以确保所有内核及网络更改完全生效，请访问探针 https://nbtz.newbie.ma 安装agent ${NC}"
echo ""
