#!/bin/bash
# ============================================================
#  订阅链接服务:在 VPS 上用 Caddy(Docker)发布 HTTPS 订阅,客户端贴 URL 即可导入
#
#  - 域名:<IP 用横杠>.sslip.io(免费通配 DNS,直接解析到本机 IP),无需买域名
#  - 证书:Caddy 自动申请 Let's Encrypt(HTTP-01,需要 80/tcp 可达)
#  - 路径:/<随机 token>/...,只认 token,根路径和目录都 404
#
#  前提:同目录有 gen-clients.sh;已装 Docker(setup.sh 会装)
#  用法(服务器上 root 运行,幂等;重跑会保留 token 并刷新节点内容):
#    NAME_PREFIX=FRA SUB_PORT=8880 bash sub-server.sh
#  换 token(旧链接立即失效): ROTATE_TOKEN=yes bash sub-server.sh
#  卸载: docker rm -f sub-caddy && rm -rf /opt/sub
# ============================================================
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "必须 root 运行"; exit 1; }
command -v docker >/dev/null || { echo "需要 Docker"; exit 1; }
HERE="$(cd "$(dirname "$0")" && pwd)"
PREFIX="${NAME_PREFIX:-NODE}"
SUB_PORT="${SUB_PORT:-8880}"
BASE=/opt/sub

