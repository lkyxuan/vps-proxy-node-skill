# vps-proxy-node-skill

> 一个给 AI agent 用的技能:**把一台新买的 VPS 变成你自己的梯子**。
> 你只要提供服务器 IP 和 root 密码,agent 会自己完成初始化、安全加固、节点体检、部署双协议代理,并把节点接进你的客户端。

已经实际搭过多台节点,流程里的坑(连不上、断连、重启后 SSH 被服务商重置、IPv6 解锁差、Clash 不认链接……)都踩过并写进了技能里。

---

## 🪄 魔法咒语(复制给你的 agent 就行)

适用于能在你电脑上执行命令的 agent:**Claude Code、Codex、Cursor、Windsurf、OpenClaw** 等。把下面整段原样发给它:

```text
帮我学会一个技能,然后用它把我的 VPS 做成梯子。

1. 安装技能:
   git clone --depth 1 https://github.com/bigsongeth/vps-proxy-node-skill.git /tmp/vps-proxy-node-skill
   - 如果你是 Claude Code:把 /tmp/vps-proxy-node-skill/skills/vps-proxy-node 整个目录复制到 ~/.claude/skills/
   - 如果你是 Codex:复制到 ~/.codex/skills/
   - 其他 agent:复制到你的技能/规则目录;没有技能机制,就把其中的 SKILL.md 当作这次任务的操作手册,全文读完再动手
2. 通读 SKILL.md 和 scripts/ 下的两个脚本,用三五句话告诉我你学会了什么、接下来会怎么做。
3. 严格按 SKILL.md 里「零、开工前先问清楚」一次性向我提问,拿到信息后按流程执行。
4. 每一步都给我看真实的命令输出作为证据;遇到要我去服务商控制台操作的地方,明确告诉我点哪里。
```

然后它会问你要服务器 IP、密码、你在什么设备上用,接下来就交给它。

**只想要最短版?**

```text
读一下 https://github.com/bigsongeth/vps-proxy-node-skill ,把里面的技能装上,然后按它的流程帮我把服务器做成梯子。
```

---

## 它会做什么

| 阶段 | 内容 |
|---|---|
| ① 系统初始化 | 更新系统、装常用工具、校时、BBR + TCP 调优、SWAP、Docker、fail2ban、**SSH 改成仅密钥登录**(分步验证,防止把自己锁在外面) |
| ② 节点体检 | 用开源脚本测 IP 纯净度、Netflix/ChatGPT/Claude 等解锁情况、CPU 性能、对国内三网的延迟和速度,出一份大白话报告 |
| ③ 部署代理 | sing-box 多协议:**VLESS-Reality(443/TCP,主力)+ Hysteria2(UDP,备用)+ AnyTLS(TCP,Surge 用)**,验证伪装生效,一键生成 Surge / 小火箭 / OpenClash 配置 |

## 本 fork 新增

- **Surge 支持**:Surge 不支持 VLESS-Reality,新增 AnyTLS(TCP)作为 Surge 主力
- **`scripts/gen-clients.sh`**:一键生成 Surge / Shadowrocket(小火箭)/ OpenClash 三份客户端配置
- **更多踩坑**:新机器硬盘是空的要先重装系统(VNC 显示 `No bootable device`);本机 Surge/Clash TUN 会让任何端口都"握手成功秒断"、很多机场封 22 端口;体检一次约耗 4 GB 流量
- **更安全的首次登录**:用户自己 `ssh-copy-id` 装公钥,agent 全程不经手密码;可按用户意愿保留密码登录

## 你需要准备

- 一台 VPS:**Ubuntu 或 Debian**,有 root 权限(1 核 1G 就够用)
- 服务器 IP + root 密码(配好密钥后会关闭密码登录,并提醒你改密码)
- 一个能在你电脑上跑命令的 AI agent(见上)
- 能登录服务商控制台(万一要放行端口)

## 目录结构

```
skills/vps-proxy-node/
├── SKILL.md                      # 技能本体:完整流程 + 踩坑经验
└── scripts/
    ├── setup.sh                  # 一键初始化(幂等,可重复跑)
    ├── gen-clients.sh            # 一键生成 Surge / 小火箭 / OpenClash 配置
    └── ssh-harden-install.sh     # 给"重启后会把 SSH 打回密码登录"的服务商用的开机自愈
```

不用 agent 也可以自己照着 `SKILL.md` 手动做,它本身就是一份完整教程。

## 几句提醒

- **机房 IP 别拿来注册账号**(各类 AI、社交平台),很容易被风控拒;日常上网、看流媒体、用 AI 没问题。
- 主力用 Reality,不通或慢了切 Hysteria2;机器有 IPv6 的话再加一组 v6 节点当保险。
- 节点只给自己和信得过的人用,别在上面跑别的服务、别放其他密钥,偶尔看一眼有没有陌生进程/容器。
- 请在你所在地法律允许的范围内使用。

## 致谢

技能里调用了这些优秀的开源项目:
[233boy/sing-box](https://github.com/233boy/sing-box) ·
[NodeQuality](https://run.NodeQuality.com) ·
[RegionRestrictionCheck(check.unlock.media)](https://github.com/lmc999/RegionRestrictionCheck) ·
[SagerNet/sing-box](https://github.com/SagerNet/sing-box)

## License

MIT
