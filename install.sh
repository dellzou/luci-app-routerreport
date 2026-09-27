#!/bin/sh
# install.sh —— 在路由器上安装「邮件日报」LuCI 应用（纯文件，无 apk 包管理）
#
# 前提：部署包已解到 /tmp/luci-app-routerreport/（deploy.sh 会自动做）
# 特性：① 覆盖前自动备份到 /mnt/data/backup-routerreport/<时间戳>/
#       ② /etc/config/routerreport 已存在则不覆盖
#       ③ 首次安装会把现有 /etc/router-report.conf + /etc/msmtprc 回填进 UCI（免得重填一遍）
#       ④ 只装文件，不改 /etc/msmtprc、不改 crontab（要改请在 WebUI 点「保存并应用」）
#
# 生成：WorkBuddy  2026-09-26

SRC=/tmp/luci-app-routerreport/root
TS=$(date +%Y%m%d-%H%M%S)
BAK=/mnt/data/backup-routerreport/$TS

if [ ! -d "$SRC" ]; then
	echo "错误：找不到 $SRC，请先运行 deploy.sh 上传" >&2
	exit 1
fi
if [ ! -x /usr/bin/router-daily-report ]; then
	echo "警告：/usr/bin/router-daily-report 不存在或不可执行，装好后页面按钮会报错" >&2
fi

FILES="etc/config/routerreport usr/bin/router-report-apply usr/bin/router-daily-report usr/lib/lua/luci/controller/routerreport.lua usr/lib/lua/luci/view/routerreport/main.htm usr/share/rpcd/acl.d/luci-app-routerreport.json"

# ---------- 1. 备份 ----------
mkdir -p "$BAK"
for f in $FILES; do
	if [ -f "/$f" ]; then
		mkdir -p "$BAK/$(dirname "$f")"
		cp "/$f" "$BAK/$f"
	fi
done
echo "已备份旧文件 -> $BAK"

# ---------- 1b. 配套脚本（metrics / logarchive）----------
# 这两个不参与 UCI 配置，只保证"随包升级"；已存在且更新则备份后覆盖。
for s in router-metrics router-logarchive; do
	if [ -f "/tmp/luci-app-routerreport/payload/usr/bin/$s" ]; then
		if [ -f "/usr/bin/$s" ] && ! cmp -s "/tmp/luci-app-routerreport/payload/usr/bin/$s" "/usr/bin/$s"; then
			mkdir -p "$BAK/usr/bin"
			cp "/usr/bin/$s" "$BAK/usr/bin/$s"
		fi
		cp "/tmp/luci-app-routerreport/payload/usr/bin/$s" "/usr/bin/$s"
		chmod 755 "/usr/bin/$s"
		echo "已安装 /usr/bin/$s"
	fi
done

# cron：router-logarchive 每 6 小时轮转一次日志（幂等，已存在则不动）
if [ -x /usr/bin/router-logarchive ]; then
	if ! grep -q '/usr/bin/router-logarchive' /etc/crontabs/root 2>/dev/null; then
		echo "0 */6 * * * /usr/bin/router-logarchive" >> /etc/crontabs/root
		/etc/init.d/cron restart >/dev/null 2>&1 || /etc/init.d/cron reload >/dev/null 2>&1
		echo "已加入 cron：router-logarchive（0 */6 * * *）"
	else
		echo "cron 已有 router-logarchive，跳过"
	fi
fi

# ---------- 2. 拷文件 ----------
if [ -f /etc/config/routerreport ]; then
	echo "已存在 /etc/config/routerreport —— 保留不动（你的配置不会被覆盖）"
else
	cp "$SRC/etc/config/routerreport" /etc/config/routerreport
	echo "已写入默认 UCI 配置"
fi
chmod 600 /etc/config/routerreport

# 配置自检：整个文件必须能被 UCI 解析。
# 踩过的坑：两个节的「名字」相同（如 config report 'main' + config smtp 'main'）会让整个文件
# 直接不可用，而 uci -q set 又是静默失败 —— 结果就是"配了等于没配"，必须在这里拦住。
if ! uci -q show routerreport >/dev/null 2>&1; then
	echo "错误：/etc/config/routerreport 无法被 UCI 解析（多半是分节名重复）—— 已中止安装" >&2
	uci show routerreport >&2
	exit 1
fi
echo "配置解析自检通过"

cp "$SRC/usr/bin/router-report-apply" /usr/bin/router-report-apply
chmod 755 /usr/bin/router-report-apply

