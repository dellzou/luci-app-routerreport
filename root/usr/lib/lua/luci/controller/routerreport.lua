-- routerreport.lua —— LuCI 控制器：邮件日报（配置 + 测试发送 + 预览 + 补发）
--
-- 实现方式与同机第三方应用 luci-app-lmclient 一致：
--   控制器只做「校验参数 -> uci set/commit -> 调本机脚本」，权限全靠 acl.d 声明。
-- 生成：WorkBuddy  2026-09-26

module("luci.controller.routerreport", package.seeall)

local sys  = require "luci.sys"
local http = require "luci.http"
local uci  = require "luci.model.uci".cursor()

local SCRIPT       = "/usr/bin/router-daily-report"
local APPLY        = "/usr/bin/router-report-apply"
local PREVIEW_FILE = "/tmp/rd-preview.mail"
local SENT_DIR     = "/mnt/data/sysreport"
local MSMTP_LOG    = "/mnt/data/logs/msmtp.log"

-- ---------- 小工具 ----------

local function jesc(s)
	s = tostring(s or "")
	s = s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\r", "")
	s = s:gsub("\n", "\\n"):gsub("\t", " ")
	return s
end

local function jstr(s)
	return '"' .. jesc(s) .. '"'
end

local function valid_date(d)
	return type(d) == "string" and d:match("^%d%d%d%d%-%d%d%-%d%d$") ~= nil
end

local function exists(p)
	local f = io.open(p, "r")
	if f then f:close() return true end
	return false
end

local function read_all(p)
	local f = io.open(p, "r")
	if not f then return nil end
	local c = f:read("*a")
	f:close()
	return c
end

