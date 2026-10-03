#!/bin/bash
# ============================================================
#  一键生成客户端配置:Surge / Shadowrocket(小火箭)/ OpenClash(Mihomo)
#
#  读取 233boy sing-box 脚本 `sb url` 输出的分享链接
#  (支持 vless-reality / hysteria2 / anytls),转换成三种客户端格式。
#
#  用法(服务器上 root 运行):
#    NAME_PREFIX=FRA bash gen-clients.sh      # 节点名前缀,默认 NODE
#  输出到 /root/clients/ :surge.conf  shadowrocket.txt  openclash.yaml
#  拿回本机:scp -r root@IP:/root/clients ./ ,用完在服务器上删掉(含节点密钥)
#
#  注意:Surge 不支持 VLESS-Reality,Surge 配置里只会有 anytls / hysteria2。
#        想让 Surge 有 TCP 主力,先 `sb add anytls 2053`。
# ============================================================
set -euo pipefail
[ "$(id -u)" = "0" ] || { echo "必须 root 运行"; exit 1; }
command -v sb >/dev/null || { echo "未找到 sb 命令,先装 233boy/sing-box"; exit 1; }
export TERM=xterm
PREFIX="${NAME_PREFIX:-NODE}"
OUT=/root/clients
install -d -m 700 "$OUT"

URLS=$(for f in /etc/sing-box/conf/*.json; do
  sb url "$(basename "$f" .json)" 2>&1 | sed -r 's/\x1b\[[0-9;]*m//g' | grep -E '^(vless|hysteria2|anytls)://' || true
done)
[ -n "$URLS" ] || { echo "没拿到任何分享链接"; exit 1; }

PREFIX="$PREFIX" OUT="$OUT" python3 - "$URLS" <<'PY'
import os, sys
from urllib.parse import urlsplit, parse_qs, unquote

prefix, out = os.environ["PREFIX"], os.environ["OUT"]
nodes = []
for line in sys.argv[1].split():
    u = urlsplit(line)
    q = {k: v[0] for k, v in parse_qs(u.query).items()}
    kind = {"vless": "Reality", "hysteria2": "Hy2", "anytls": "AnyTLS"}[u.scheme]
    nodes.append(dict(scheme=u.scheme, name=f"{prefix}-{kind}", secret=unquote(u.username),
                      host=u.hostname, port=u.port, q=q, raw=line.split("#")[0]))

order = {"vless": 0, "anytls": 1, "hysteria2": 2}
nodes.sort(key=lambda n: order[n["scheme"]])

# ---------- Shadowrocket:原样链接,只改备注名 ----------
with open(f"{out}/shadowrocket.txt", "w") as f:
    for n in nodes:
        f.write(n["raw"] + "#" + n["name"] + "\n")

# ---------- Surge ----------
# 233boy 的 hysteria2 / anytls 共用同一张自签证书,anytls 链接里没带指纹就借 hy2 的
shared_pin = next((n["q"]["pinSHA256"] for n in nodes if n["q"].get("pinSHA256")), "")
surge = []
for n in nodes:
    q, pin = n["q"], n["q"].get("pinSHA256", shared_pin)
    cert = f"server-cert-fingerprint-sha256={pin}" if pin else "skip-cert-verify=true"
    if n["scheme"] == "anytls":
        surge.append(f'{n["name"]} = anytls, {n["host"]}, {n["port"]}, password={n["secret"]}, {cert}, reuse=true')
    elif n["scheme"] == "hysteria2":
        surge.append(f'{n["name"]} = hysteria2, {n["host"]}, {n["port"]}, password={n["secret"]}, {cert}, download-bandwidth=200')
names = [n["name"] for n in nodes if n["scheme"] != "vless"]
with open(f"{out}/surge.conf", "w") as f:
    f.write("# Surge 不支持 VLESS-Reality,这里只有 AnyTLS / Hysteria2\n[Proxy]\n")
    f.write("\n".join(surge) + "\n\n[Proxy Group]\n")
    f.write(f"自建-{prefix} = select, {', '.join(names)}\n")

# ---------- OpenClash / Mihomo ----------
y = ["# OpenClash 需 Meta(Mihomo)内核", "proxies:"]
for n in nodes:
    q = n["q"]
    y += [f'  - name: {n["name"]}', f'    type: {n["scheme"]}', f'    server: {n["host"]}', f'    port: {n["port"]}']
    if n["scheme"] == "vless":
        y += [f'    uuid: {n["secret"]}', "    network: tcp", "    udp: true", "    tls: true"]
        if q.get("flow"): y.append(f'    flow: {q["flow"]}')
        y += [f'    servername: {q.get("sni", "")}', f'    client-fingerprint: {q.get("fp", "chrome")}',
              "    reality-opts:", f'      public-key: {q.get("pbk", "")}', f'      short-id: "{q.get("sid", "")}"']
    elif n["scheme"] == "hysteria2":
        y += [f'    password: {n["secret"]}', "    alpn: [h3]", "    skip-cert-verify: true"]
    else:
        y += [f'    password: {n["secret"]}', "    client-fingerprint: chrome", "    udp: true", "    skip-cert-verify: true"]
    y.append("")
y += ["proxy-groups:", f"  - name: 自建-{prefix}", "    type: select",
      f'    proxies: [{", ".join(n["name"] for n in nodes)}]']
with open(f"{out}/openclash.yaml", "w") as f:
    f.write("\n".join(y) + "\n")

print("生成节点:", ", ".join(n["name"] for n in nodes))
PY
chmod 600 "$OUT"/*
ls -l "$OUT"
echo "⚠️ 这些文件含节点密钥:拿回本机后在服务器上 rm -rf $OUT"
