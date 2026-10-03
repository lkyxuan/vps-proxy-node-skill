#!/bin/bash
# ============================================================
#  开机自愈 SSH 加固 —— 给"每次重启都把 SSH 打回密码登录"的服务商用
#
#  症状:重启后密钥登不上了,或者 sshd -T 显示 passwordauthentication yes。
#  原因:部分服务商的 cloud-init 每次开机都重跑 provisioning,
#        清空 authorized_keys、写回 PubkeyAuthentication no / PasswordAuthentication yes。
#  对策:装一个在 cloud-final.service 之后运行的 oneshot 服务,每次开机重新加固。
#  ⚠️ 不要直接禁用 cloud-init:有些机器的网络(尤其 IPv6)是靠它每次开机写进去的。
#
#  用法(服务器上 root 运行,幂等):
#    SSH_PUBKEY="ssh-ed25519 AAAA..." bash ssh-harden-install.sh
#  前提:这把公钥已经验证过能登录,否则会把自己锁在门外。
# ============================================================
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "必须 root 运行"; exit 1; }
[ -n "${SSH_PUBKEY:-}" ] || { echo "请设置 SSH_PUBKEY"; exit 1; }

install -d -m 700 /etc/ssh-harden
printf '%s\n' "$SSH_PUBKEY" > /etc/ssh-harden/authorized_key
chmod 600 /etc/ssh-harden/authorized_key

cat > /usr/local/sbin/ssh-harden.sh <<'EOF'
#!/bin/bash
# 开机自愈:在 cloud-init 之后重新应用 SSH 加固。幂等。
set -u
KEY="$(cat /etc/ssh-harden/authorized_key)"
mkdir -p /root/.ssh && chmod 700 /root/.ssh
grep -qxF "$KEY" /root/.ssh/authorized_keys 2>/dev/null || echo "$KEY" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
sed -i '/^PubkeyAuthentication/d;/^PasswordAuthentication/d' /etc/ssh/sshd_config
echo 'PubkeyAuthentication yes'  >> /etc/ssh/sshd_config
echo 'PasswordAuthentication no' >> /etc/ssh/sshd_config
for f in /etc/ssh/sshd_config.d/*.conf; do
  [ -f "$f" ] && sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/;s/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$f"
done
sshd -t && { systemctl restart ssh 2>/dev/null || systemctl restart sshd; }
logger -t ssh-harden "SSH 加固已重新应用"
EOF
chmod 700 /usr/local/sbin/ssh-harden.sh

cat > /etc/systemd/system/ssh-harden.service <<'EOF'
[Unit]
Description=Re-apply SSH hardening after provisioning (cloud-init may reset it every boot)
After=cloud-final.service ssh.service
Wants=cloud-final.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/ssh-harden.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now ssh-harden.service
echo "生效值:"; sshd -T | grep -E '^(passwordauthentication|pubkeyauthentication)'
echo "已安装。建议重启一次服务器,确认重启后仍然只能用密钥登录。"
