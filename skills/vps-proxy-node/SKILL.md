---
name: vps-proxy-node
description: 把一台新买的 Linux VPS 变成自用科学上网节点(梯子)——系统初始化(更新/BBR/SWAP/Docker/SSH 仅密钥/fail2ban)、节点体检(IP 质量/流媒体与 AI 解锁/性能/对华线路出报告)、部署 sing-box 双协议(VLESS-Reality + Hysteria2),并把节点接进用户的客户端。用户说"把这台服务器做成梯子"、"配置服务器/节点"、"初始化 VPS"、"测一下这个节点/出个体检报告"、"在这台机器上搭代理"、或直接给一个服务器 IP + root 密码时使用。
---

# VPS → 自用梯子

把一台新买的 Linux VPS 配成可用的代理节点。目标发行版:**Ubuntu / Debian(apt)**。

完整流程分三段,**按需做,不要一上来就全做**:
① 系统初始化(必做)② 节点体检(想知道这台机器值不值得用时做)③ 部署代理 + 接入客户端(要拿来翻墙时做)。

## 零、开工前先问清楚(一次问完,别边做边问)

1. **服务器 IP**、**SSH 端口**(默认 22)、**root 密码**(或已有私钥路径)。
2. **要做哪几段**:只初始化 / 初始化+体检 / 全套搭梯子。用户说"做成梯子"= 全套。
3. **用户在什么设备上用**:Mac/Windows 的 Clash Verge(Mihomo)、v2rayN、**Surge**、iPhone 的 Shadowrocket / Stash、路由器 **OpenClash**、安卓的 NekoBox / Hiddify……这决定第三段最后交付什么格式(可以多选,`scripts/gen-clients.sh` 一次出 Surge / 小火箭 / OpenClash 三份)。
   - **用 Surge 的要额外加 AnyTLS**:Surge 不支持 VLESS-Reality,只剩 Hy2(UDP)容易被运营商 QoS,得给它一个 TCP 主力。
4. **本机有没有 SSH 公钥**(`~/.ssh/id_ed25519.pub` 或 `~/.ssh/id_rsa.pub`)。没有就先 `ssh-keygen -t ed25519` 生成一把。
5. **服务商控制台能不能登**——连不上时需要用户去面板放行端口,提前说一声。
6. **系统装了没有**:有的服务商开通后**硬盘是空的**,要用户自己在面板「重建操作系统」里选模板。首推 **Debian 12**(省资源、无 cloud-init 改 SSH 的坑),其次 Ubuntu 22.04/24.04;CentOS 7/8、Debian 10、Ubuntu 18/20 都别选。
7. **要不要保留密码登录**:默认关掉,但用户明确要留就留(fail2ban 兜底),别反复劝。
8. **这台机器以后还跑别的吗**:要跑大流量服务的,先提醒看套餐**月流量额度**(CN2 GIA mini 往往只有几百 GB),以及对外服务越多攻击面越大。

> 密码只在本次会话里用于首次登录,配好密钥后就关掉密码登录;不要把密码写进任何文件或日志。

---

## 一、系统初始化(标准清单)

1. **系统基本设置**:更新软件库 → 升级 + 装必备软件 → 校时(时区 + NTP)
2. **TCP 参数调优**:BBR + fq + sysctl(见脚本)
3. **添加 SWAP**:低内存机器加 swap + swappiness=10
4. **Docker + docker compose**:官方源安装 + daemon.json(日志轮转,防小盘被撑爆)
5. **fail2ban**:防 SSH 爆破
6. **SSH 密钥登录**:加公钥 → 验证能登 → 关密码登录

有一键脚本 `scripts/setup.sh`(幂等,可重复跑)。但**首次配置建议分步跑并核对**,尤其 SSH 那步。

### 首次密码登录

