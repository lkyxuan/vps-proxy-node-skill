#!/bin/bash
# ============================================================
#  VPS 节点初始化脚本 (idempotent) — Ubuntu/Debian
#  在服务器上以 root 运行,可重复执行,每段都做状态检查。
#
#  可选环境变量:
#    TIMEZONE=Asia/Shanghai           时区
#    SWAP_SIZE_GB=0                   >0 则创建 swapfile 到该大小;0=保留现有
#    SSH_PUBKEY="ssh-ed25519 AAAA..." 提供则写入 root 的 authorized_keys 并开启 pubkey 认证
#    DISABLE_PASSWORD_AUTH=no         yes=关闭密码登录(仅当 authorized_keys 非空才执行)
#    ENABLE_BBR=yes
#
#  例:
#    SSH_PUBKEY="ssh-ed25519 AAAA..." DISABLE_PASSWORD_AUTH=yes bash setup.sh
# ============================================================
set -uo pipefail

TIMEZONE="${TIMEZONE:-Asia/Shanghai}"
SWAP_SIZE_GB="${SWAP_SIZE_GB:-0}"
SSH_PUBKEY="${SSH_PUBKEY:-}"
DISABLE_PASSWORD_AUTH="${DISABLE_PASSWORD_AUTH:-no}"
ENABLE_BBR="${ENABLE_BBR:-yes}"
export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a

log(){ echo -e "\n\033[1;36m### $*\033[0m"; }
[ "$(id -u)" = "0" ] || { echo "必须 root 运行"; exit 1; }

# ---------- 一、系统基本设置 ----------
log "1/7 更新软件库 + 升级 + 装必备软件"
apt-get update -y
apt-get upgrade -y
apt-get install -y curl wget vim git htop unzip zip net-tools dnsutils \
  ca-certificates gnupg lsb-release software-properties-common \
  apt-transport-https jq ncdu tree mtr-tiny

log "校时:时区=$TIMEZONE + 启用 NTP"
timedatectl set-timezone "$TIMEZONE"
timedatectl set-ntp true

# ---------- 二、TCP 参数调优 ----------
if [ "$ENABLE_BBR" = "yes" ]; then
  log "2/7 TCP 调优 (BBR + fq + sysctl)"
  modprobe tcp_bbr 2>/dev/null || true
  echo tcp_bbr > /etc/modules-load.d/bbr.conf
  cat > /etc/sysctl.d/99-node-tuning.conf <<'EOF'
# ===== 节点网络调优 =====
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.somaxconn = 32768
net.core.netdev_max_backlog = 32768
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_max_tw_buckets = 65536
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_notsent_lowat = 16384
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_keepalive_intvl = 30
net.ipv4.tcp_keepalive_probes = 5
fs.file-max = 1048576
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
vm.swappiness = 10
vm.vfs_cache_pressure = 50
EOF
  sysctl --system >/dev/null
  echo "拥塞算法: $(sysctl -n net.ipv4.tcp_congestion_control) / qdisc: $(sysctl -n net.core.default_qdisc)"
fi

# ---------- 三、SWAP ----------
log "3/7 SWAP"
if [ "${SWAP_SIZE_GB}" -gt 0 ] 2>/dev/null; then
  if ! swapon --show | grep -q '/swap.img'; then
    fallocate -l "${SWAP_SIZE_GB}G" /swap.img || dd if=/dev/zero of=/swap.img bs=1M count=$((SWAP_SIZE_GB*1024))
    chmod 600 /swap.img; mkswap /swap.img; swapon /swap.img
    grep -q '/swap.img' /etc/fstab || echo '/swap.img none swap sw 0 0' >> /etc/fstab
    echo "已创建 ${SWAP_SIZE_GB}G swap"
  else
    echo "swap 已存在,跳过(如需扩容先手动 swapoff -a && rm /swap.img)"
  fi
else
  echo "SWAP_SIZE_GB=0,保留现有:"; swapon --show || echo "(无 swap)"
fi

# ---------- 四、Docker + compose ----------
log "4/7 Docker + docker-compose"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  OS_ID=$(. /etc/os-release && echo "$ID")   # ubuntu / debian
  curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  ARCH=$(dpkg --print-architecture); CODENAME=$(. /etc/os-release && echo "$VERSION_CODENAME")
  echo "deb [arch=$ARCH signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/$OS_ID $CODENAME stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'JSON'
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "20m", "max-file": "3" },
  "storage-driver": "overlay2",
  "live-restore": true,
  "default-address-pools": [ { "base": "172.30.0.0/16", "size": 24 } ]
}
JSON
systemctl enable docker >/dev/null 2>&1
systemctl restart docker
docker --version; docker compose version

# ---------- 五、fail2ban ----------
log "5/7 fail2ban (防 SSH 爆破)"
command -v fail2ban-client >/dev/null || apt-get install -y fail2ban
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 1h
findtime = 10m
maxretry = 5
backend  = systemd
ignoreip = 127.0.0.1/8 ::1

[sshd]
enabled = true
port    = 22
maxretry = 5
EOF
systemctl enable fail2ban >/dev/null 2>&1
systemctl restart fail2ban

# ---------- 六、SSH 密钥登录 ----------
log "6/7 SSH 密钥登录"
if [ -n "$SSH_PUBKEY" ]; then
  mkdir -p /root/.ssh; chmod 700 /root/.ssh
  touch /root/.ssh/authorized_keys; chmod 600 /root/.ssh/authorized_keys
  grep -qxF "$SSH_PUBKEY" /root/.ssh/authorized_keys || echo "$SSH_PUBKEY" >> /root/.ssh/authorized_keys
  sed -i 's/^#\?PubkeyAuthentication.*/PubkeyAuthentication yes/' /etc/ssh/sshd_config
  grep -q '^PubkeyAuthentication yes' /etc/ssh/sshd_config || echo 'PubkeyAuthentication yes' >> /etc/ssh/sshd_config
  echo "公钥已写入。务必先用密钥登录验证成功,再设 DISABLE_PASSWORD_AUTH=yes 重跑本段。"
  if [ "$DISABLE_PASSWORD_AUTH" = "yes" ] && [ -s /root/.ssh/authorized_keys ]; then
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
    grep -q '^PasswordAuthentication no' /etc/ssh/sshd_config || echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
    # 清理 Ubuntu cloud-init 常写的 drop-in 覆盖(否则改主配置无效!)
    if ls /etc/ssh/sshd_config.d/*.conf >/dev/null 2>&1; then
      sed -ri 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config.d/*.conf
    fi
    echo "已关闭密码登录。"
  fi
  sshd -t && { systemctl restart ssh 2>/dev/null || systemctl restart sshd; }
  echo "生效值:"; sshd -T | grep -E '^(passwordauthentication|pubkeyauthentication)'
else
  echo "未提供 SSH_PUBKEY,跳过。设置该变量后重跑本段。"
fi

log "7/7 全部完成 ✓"
