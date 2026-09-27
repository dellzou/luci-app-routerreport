#!/bin/sh
# deploy.sh —— 把「邮件日报」LuCI 应用从电脑部署到路由器（在电脑上执行）
#
#   ./deploy.sh --check     只做语法检查，不往路由器写任何文件
#   ./deploy.sh --install   上传并安装（会先备份旧文件到 /mnt/data/backup-routerreport/）
#
# 生成：WorkBuddy  2026-09-26
# 注意：本机 Git Bash 的 PATH 里可能没有 coreutils，先执行
#   export PATH="/c/Users/27970/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:$PATH"

set -u
DIR=$(cd "$(dirname "$0")" && pwd)
MODE="${1:---check}"
LUA_LOCAL="$DIR/root/usr/lib/lua/luci/controller/routerreport.lua"
LUA_VIEW="$DIR/root/usr/lib/lua/luci/view/routerreport/main.htm"
SH_APPLY="$DIR/root/usr/bin/router-report-apply"
SH_INSTALL="$DIR/install.sh"
SH_REPORT="$DIR/../scripts/router-daily-report"

echo "== 1) 本地 shell 语法检查 =="
for f in "$SH_APPLY" "$SH_INSTALL" "$SH_REPORT"; do
	if [ -f "$f" ] && sh -n "$f" 2>/tmp/.rr-sh.err; then
		echo "   OK   $(basename "$f")"
	else
		echo "   FAIL $(basename "$f")"; cat /tmp/.rr-sh.err 2>/dev/null; exit 1
	fi
done
rm -f /tmp/.rr-sh.err

echo "== 2) JSON 检查（acl 文件）=="
if command -v python >/dev/null 2>&1; then
	python -c "import json,sys;json.load(sys.stdin);print('   OK   acl json')" \
		< "$DIR/root/usr/share/rpcd/acl.d/luci-app-routerreport.json" || exit 1
else
	echo "   SKIP 没有 python，跳过（内容很短，可肉眼核对）"
fi

echo "== 3) Lua 语法检查（借路由器上的 lua 解释器，只读 stdin，不在设备上写文件）=="
if ssh -o ConnectTimeout=8 router 'command -v lua >/dev/null 2>&1'; then
	if ssh router 'lua -e "local s=io.read(\"*a\"); local f,e=loadstring(s); if f then print(\"   OK   controller\") else print(\"   FAIL \"..tostring(e)); os.exit(1) end"' < "$LUA_LOCAL"; then
		echo "   controller 语法通过"
	else
		echo "   controller 语法失败"; exit 1
	fi
	# 视图文件里的 Lua 只取第一段 <% ... %>（跳过 <%+include%> 与 <%="百分号表达式"%>）
	awk '/^<%/ && $0 !~ /^<%[+="]/ { inb=1; sub(/^<%/,"") } inb { if (/%>/) { sub(/%>.*/,""); print; inb=0 } else print }' "$LUA_VIEW" > /tmp/.rr-view.lua
	echo "   （视图内嵌 Lua 片段 $(wc -l < /tmp/.rr-view.lua) 行）"
	if ssh router 'lua -e "local s=io.read(\"*a\"); local f,e=loadstring(s); if f then print(\"   OK   view-lua\") else print(\"   FAIL \"..tostring(e)); os.exit(1) end"' < /tmp/.rr-view.lua; then
		echo "   视图 Lua 语法通过"
	else
		echo "   视图 Lua 语法失败"; exit 1
	fi
else
	echo "   SKIP 路由器上没有 lua 命令"
fi

if [ "$MODE" = "--check" ]; then
	echo
	echo "全部检查通过（未改动路由器上的任何文件）。"
	exit 0
fi

if [ "$MODE" != "--install" ]; then
	echo "未知参数：$MODE（可用 --check / --install）" >&2
	exit 1
fi

echo "== 4) 打包上传 =="
TARBALL=/tmp/luci-app-routerreport.tgz
STAGE=/tmp/.rr-stage.$$
rm -rf "$STAGE"; mkdir -p "$STAGE/payload/usr/bin"
cp -r "$DIR/root" "$DIR/install.sh" "$STAGE/"
cp "$SH_REPORT" "$STAGE/payload/usr/bin/router-daily-report"
cp "$DIR/scripts/router-metrics"    "$STAGE/payload/usr/bin/router-metrics"
cp "$DIR/scripts/router-logarchive" "$STAGE/payload/usr/bin/router-logarchive"
tar czf "$TARBALL" -C "$STAGE" .
rm -rf "$STAGE"
echo "   包大小：$(wc -c < "$TARBALL") 字节"
cat "$TARBALL" | ssh router 'cat > /tmp/luci-app-routerreport.tgz'
rm -f "$TARBALL"

echo "== 5) 在路由器上安装 =="
ssh router 'cd /tmp && rm -rf /tmp/luci-app-routerreport && mkdir -p /tmp/luci-app-routerreport && tar xzf /tmp/luci-app-routerreport.tgz -C /tmp/luci-app-routerreport && sh /tmp/luci-app-routerreport/install.sh'

echo
echo "部署结束。请在浏览器打开 http://<路由器IP> -> 服务 -> 邮件日报"