**推荐:让用户自己装公钥**,agent 全程只用密钥,不经手密码。在用户终端里跑(用户粘贴一次密码):
```bash
ssh-copy-id -i ~/.ssh/id_ed25519.pub -o StrictHostKeyChecking=accept-new root@IP
```
然后 agent 后台等待密钥可登:
```bash
until ssh -o BatchMode=yes -o ConnectTimeout=6 -o IdentitiesOnly=yes -i ~/.ssh/id_ed25519 root@IP true 2>/dev/null; do sleep 5; done; echo KEY_OK
```
顺手在 `~/.ssh/config` 加别名(见下文),后面所有命令都用 `ssh 别名`,也避开 zsh 不分词的坑。

如果 agent 必须自己用密码登录,才用 `sshpass`
(macOS:`brew install sshpass`;Linux:`apt install sshpass`):
```bash
export SSHPASS='密码'
sshpass -e ssh -o StrictHostKeyChecking=no -o PubkeyAuthentication=no -o PreferredAuthentications=password root@IP '命令'
```
- **zsh 不做变量分词**:别把 `sshpass -e ssh ...` 塞进变量再 `$VAR '...'`(会报 command not found),**每次内联完整命令**。
- 上传脚本:`sshpass -e scp -o StrictHostKeyChecking=no scripts/setup.sh root@IP:/root/_setup.sh`

### ⚠️ 连不上服务器?先排查网络边缘

新买的 VPS 常连不上,**别急着怀疑密码**。按证据判断:

- **裸 socket 探测**:连一个**没有服务的随机高位端口**(如 54321):
  ```bash
  python3 -c "import socket;s=socket.create_connection(('IP',54321),5);s.settimeout(3);print(repr(s.recv(100)))"
  ```
  - 该端口也「TCP 握手成功 → 立刻被关闭、不回数据」→ 是**高防 / DDoS 清洗设备**或**面板安全组默认拒绝**在挡你,跟 sshd/密码无关。
  - 修复:让用户去**服务商控制面板**(不是系统内!)找 **安全组 / 访问控制 / 网络与安全 / DDoS 防护 / 防火墙**,放行用户的**出口 IP** 或放行需要的端口(22/tcp、443/tcp、Hy2 用的 udp 端口)。系统内 ufw/iptables 加白名单没用——流量根本到不了系统。
- 本机出口 IP:`curl -s https://api.ipify.org`(注意它可能会变;开着代理时查到的是代理 IP)。
- 面板一般有 **VNC / 救援模式**(带外控制台,不经 SSH 和高防),实在搞不定时让用户走 VNC。

- **先排除本机代理!** 用户电脑开着 Surge 增强模式 / Clash TUN 时,连 VPS 的流量会**先被本机代理接住再从机场节点转出**——表现为任何端口都「握手成功、不回数据、秒断」,和高防一模一样,而且很多机场**封 22 端口**。排查:
  ```bash
  route -n get IP | grep interface   # 是 utunX 就说明走了 TUN
  scutil --proxy | grep -E 'Enable|Port'   # 6152/6153 = Surge,7890 = Clash
  ```
  对照实验:连 `github.com:22` 能拿到 `SSH-2.0-` banner 而 VPS 不行 → 代理放行 22,问题在 VPS 侧;两个都不行 → 先给 VPS IP 加直连规则(Surge:`IP-CIDR,IP/32,DIRECT,no-resolve`)或临时关 TUN。
- **SSH 握手前就断(`kex_exchange_identification: Connection closed`)且代理已排除** → 让用户开面板 **VNC 看一眼**:很可能是 `No bootable device`(**没装系统**),或者还在装。

判断口诀:**没服务的端口也秒断 = 边缘设备/安全组;只有 22 被拒 = sshd 或防火墙规则;超时 = 被 DROP(防火墙丢包)。**

> 判断端口通不通用 `nc -vz IP 端口` 探端口,别用 ping:开着 TUN 模式的代理客户端时 ping 恒通,是假象。

### 执行注意事项