local function tail(path, lines)
	local c = read_all(path)
	if not c then return "" end
	local buf = {}
	for l in c:gmatch("[^\n]*") do
		buf[#buf + 1] = l
	end
	local n, out = #buf, {}
	for i = math.max(1, n - lines + 1), n do
		out[#out + 1] = buf[i]
	end
	return table.concat(out, "\n")
end

local function json_out(s)
	http.prepare_content("application/json")
	http.write(s)
	return
end

local function fv(name, maxlen)
	local v = http.formvalue(name)
	if v == nil then return nil end
	v = v:gsub("[\r\n\t]", " ")
	if maxlen and #v > maxlen then v = v:sub(1, maxlen) end
	return v
end

-- ---------- 菜单 ----------

function index()
	entry({ "admin", "services", "routerreport" },
		template("routerreport/main"), _("邮件日报"), 81).acl_depends = { "luci-app-routerreport" }
	entry({ "admin", "services", "routerreport", "api" },
		call("action_api"), nil).acl_depends = { "luci-app-routerreport" }
	entry({ "admin", "services", "routerreport", "preview" },
		call("action_preview"), nil).acl_depends = { "luci-app-routerreport" }
end

-- ---------- 动作分发 ----------

function action_api()
	local action = fv("action") or ""
	if not action:match("^[%w_]+$") then
		return json_out('{"status":"error","message":"invalid action"}')
	end
	if action == "save" then
		return action_save()
	elseif action == "send" then
		return action_send()
	elseif action == "status" then
		return action_status()
	end
	return json_out('{"status":"error","message":"unknown action"}')
end

-- 保存配置 -> uci commit -> 渲染运行配置
function action_save()
	local enabled = (fv("enabled") == "1") and "1" or "0"
	local send_time = fv("send_time", 5) or ""
	local router_name = fv("router_name", 64) or ""
	local recipient = fv("recipient", 128) or ""
	local from = fv("from", 128) or ""
	local threshold = fv("warn_threshold", 6) or ""
	local smtp_host = fv("smtp_host", 128) or ""
	local smtp_port = fv("smtp_port", 6) or ""
	local smtp_user = fv("smtp_user", 128) or ""
	local smtp_pass = fv("smtp_password", 128)

	-- 校验
	if not send_time:match("^%d%d?:%d%d$") then
		return json_out('{"status":"error","message":"发送时间格式应为 HH:MM"}')
	end
	if recipient ~= "" and not recipient:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
		return json_out('{"status":"error","message":"收件人邮箱格式不正确"}')
	end
	if enabled == "1" and recipient == "" then
		return json_out('{"status":"error","message":"启用自动发送前必须填写收件人"}')
	end
	if from ~= "" and not from:match("^[^@%s]+@[^@%s]+%.[^@%s]+$") then
		return json_out('{"status":"error","message":"发件人邮箱格式不正确"}')
	end
	if smtp_port ~= "" and not smtp_port:match("^%d+$") then
		return json_out('{"status":"error","message":"SMTP 端口必须是数字"}')
	end
	if threshold ~= "" and not threshold:match("^%d+$") then
		return json_out('{"status":"error","message":"告警阈值必须是数字"}')
	end
	if smtp_pass == nil then smtp_pass = "" end

	local c = uci
	local function uset(opt, val)
		if val ~= nil and val ~= "" then
			c:set("routerreport", "main", opt, val)
		end
	end
	uset("enabled", enabled)
	uset("send_time", send_time)
	uset("router_name", router_name)
	if recipient ~= "" then c:set("routerreport", "main", "recipient", recipient) end
	c:set("routerreport", "main", "from", from)
	uset("warn_threshold", threshold)

	-- ⚠️ SMTP 主机/端口属于 smtp 节，早期版本误写成 main 节的 smtp_host/smtp_port，
	--    导致界面里改 SMTP 主机/端口不生效（apply 只读 smtp.host / smtp.port）。
	local function sset(opt, val)
		if val ~= nil and val ~= "" then
			c:set("routerreport", "smtp", opt, val)
		end
	end
	sset("host", smtp_host)
	sset("port", smtp_port)
	if smtp_user ~= "" then c:set("routerreport", "smtp", "user", smtp_user) end
	if smtp_pass ~= "" then c:set("routerreport", "smtp", "password", smtp_pass) end
	c:commit("routerreport")

	-- 清理历史误写：main 节下不应存在 smtp_* 选项
	for _, bad in ipairs({ "smtp_host", "smtp_port", "smtp_user", "smtp_password" }) do
		if c:get("routerreport", "main", bad) ~= nil then
			c:delete("routerreport", "main", bad)
			c:commit("routerreport")
		end
	end

	local out = sys.exec(APPLY .. " 2>&1") or ""
	out = out:gsub("%s+$", "")
	local j = out:match("({.*})")
	if not j then
		return json_out('{"status":"error","message":"配置已保存，但渲染失败：' .. jesc(out) .. '"}')
	end

	-- 从渲染结果里挑出人话摘要，回给界面直接显示
	local en = j:match('"enabled":"(%d)"') or "?"
	local st = j:match('"send_time":"([%d:]+)"') or "?"
	local cr = j:match('"cron":"([%w_]+)"') or "?"
	local rc = j:match('"recipient":"([^"]*)"') or ""
	local th = j:match('"threshold":"(%d+)"') or "?"
	local cron_txt
	if cr == "enabled" then cron_txt = "已按 " .. st .. " 排入定时任务"
	elseif cr == "disabled" then cron_txt = "定时任务已移除（仅手动发送）"
	else cron_txt = "定时任务无变化" end

	local msg = string.format("配置已保存并生效 · 自动发送：%s · 发送时间：%s · 阈值：%s 条 · 收件人：%s · %s",
		(en == "1" and "启用" or "停用"), st, th, (rc == "" and "未设置" or rc), cron_txt)

	return json_out('{"status":"ok","message":"' .. jesc(msg) ..
		'","at":"' .. os.date("%H:%M:%S") ..
		'","apply":"' .. jesc(j) .. '"}')
end

-- 发送 / 补发（date 为今天即"测试发送"）
function action_send()
	local date = fv("date", 10)
	local force = (fv("force") == "1") and "1" or "0"
	if not date or date == "" then
		date = os.date("%Y-%m-%d")
	end
	if not valid_date(date) then
		return json_out('{"status":"error","message":"日期格式应为 YYYY-MM-DD"}')
	end

	local cmd = SCRIPT .. " --date " .. date
	if force == "1" then cmd = cmd .. " --force" end
	cmd = cmd .. " 2>&1"

	-- ⚠️ 先删掉当天标记再发：否则沿用上次成功的旧标记，会把这次失败误报成"已发送"
	local flag = SENT_DIR .. "/.sent-" .. date
	os.remove(flag)

	local out = sys.exec(cmd) or ""
	out = out:gsub("%s+$", "")

	local ok = exists(flag)
	local who = ""
	local fh = io.open("/etc/router-report.conf", "r")
	if fh then
		local c = fh:read("*a") or ""
		fh:close()
		who = c:match('RECIPIENT="([^"]*)"') or ""
	end

	local today = os.date("%Y-%m-%d")
	local kind = (date == today) and "测试发送" or "补发"
	local msg
	if ok then
		msg = string.format("✅ %s成功（%s）· 已投递到 %s · %s", kind, date, (who == "" and "收件人未配置" or who), os.date("%H:%M:%S"))
	else
		msg = string.format("❌ %s失败（%s）· 未投递成功，详见下方执行输出与 msmtp 日志", kind, date)
	end

	local resp = {
		'{"status":"' .. (ok and "ok" or "error") .. '"',
		'"message":' .. jstr(msg),
		'"date":' .. jstr(date),
		'"at":' .. jstr(os.date("%H:%M:%S")),
		'"output":' .. jstr(out)
	}
	if not ok then
		resp[#resp + 1] = '"mailtail":' .. jstr(tail(MSMTP_LOG, 8))
		if exists(SENT_DIR .. "/failed/report-" .. date .. ".mail") then
			resp[#resp + 1] = '"failed_copy":' .. jstr(SENT_DIR .. "/failed/report-" .. date .. ".mail")
		end
	end
	return json_out(table.concat(resp, ",") .. "}")
end

-- 状态回显（不触发任何写操作）
function action_status()
	local c = uci
	local function g(sec, opt)
		return c:get("routerreport", sec, opt) or ""
	end
	local sent = {}
	local p = io.popen("ls -1t " .. SENT_DIR .. "/.sent-* 2>/dev/null | head -3")
	if p then
		for line in p:lines() do
			sent[#sent + 1] = jstr(line:match("%.sent%-(%d%d%d%d%-%d%d%-%d%d)$") or line)
		end
		p:close()
	end
	local resp = {
		'{"status":"ok"',
		'"enabled":' .. jstr(g("main", "enabled")),
		'"send_time":' .. jstr(g("main", "send_time")),
		'"recipient":' .. jstr(g("main", "recipient")),
		'"threshold":' .. jstr(g("main", "warn_threshold")),
		'"password_set":' .. ((g("smtp", "password") ~= "") and "true" or "false"),
		'"recent_sent":[' .. table.concat(sent, ",") .. "]",
		'"mailtail":' .. jstr(tail(MSMTP_LOG, 5))
	}
	return json_out(table.concat(resp, ",") .. "}")
end

-- 预览：跑一次 --dry-run，把邮件正文（不含邮件头）原样吐给 iframe
function action_preview()
	local date = http.formvalue("date")
	if not valid_date(date) then
		date = os.date("%Y-%m-%d")
	end

	sys.exec(SCRIPT .. " --date " .. date .. " --dry-run >/dev/null 2>&1")
	local raw = read_all(PREVIEW_FILE)
	if raw then
		os.remove(PREVIEW_FILE)
	end
	if not raw or raw == "" then
		http.prepare_content("text/html; charset=utf-8")
		http.write("<p style='font:13px sans-serif;color:#a32d2d'>生成预览失败：未取到邮件正文，请检查 /usr/bin/router-daily-report 是否可执行。</p>")
		return
	end

	-- 去掉邮件头（第一个空行之前的部分），只留 HTML 正文
	local body = select(2, raw:match("^(.-)\r?\n\r?\n(.*)$")) or raw
	http.prepare_content("text/html; charset=utf-8")
	http.write(body)
	return
end