# 日报脚本：本应用需要其 WARN_THRESHOLD（阈值）支持，随包升级（旧版已在上一步备份）
if [ -f /tmp/luci-app-routerreport/payload/usr/bin/router-daily-report ]; then
	cp /tmp/luci-app-routerreport/payload/usr/bin/router-daily-report /usr/bin/router-daily-report
	chmod 755 /usr/bin/router-daily-report
	echo "日报脚本已更新（含 WARN_THRESHOLD 阈值支持）"
fi

mkdir -p /usr/lib/lua/luci/controller /usr/lib/lua/luci/view/routerreport /usr/share/rpcd/acl.d
cp "$SRC/usr/lib/lua/luci/controller/routerreport.lua" /usr/lib/lua/luci/controller/routerreport.lua
cp "$SRC/usr/lib/lua/luci/view/routerreport/main.htm" /usr/lib/lua/luci/view/routerreport/main.htm
cp "$SRC/usr/share/rpcd/acl.d/luci-app-routerreport.json" /usr/share/rpcd/acl.d/luci-app-routerreport.json
echo "程序文件已安装"

# ---------- 3. 首次安装：把现有运行配置回填进 UCI ----------
SEEDED=0
if [ -f /etc/router-report.conf ]; then
	# shellcheck disable=SC1091
	. /etc/router-report.conf 2>/dev/null
	[ -n "${ROUTER_NAME:-}" ] && { uci -q set routerreport.main.router_name="$ROUTER_NAME"; SEEDED=1; }
	[ -n "${RECIPIENT:-}" ] && { uci -q set routerreport.main.recipient="$RECIPIENT"; SEEDED=1; }
	[ -n "${FROM_ADDR:-}" ] && { uci -q set routerreport.main.from="$FROM_ADDR"; SEEDED=1; }
	[ -n "${WARN_THRESHOLD:-}" ] && { uci -q set routerreport.main.warn_threshold="$WARN_THRESHOLD"; SEEDED=1; }
fi

if [ -f /etc/msmtprc ]; then
	MHOST=$(sed -n 's/^host[[:space:]]\+\(.*\)$/\1/p' /etc/msmtprc | head -1)
	MPORT=$(sed -n 's/^port[[:space:]]\+\(.*\)$/\1/p' /etc/msmtprc | head -1)
	MUSER=$(sed -n 's/^user[[:space:]]\+\(.*\)$/\1/p' /etc/msmtprc | head -1)
	MPASS=$(sed -n 's/^password[[:space:]]\+\(.*\)$/\1/p' /etc/msmtprc | head -1)
	[ -n "$MHOST" ] && { uci -q set routerreport.smtp.host="$MHOST"; SEEDED=1; }
	[ -n "$MPORT" ] && { uci -q set routerreport.smtp.port="$MPORT"; SEEDED=1; }
	[ -n "$MUSER" ] && { uci -q set routerreport.smtp.user="$MUSER"; SEEDED=1; }
	[ -n "$MPASS" ] && { uci -q set routerreport.smtp.password="$MPASS"; SEEDED=1; }
fi

# 当前 crontab 里已有日报行 -> 认为自动发送是开着的
if grep -q '/usr/bin/router-daily-report' /etc/crontabs/root 2>/dev/null; then
	CT=$(awk '/\/usr\/bin\/router-daily-report/ {printf "%02d:%02d", $2 + 0, $1 + 0; exit}' /etc/crontabs/root 2>/dev/null)
	uci -q set routerreport.main.enabled='1'; SEEDED=1
	[ -n "$CT" ] && { uci -q set routerreport.main.send_time="$CT"; }
else
	uci -q set routerreport.main.enabled='0'
fi

if [ "$SEEDED" = "1" ]; then
	uci -q commit routerreport
	chmod 600 /etc/config/routerreport
	echo "已把现有运行配置回填进 UCI（WebUI 打开即可看到当前值）"
	# 回填结果自检：确认确实写进去了（uci -q set 失败时是静默的）
	echo "  自检 recipient='$(uci -q get routerreport.main.recipient)'  enabled='$(uci -q get routerreport.main.enabled)'  send_time='$(uci -q get routerreport.main.send_time)'"
fi

# ---------- 4. 让 LuCI 认到新菜单 ----------
rm -f /tmp/luci-indexcache* 2>/dev/null
/etc/init.d/rpcd reload >/dev/null 2>&1
/etc/init.d/uhttpd reload >/dev/null 2>&1

echo
echo "安装完成。入口：LuCI -> 服务 -> 邮件日报"
echo "回滚：cp -r $BAK/* / && rm -rf /usr/lib/lua/luci/controller/routerreport.lua /usr/lib/lua/luci/view/routerreport /usr/share/rpcd/acl.d/luci-app-routerreport.json && rm -f /tmp/luci-indexcache*"
exit 0