- **长命令会断连**:`apt upgrade` / Docker 安装等长操作,连接可能中途被掐(高防掐长连接,或升级重启了网络/sshd)。**对策:写成脚本后台跑,再轮询日志**:
  ```bash
  nohup bash /root/_setup.sh > /root/_setup.log 2>&1 &
  # 之后反复看:
  grep '###' /root/_setup.log; pgrep -f _setup.sh || echo FINISHED
  ```
  断连也不影响任务。
- **偶发 `Permission denied (password)`**:apt/docker 占资源时 sshd 认证会抖动,**重试即可**,不是密码错。
- **noninteractive**:所有 apt 操作前 `export DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a`,避免卡在交互框。

### SSH 密钥登录:必须分步,防锁死

顺序不能乱,**验证成功前绝不关密码**:

1. 写公钥到 `/root/.ssh/authorized_keys`(700/600 权限),设 `PubkeyAuthentication yes`,`sshd -t` 校验后重启 ssh。
2. **另开连接仅用密钥登录验证**:
   `ssh -o PreferredAuthentications=publickey -o IdentitiesOnly=yes -i ~/.ssh/id_xxx root@IP 'echo OK'`
3. **只有第 2 步成功**,才设 `PasswordAuthentication no`。
4. **Ubuntu 大坑**:cloud-init 会在 `/etc/ssh/sshd_config.d/*.conf` 里写 `PasswordAuthentication yes`,**覆盖主配置**。关密码时必须一并改这些 drop-in 文件。用 `sshd -T | grep passwordauthentication` 看**最终生效值**才算数。
5. 双向验证:密钥能登 ✓ + 密码被拒(`Permission denied (publickey)`)✓。
6. 帮用户在本机 `~/.ssh/config` 加一个别名,以后 `ssh 别名` 直接登:
   ```
   Host mynode
     HostName IP
     User root
     IdentityFile ~/.ssh/id_ed25519
   ```

### 一键脚本用法

首次(不关密码,先验证):
```bash
SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" bash setup.sh
```
密钥验证通过后,关密码:
```bash
SSH_PUBKEY="ssh-ed25519 AAAA..." DISABLE_PASSWORD_AUTH=yes bash setup.sh
```
可选:`TIMEZONE=Asia/Tokyo`(默认 Asia/Shanghai)、`SWAP_SIZE_GB=2`(0 = 保留自带 swap)。

### ⚠️ 重启后 SSH 又变回密码登录?

有的服务商 **每次开机 cloud-init 都会重跑 provisioning**:清空 `authorized_keys`、写回 `PubkeyAuthentication no`。表现是"配好的密钥,重启后登不上了"。
- 对策:跑 `scripts/ssh-harden-install.sh`,装一个在 cloud-init 之后执行的自愈服务,每次开机重新加固:
  ```bash
  SSH_PUBKEY="$(cat ~/.ssh/id_ed25519.pub)" bash ssh-harden-install.sh
  ```
- **别直接禁用 cloud-init**——有的机器 IPv6 等网络配置就是靠它每次开机写进去的。
- 初始化做完后**主动重启一次**验证:重启后仍只能密钥登录才算过关。

### 安全收尾(别跳过)

- **改掉 root 密码**(`passwd`),服务商发的初始密码往往走过邮件/工单,视为已泄露。
- **检查 `authorized_keys` 里只有用户自己的 key**,有来历不明的 key 先问用户再删。
- 清理服务器上留的临时脚本/日志(`/root/_*.sh` `/root/_*.log`)。
- 别在节点上放任何其他服务的密钥/凭据;别对公网开任何 Web 管理面板(必要的话至少换非常用端口 + 强密码 + 只放行自己 IP)。
- 建议用户以后偶尔巡检一下:`systemctl list-units --type=service --state=running`、`docker ps -a`、`ss -tlnp`,看有没有不认识的服务、容器、外连。机器上出现陌生的 systemd 服务或"挂机赚钱"类容器,大概率是被入侵了——**处置倾向重装,而不是清理**。

---

## 二、节点体检(IP 质量 + 流媒体解锁 + 性能 + 网络质量)