IP=$(curl -4 -s --max-time 8 https://api.ipify.org)
DOMAIN="${SUB_DOMAIN:-${IP//./-}.sslip.io}"

install -d -m 700 "$BASE"
if [ ! -s "$BASE/token" ] || [ "${ROTATE_TOKEN:-no}" = "yes" ]; then
  openssl rand -hex 16 > "$BASE/token"
fi
TOKEN=$(cat "$BASE/token")

# 1) 生成三端配置
NAME_PREFIX="$PREFIX" bash "$HERE/gen-clients.sh" >/dev/null
SRC=/root/clients

# 2) 组装订阅文件
rm -rf "$BASE/www"; install -d "$BASE/www/$TOKEN"
W="$BASE/www/$TOKEN"
base64 -w0 "$SRC/shadowrocket.txt" > "$W/shadowrocket"                          # 小火箭:base64 订阅
sed -n '/^\[Proxy\]/,/^\[/{/^\[/d;/^$/d;p}' "$SRC/surge.conf" > "$W/surge.list"  # Surge:policy-path 节点列表
# 带分流规则的完整配置(规则集:blackmatrix7/ios_rule_script,经 jsDelivr,国内可直连)
U_BASE="https://$DOMAIN:$SUB_PORT/$TOKEN"
SRC="$SRC" W="$W" U_BASE="$U_BASE" python3 - <<'PY'
import os, re
src, w, ubase = os.environ["SRC"], os.environ["W"], os.environ["U_BASE"]
RS = "https://cdn.jsdelivr.net/gh/blackmatrix7/ios_rule_script@master/rule"
# (规则集, 策略) —— 顺序即优先级
RULES = [("Lan", "DIRECT"), ("Advertising", "REJECT"),
         ("OpenAI", "AI"), ("Claude", "AI"), ("Gemini", "AI"),
         ("YouTube", "流媒体"), ("Netflix", "流媒体"),
         ("Telegram", "节点选择"), ("Google", "节点选择"),
         ("Apple", "苹果"), ("ChinaMax", "DIRECT")]
SKIP = "127.0.0.1, 192.168.0.0/16, 10.0.0.0/8, 172.16.0.0/12, 100.64.0.0/10, localhost, *.local, *.ts.net"

surge_nodes = [l for l in open(f"{src}/surge.conf").read().split("[Proxy]\n")[1].split("\n[")[0].splitlines() if "=" in l]
surge_names = [l.split("=")[0].strip() for l in surge_nodes]
clash_txt = open(f"{src}/openclash.yaml").read()
clash_proxies = clash_txt[clash_txt.index("proxies:"):clash_txt.index("proxy-groups:")].rstrip()
clash_names = re.findall(r"^  - name: (.+)$", clash_proxies, re.M)

def groups(names, fmt):
    g = [("节点选择", names + ["DIRECT"]), ("AI", ["节点选择"] + names),
         ("流媒体", ["节点选择"] + names + ["DIRECT"]), ("苹果", ["DIRECT", "节点选择"]),
         ("漏网之鱼", ["节点选择", "DIRECT"])]
    return [fmt(n, m) for n, m in g]

# ---------- Surge:托管配置 ----------
with open(f"{w}/surge.conf", "w") as f:
    f.write(f"#!MANAGED-CONFIG {ubase}/surge.conf interval=86400 strict=false\n\n")
    f.write(f"[General]\nloglevel = notify\nipv6 = false\ndns-server = 223.5.5.5, 119.29.29.29, system\n"
            f"skip-proxy = {SKIP}\nexclude-simple-hostnames = true\n"
            "internet-test-url = http://www.baidu.com\nproxy-test-url = http://cp.cloudflare.com/generate_204\n\n")
    f.write("[Proxy]\n" + "\n".join(surge_nodes) + "\n\n[Proxy Group]\n")
    f.write("\n".join(groups(surge_names, lambda n, m: f"{n} = select, {', '.join(m)}")) + "\n\n[Rule]\n")
    for r, pol in RULES:
        f.write(f"RULE-SET,{RS}/Surge/{r}/{r}.list,{pol}" + (",extended-matching" if pol == "REJECT" else "") + "\n")
    f.write("GEOIP,CN,DIRECT\nFINAL,漏网之鱼,dns-failed\n")

# ---------- 小火箭:规则配置(节点来自订阅,PROXY = 当前选中的节点) ----------
SR = {"AI": "PROXY", "流媒体": "PROXY", "节点选择": "PROXY", "苹果": "DIRECT"}
with open(f"{w}/shadowrocket.conf", "w") as f:
    f.write(f"[General]\nbypass-system = true\nipv6 = false\nprefer-ipv6 = false\n"
            f"dns-server = system, 223.5.5.5, 119.29.29.29\nskip-proxy = {SKIP}\n"
            "tun-excluded-routes = 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.168.0.0/16, 224.0.0.0/4, 255.255.255.255/32\n"
            f"update-url = {ubase}/shadowrocket.conf\n\n[Rule]\n")
    for r, pol in RULES:
        f.write(f"RULE-SET,{RS}/Shadowrocket/{r}/{r}.list,{SR.get(pol, pol)}\n")
    f.write("GEOIP,CN,DIRECT\nFINAL,PROXY\n")

# ---------- OpenClash(Mihomo):完整配置 + rule-providers ----------
y = ["mixed-port: 7890", "allow-lan: true", "mode: rule", "log-level: info", "ipv6: false", "", clash_proxies, "", "proxy-groups:"]
for n, m in [(a, b) for a, b in [(g.split("|")[0], g.split("|")[1].split(",")) for g in groups(clash_names, lambda n, m: n + "|" + ",".join(m))]]:
    y += [f"  - name: {n}", "    type: select", f"    proxies: [{', '.join(m)}]"]
y += ["", "rule-providers:"]
for r, _ in RULES:
    y += [f"  {r}:", "    type: http", "    behavior: classical", "    format: yaml",
          f"    url: {RS}/Clash/{r}/{r}.yaml", f"    path: ./ruleset/bm7_{r}.yaml", "    interval: 86400"]
y += ["", "rules:", "  - IP-CIDR,100.64.0.0/10,DIRECT,no-resolve"]
y += [f"  - RULE-SET,{r},{pol}" for r, pol in RULES]
y += ["  - GEOIP,CN,DIRECT", "  - MATCH,漏网之鱼"]
open(f"{w}/clash.yaml", "w").write("\n".join(y) + "\n")
PY
rm -rf "$SRC"
chmod -R a+rX "$BASE/www"

# 3) Caddy
cat > "$BASE/Caddyfile" <<EOF
$DOMAIN:$SUB_PORT {
  @ok path /$TOKEN/shadowrocket /$TOKEN/shadowrocket.conf /$TOKEN/surge.list /$TOKEN/surge.conf /$TOKEN/clash.yaml
  handle @ok {
    root * /srv
    header Cache-Control "no-store"
    header Content-Type "text/plain; charset=utf-8"
    file_server
  }
  handle {
    respond 404
  }
}
EOF
if docker ps -a --format '{{.Names}}' | grep -qx sub-caddy; then
  docker exec sub-caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || docker restart sub-caddy >/dev/null
else
  docker run -d --name sub-caddy --restart unless-stopped --network host \
    -v "$BASE/Caddyfile:/etc/caddy/Caddyfile:ro" -v "$BASE/www:/srv:ro" \
    -v sub-caddy-data:/data -v sub-caddy-config:/config caddy:2-alpine >/dev/null
fi

U="https://$DOMAIN:$SUB_PORT/$TOKEN"
echo "等待证书签发..."
for i in $(seq 1 30); do curl -sf --max-time 5 -o /dev/null "$U/surge.list" && break; sleep 3; done
curl -sf --max-time 5 -o /dev/null "$U/surge.list" && echo "✓ HTTPS 订阅可用" || echo "✗ 还不通:docker logs sub-caddy 看原因(80/tcp 和 $SUB_PORT/tcp 要放行)"
cat <<EOF

小火箭  节点订阅:   $U/shadowrocket
小火箭  规则配置:   $U/shadowrocket.conf
Surge   完整配置:   $U/surge.conf      (托管配置,含节点+分流规则)
Surge   仅节点:     $U/surge.list      (合进已有配置: 自建 = select, policy-path=<这个URL>)
OpenClash 完整配置: $U/clash.yaml      (含节点+分流规则)
⚠️ 拿到链接 = 拿到节点,别外传;泄露了就 ROTATE_TOKEN=yes 重跑
EOF