要评估"这台机器适不适合当节点",必须实测出报告,别凭配置参数猜。用两个成熟的开源脚本组合(NodeQuality 不含流媒体解锁,需另配):

1. **NodeQuality**(综合:性能 + IP 质量 + 网络质量 + 回程路由):
   ```bash
   curl -sL https://run.NodeQuality.com -o /root/nq.sh
   # 交互问题固定 4 个,用 printf 喂答案非交互跑: f=性能快速模式, y/y/y = IP/网络/回程 全跑
   nohup bash -c 'printf "f\ny\ny\ny\n" | bash /root/nq.sh -E; echo "### NQ_DONE"' > /root/nq_result.log 2>&1 &
   ```
   小内存机(≤1G)**必须用 `f`(快速模式)**,否则跑 Geekbench 会 OOM 或耗时过长。
2. **流媒体 / AI 解锁**(check.unlock.media):
   ```bash
   nohup bash -c 'printf "\n" | bash <(curl -L -s check.unlock.media); echo "### MEDIA_DONE"' > /root/media_result.log 2>&1 &
   ```
3. **两者都要跑 5–8 分钟**(三网测速 + iperf3 是耗时大头),沿用"后台任务 + 轮询日志"模式,别在前台傻等导致连接超时。
   - **⚠️ 很费流量**:一次完整 NodeQuality 实测约 **4 GB**。小流量套餐(CN2 GIA mini 等)**开跑前先告诉用户**;想省流量就把第 3 个答案(网络质量/测速)改成 `n`:`printf "f\ny\nn\ny\n"`,回程路由和 IP 质量照样有。
   - 读结果:日志里满是进度动画和广告,用 `sed -r "s/\x1b\[[0-9;?]*[a-zA-Z]//g" 日志 | tr "\r" "\n" | grep -vE "⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏"` 清洗后再 grep 关键行;报告链接 grep `nodequality.com/r/`。
   - 国内三网测速点偶尔全部 `ERROR`(测速服务器侧问题),此时以回程路由(CN2 GIA / CMIN2 / 9929 等)和延迟为准,别重跑浪费流量。
4. **收尾清理**:NodeQuality 会在 `/root/.nodequality*/` 下建含 `/dev` bind mount 的沙盒目录,**直接 `rm -rf` 会报 `Device or resource busy`**,要先卸载:
   ```bash
   for m in $(mount | grep -oE "/root/.nodequality[^ ]*"); do umount -l "$m" 2>/dev/null; done
   rm -rf /root/.nodequality* /root/nq.sh /root/nq_result.log /root/media_result.log
   ```
5. **出报告**(用大白话,先说结论"这台机器适合/不适合拿来干什么"):
   - IP 风险评分(Scamalytics / AbuseIPDB / IP2Location / IPQS)、Proxy/VPN/黑名单标记、25 端口出站
   - 流媒体与 AI 解锁清单(Netflix / Disney+ / YouTube / ChatGPT / Claude 等的区域和类型),**IPv4、IPv6 分开看**
   - CPU 型号/核数、对国内三网延迟和测速、到东京/香港/新加坡/洛杉矶延迟
   - NodeQuality 会给一个可分享的报告图链接(30 天有效),一并附上

**几条经验结论**(告诉用户,别让他踩坑):
- **机房 IP 不要拿来做注册类操作**(注册各类 AI / 社交账号)。哪怕 Scamalytics/AbuseIPDB 都是 0 分,IPQS 常给机房段标 Suspicious,注册风控会直接拒。日常访问、看流媒体、用 AI 不受影响;要注册得用住宅 IP。
- **IPv6 往往解锁比 IPv4 差**,体检显示 v6 差就在第三段强制 IPv4 出站。

---

## 三、部署代理节点(sing-box:VLESS-Reality + Hysteria2 [+ AnyTLS])

个人自建的共识是**多协议并行**,不是二选一——某条线路被干扰时,换协议比换机器有效:

| 协议 | 角色 | 端口 | 理由 |
|---|---|---|---|
| VLESS + Reality | 主力 | 443/TCP | 借大站 TLS 握手伪装,抗封锁,无需域名和证书 |
| Hysteria2 | 备用 | 另一个端口/UDP(如 8443) | 基于 QUIC,弱网/晚高峰更快 |
| AnyTLS | Surge 的主力 / 第三备用 | 2053/TCP | **Surge 不支持 VLESS-Reality**;AnyTLS 是 TCP,Surge / 小火箭 / Mihomo 都支持 |

内核选 **sing-box**(开源的 233boy 一键脚本),个人自用最省心,没有 Web 面板 = 少一个攻击面。用户明确要多用户管理/可视化流量统计时,才考虑 3x-ui 这类面板(注意面板别裸奔在公网)。

### 部署步骤

```bash
wget -qO /root/sb_install.sh https://github.com/233boy/sing-box/raw/main/install.sh
bash /root/sb_install.sh   # 自动装 sing-box + 生成默认 VLESS-Reality 节点
# 注意: bash <(curl ...) 进程替换在非交互场景可能失效,务必先 wget 落地再 bash 执行
export TERM=xterm          # sb 命令行工具需要,否则输出/交互异常

sb sni VLESS-REALITY-<port> www.apple.com   # SNI 换成高流量、当地可达、未被墙的大站(如 apple / microsoft)
sb port VLESS-REALITY-<port> 443            # 端口换到 443(最不显眼)

sb add hysteria2 8443   # 加 Hysteria2
# 注意: sb 的端口占用检测不分 tcp/udp,443 被 Reality(tcp)占了就不能再给 Hy2 用 443,换一个端口号

sb add anytls 2053      # 用户用 Surge 时必加(自签证书,和 Hy2 共用 /etc/sing-box/bin/tls.cer)
```
- 233boy 生成的 Reality **short_id 是空字符串**,链接里没有 `sid=`,客户端 short-id 填 `""` 即可。
- 自签证书指纹:`openssl x509 -in /etc/sing-box/bin/tls.cer -noout -fingerprint -sha256`,Surge 可用 `server-cert-fingerprint-sha256=` 钉证书,比 `skip-cert-verify` 安全。
具体配置名用 `sb info` / `sb list` 查。部署完提醒用户:**如果服务商面板有安全组,要放行 443/TCP、2053/TCP 和 Hy2 的 UDP 端口**。

**在服务器上自测三个协议**(本机开着代理时从本机测不准,直接在 VPS 上起一个临时 sing-box 客户端连自己的公网 IP):每个协议一个 socks 入站 → 对应出站,`curl -x socks5h://127.0.0.1:端口 https://www.google.com` 返回 200、`api.ipify.org` 返回 VPS IP 即通过;测完删掉临时配置。

**强制 IPv4 出站**(体检显示 IPv6 解锁差时):sing-box **1.12+ 已弃用** outbound 上的 `domain_strategy` 字段(会报 `FATAL: legacy domain strategy options is deprecated`),新写法是在 `/etc/sing-box/config.json` 里:
```json
{
  "dns": { "servers": [{ "tag": "local", "type": "local" }] },
  "route": { "default_domain_resolver": { "server": "local", "strategy": "ipv4_only" } },
  "outbounds": [{ "tag": "direct", "type": "direct" }]
}
```
改完必须校验通过再重启:
```bash
/etc/sing-box/bin/sing-box check -c /etc/sing-box/config.json -C /etc/sing-box/conf && systemctl restart sing-box
```

**从外部验证 Reality 真的可达 + 伪装生效**(不要只看服务在监听):
```bash
echo | openssl s_client -connect <IP>:443 -servername www.apple.com 2>&1 | grep -iE "subject=|issuer="
# 应返回目标大站的真实证书,说明任何探测者看到的都是"这是 apple.com"
```

**拿分享链接**:`sb url <配置名>`,得到 `vless://...` / `hysteria2://...`。
**机器有 IPv6 的话**:sing-box 默认监听 `*:端口`,v6 入站零改动可用,把链接里的 IP 换成 `[v6地址]` 就多了一组 v6 节点。部分地区/运营商方向会对机房 IPv4 做周期性阻断,而 IPv6 走另一条路由往往不受影响——多一组 v6 节点是很便宜的保险。

### 接入客户端(按第零步问到的设备交付)

**一键生成**:`scripts/gen-clients.sh` 读取 `sb url` 的链接,同时生成 Surge / Shadowrocket / OpenClash 三份:
```bash
scp scripts/gen-clients.sh root@IP:/root/_gen.sh
ssh root@IP 'NAME_PREFIX=FRA bash /root/_gen.sh'          # 输出到 /root/clients/
scp -r root@IP:/root/clients ./ && ssh root@IP 'rm -rf /root/clients /root/_gen.sh'
```
- **Surge**:粘进 `[Proxy]` 和 `[Proxy Group]`(只含 AnyTLS / Hy2)。
- **Shadowrocket(小火箭)**:复制链接,打开小火箭自动识别剪贴板导入。
- **OpenClash**:内核必须选 **Meta(Mihomo)**,把 `proxies` / `proxy-groups` 合并进配置(覆写设置或配置文件编辑)。
- 生成的文件含节点密钥:**本机 `chmod 600`,不要提交到 Git 仓库**。

手工转换的细节如下:

- **v2rayN / NekoBox / Hiddify / Shadowrocket / Stash**:直接导入 `vless://`、`hysteria2://` 链接(复制后在客户端里"从剪贴板导入")。
- **Clash Verge / Mihomo(Clash Meta)系**:**不吃这种 URI 链接**,粘进"订阅"框会报不可用——这和 https 无关,纯粹是两套配置语言(URI vs YAML)。要转成 YAML 的 `proxies:` 条目:
  ```yaml
  proxies:
    - name: my-reality
      type: vless
      server: <IP>
      port: 443
      uuid: <链接里 @ 前面那串>
      network: tcp
      udp: true
      tls: true
      flow: xtls-rprx-vision        # 链接里有 flow= 才写
      servername: www.apple.com     # 链接里的 sni=
      client-fingerprint: chrome    # 链接里的 fp=
      reality-opts:
        public-key: <链接里的 pbk=>
        short-id: <链接里的 sid=>
    - name: my-hy2
      type: hysteria2
      server: <IP>
      port: 8443
      password: <链接里 @ 前面那串>
      sni: <链接里的 sni=>
      skip-cert-verify: true        # 链接里 insecure=1 时
  ```
  - 写进**当前订阅 profile 的扩展配置**(Clash Verge 里该订阅右键 → 编辑节点/扩展配置,用 `prepend:` 加到最前),并把节点加进一个代理组(或新建一个 `select` 组),否则节点出现了也选不到。
  - **改任何配置文件前先备份**(`cp x.yaml x.yaml.bak-日期`),改完用 `python3 -c "import yaml,sys; yaml.safe_load(open(sys.argv[1]))" x.yaml` 校验语法。
  - 这样加的节点只挂在当前这一个订阅下,切到别的订阅就看不到;要跨订阅常驻,得用全局扩展脚本(Script)注入。
- **要不要做成订阅链接**:一两台自建节点没必要——直接维护本地配置最安全(零额外攻击面,不会把节点密钥挂在公网上)。节点多了、要分享给多人时再考虑订阅转换。

### 最终验收(交付前自己验一遍,给用户看证据)

1. 服务端:`systemctl is-active sing-box` = active;`ss -tlnup | grep -E ':443|:8443'` 两个端口都在监听。
2. 外部:上面的 `openssl s_client` 返回伪装站真实证书。
3. 客户端:选中新节点后 `curl -s https://api.ipify.org`(走代理)返回的是 VPS 的 IP;能打开 google.com。
4. 告诉用户:**主力用 Reality(Surge 用 AnyTLS),不通/慢了切 Hy2;有 v6 节点的话轮着试。**
