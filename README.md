# luci-app-routerreport —— 「邮件日报」LuCI 应用

把 iStoreOS/OpenWrt 上的**每日运行报告邮件**搬进 WebUI：改收件人、改发送时间、设告警阈值、换 SMTP 凭据、一键测试发送、预览任意一天、补发漏掉的日报。

- 面向设备：Intel J6412 / iStoreOS 25.12.5（LuCI 26.253，apk 生态）
- 交付形态：**纯文件应用**（无需 OpenWrt SDK、无需编译）；后续可选打包成 `.apk`
- 依赖：`luci-base`、`luci-compat`（一般已随固件安装）、以及已有的 `/usr/bin/router-daily-report`
- 版本：0.1.1（2026-09-27）

![邮件日报应用界面](https://xiaozou123.cn/wp-content/uploads/2026/09/istoreos-luci-email-daily-report-panel-scaled.png)

> 实际渲染效果（本地用真实主题 CSS 复刻渲染，非示意图）。

**配套的三个采集/发送/轮转脚本也在这个仓库的 [`scripts/`](scripts) 里**，本应用就是它们的"配置界面 + 触发器"：

| 脚本 | 作用 | 调度 |
|---|---|---|
| `scripts/router-metrics` | 每 5 分钟采集流量、CPU/内存/负载、数据盘占用，落 CSV | crontab `*/5 * * * *` |
| `scripts/router-daily-report` | 汇总前一天数据，渲染 HTML 邮件并发送（支持 `--dry-run` / `--date` / `--force`） | crontab 每天一次 |
| `scripts/router-logarchive` | `messages` 日志真轮转 + gzip 归档 + 30 天清理（防日志无限增长） | crontab `0 */6 * * *` |

**不装界面也能用**：只部署这三个脚本 + 配好 `/etc/msmtprc` 与 crontab，就是一个完整的"路由器邮件日报"系统；界面解决的是"改配置不用 SSH"。

---

## 1. 它不碰什么（重要）

| 组件 | 是否被改动 |
|---|---|
| `/usr/bin/router-daily-report`（日报生成与发信） | ❌ 一行不改，只被调用 |
| `/usr/bin/router-metrics`（5 分钟指标采集） | ❌ 不动 |
| crontab 里 `*/5` 指标采集行 | ❌ 不动 |
| crontab 里 `router-daily-report` 那一行 | ✅ 仅在 WebUI 点「保存并应用」时按开关/时间重写（改前自动备份到 `/mnt/data/backup-routerreport/`） |
| `/etc/msmtprc`、`/etc/router-report.conf` | ✅ 由界面保存时重新渲染（渲染脚本 `/usr/bin/router-report-apply`） |

也就是说：**卸载或出错，最坏情况是回到"手工改文件"的现状**，不会破坏日报链路。

> 唯一的例外：为支持「告警阈值」，`router-daily-report` 增加了 `WARN_THRESHOLD` 支持（默认 `1`，等价于原来的 `>0` 判定，行为不变）。

---

## 2. 仓库结构

```
luci-app-routerreport/
├── root/                                  ← 按 OpenWrt 包布局，整棵树可直接拷到 /
│   ├── etc/config/routerreport            UCI 默认配置（已存在则不覆盖）
│   ├── usr/bin/router-report-apply        渲染器：UCI → 运行配置 + msmtprc + crontab 行
│   ├── usr/lib/lua/luci/controller/routerreport.lua
│   ├── usr/lib/lua/luci/view/routerreport/main.htm
│   └── usr/share/rpcd/acl.d/luci-app-routerreport.json
├── scripts/                               ← 配套的业务脚本（不使用界面也需要它们）
│   ├── router-metrics                     指标采集（cron 每 5 分钟）
│   ├── router-daily-report                日报生成与发送（cron 每天一次）
│   └── router-logarchive                  messages 日志轮转 + 归档清理（cron 每 6 小时）
├── deploy.sh                             电脑侧一键部署（--check 只检查 / --install 真装）
├── install.sh                            路由器侧安装（备份 → 拷贝 → 迁移配置 → 清菜单缓存）
├── README.md · LICENSE · VERSION · .gitattributes
└── .gitignore
```

> `scripts/` 里是随仓库发布的副本；部署后实际运行位置是 `/usr/bin/`。
> 截图直接用博客图床外链，仓库里不放二进制文件。

### 三个脚本各自解决什么

| 脚本 | 解决的问题 |
|---|---|
| `router-metrics` | 把"瞬时值"变成"时间序列"——每 5 分钟落一行 CSV，日报才能算平均值和峰值 |
| `router-daily-report` | 读 CSV + 系统日志，渲染 HTML 邮件；**流量按字节累加、输出时才换算单位** |
| `router-logarchive` | iStoreOS 配了 `log_file` 后日志**只追加不轮转**，单文件无限增长 → 真轮转 + gzip + 30 天清理 |

---

## 3. 文件清单（6 个）

| 文件 | 作用 |
|---|---|
| `root/usr/lib/lua/luci/controller/routerreport.lua` | 菜单注册 + `save` / `send` / `status` / `preview` 四个动作 |
| `root/usr/lib/lua/luci/view/routerreport/main.htm` | 页面：状态卡、配置表单、测试发送、预览 iframe、补发 |
| `root/usr/share/rpcd/acl.d/luci-app-routerreport.json` | ACL：`uci: routerreport` 读写（菜单可见性也由它决定） |
| `root/etc/config/routerreport` | UCI 默认配置（**已存在则不覆盖**） |
| `root/usr/bin/router-report-apply` | 渲染器：UCI → `/etc/router-report.conf` + `/etc/msmtprc`(0600) + 维护 crontab 行 |
| `install.sh` / `deploy.sh` | 路由器侧安装脚本 / 电脑侧部署脚本 |

程序文件落点（安装后）：

```
/etc/config/routerreport
/usr/bin/router-report-apply                        (755)
/usr/bin/router-daily-report                        (755)
/usr/bin/router-metrics                             (755)
/usr/bin/router-logarchive                          (755)
/usr/lib/lua/luci/controller/routerreport.lua
/usr/lib/lua/luci/view/routerreport/main.htm
/usr/share/rpcd/acl.d/luci-app-routerreport.json
```

---

## 3.1 一个值得单独说的坑：流量为什么会显示 0

这不是"统计错了"，是 **busybox awk 的 `%d` 只支持 32 位有符号整数**。

| | |
|---|---|
| 32 位有符号整数上限 | `2,147,483,647` ≈ 2.1 GB |
| 一次 4 小时满速下载（2000M 宽带） | 约 2.5 TB |
| 用 `printf "%d"` 输出 2,496,773,389,155 | 截断成 `-2147483648` |
| 脚本的"负数保护"再把负值归零 | → 日报显示 `0 B` |

awk 的**数值本身**是 IEEE754 双精度浮点，能精确表示到 `2^53` ≈ 9 PB，问题只出在**输出格式**上。

```sh
# ❌ 错：超过 2.1 GB 就溢出
END{ printf "%d %d", srx, stx }

# ✅ 对：双精度输出，9 PB 以内无损
END{ printf "%.0f %.0f", srx, stx }
```

同理，shell 的 `$(( ))` 在 32 位 busybox 上也是整数运算，**合计流量必须用 awk 加**：

```sh
TRAF_TOTAL=$(awk -v a="$TRAF_DOWN" -v b="$TRAF_UP" 'BEGIN{ printf "%.0f", a+b }')
```

> 顺带一提：`router-metrics` 落盘的是**裸字节数**（不做单位换算，保证精度），
> 所以任何读这张 CSV 的脚本都要遵守同一条规则 —— 该文件头上写了警告注释。
>
> **单位策略**：内部一律按字节累加，只在渲染邮件时才换算成 KB/MB/GB/TB。

---

## 4. 安装

在电脑上（Git Bash）：

```sh
export PATH="/c/Users/27970/.workbuddy/binaries/PortableGit/versions/1.2.0/usr/bin:$PATH"
cd /c/Users/27970/WorkBuddy/openWRT/luci-app-routerreport

sh deploy.sh --check      # 只做语法检查（shell / json / lua），不碰路由器
sh deploy.sh --install    # 上传并安装（自动备份旧文件）
```

安装脚本会：

1. 把将被覆盖的旧文件备份到 `/mnt/data/backup-routerreport/<时间戳>/`
2. `/etc/config/routerreport` 不存在才写入默认值（**不覆盖已有配置**）
3. **首次安装自动迁移**：把当前 `/etc/router-report.conf` + `/etc/msmtprc` + crontab 里的时间回填进 UCI，打开页面就能看到现有值，不用重填
4. 清理 `/tmp/luci-indexcache*` 并 reload `rpcd`/`uhttpd`（否则菜单不出现）

入口：**LuCI → 服务 → 邮件日报**（`http://<路由器IP>/cgi-bin/luci/admin/services/routerreport`）

---

## 5. 使用

| 元素 | 说明 |
|---|---|
| 当前状态卡 | 自动发送开关、发送时间、收件人、阈值、SMTP 密码是否已设置、最近 3 次发送日期 |
| 报告与收件人 | 启用开关、发送时间（HH:MM，发的是**前一天**的数据）、路由器名、收件人、发件人、告警阈值 |
| SMTP 发信 | 主机 / 端口(465 SSL) / 账号 / 密码（**留空 = 不修改**） |
| 保存并应用 | 写 UCI → commit → 渲染 `router-report.conf` + `msmtprc` → 维护 cron 行 → 重启 cron |
| 立即测试发送（今天） | `router-daily-report --date <今天> --force`，结果直接回显；失败时附带 `msmtp.log` 末尾 |
| 日报预览与补发 | 选日期 → 预览（`--dry-run`，不发信，正文渲染在 iframe 内）；补发（`--force` 重发该日期） |

---

## 6. 卸载 / 回滚

```sh
# 用安装时打印的备份目录
cp -r /mnt/data/backup-routerreport/<时间戳>/* /
rm -f  /usr/lib/lua/luci/controller/routerreport.lua
rm -rf /usr/lib/lua/luci/view/routerreport
rm -f  /usr/share/rpcd/acl.d/luci-app-routerreport.json
rm -f  /tmp/luci-indexcache*
# 可选：连配套脚本与它们的 cron 一起撤掉
rm -f  /usr/bin/router-daily-report /usr/bin/router-metrics /usr/bin/router-logarchive
sed -i '/router-logarchive/d' /etc/crontabs/root && /etc/init.d/cron restart
```

`/etc/config/routerreport` 可保留（不装应用就没人读它）；想彻底清干净就一并删掉。crontab 与 `msmtprc` 会被保留成卸载前的最后状态。

---

## 7. 安全说明

- 页面走 LuCI 原有的 **HTTP + 会话认证**（仅内网 `<路由器IP>`，WAN 侧 REJECT）。密码在此链路上是明文的——和 LuCI 登录本身一致，未引入新的暴露面。
- SMTP 授权码存在 `/etc/config/routerreport`（安装与每次保存都强制 `chmod 600`），渲染出的 `/etc/msmtprc` 同为 `600`。
- 能登录 LuCI 就等于 root，因此"界面能读到授权码"不构成额外的权限提升。
- ⚠️ **实测坑**：`/etc/config` 下权限是 600/644 混杂的，`uci commit` 不保证 0600 —— 所以本应用**显式 chmod**，不要删掉那两行。

---

## 8. 验证状态（2026-09-27 复测）

| 项目 | 状态 |
|---|---|
| shell / Lua / JSON 静态检查（`deploy.sh --check`） | ✅ 全绿 |
| 控制器在真实 LuCI Lua 环境下可加载（`require`） | ✅ |
| 模板数据层：9 个字段读值正确（收件人/时间/阈值/SMTP/密码已设置） | ✅ |
| UCI 解析自检 + 首次安装迁移现有配置 | ✅ |
| 渲染脚本幂等：连跑两次 → 第二次 `cron:unchanged` | ✅ |
| crontab：日报行仅 1 条、标记不累积、指标采集行完好、时间零丢失 | ✅ |
| `msmtprc` 功能行与安装前**逐行一致**（仅注释头不同） | ✅ |
| 告警阈值生效：阈值调大后正文里"N 条需关注"条目消失 | ✅ |
| 业务链路未被波及（`router-report.conf` / `msmtprc` / crontab 在安装瞬间均未变） | ✅ |
| **流量大数不溢出**：实测 2,496,773,389,155 字节 → 日报正确显示 `2.27 TB` | ✅ |
| **日志轮转**：`messages` ≥ 8 MB 触发 copytruncate + gzip，日报仍能读到 `messages` + `messages.old` | ✅ |
| **磁盘监控**：日报"数据盘占用"格与 ≥85% 告警逻辑 | ✅ |
| 浏览器实际渲染 + 四个按钮点击 | ⏳ **需登录 LuCI 人工过一遍**（无会话时脚本无法代测） |

> 已知的安装期踩坑（已修）：
> 1. **两个 UCI 节不能同名** —— `config report 'main'` + `config smtp 'main'` 会让整个配置文件不可解析，且 `uci -q set` 静默失败、迁移"配了等于没配"。现用 `main` / `smtp` 唯一名，并在 `install.sh` 里加了**解析自检 + 回填结果回读**。
> 2. 从 crontab 回填发送时间时未补零（`8:0`），会让页面保存时校验不通过。现用 `%02d:%02d`。
> 3. 渲染脚本每次重写 cron 会留下不再匹配的注释行，反复保存会累积。现用固定标记 `#ROUTERREPORT-CRON` 连注释一起清理。

---

## 9. 已知限制

1. 密码字符集：会过滤 `"` `\` `` ` `` `$`（这些字符会破坏 shell 引号）。QQ/163 授权码是小写字母，不受影响。
2. 只支持**单个**收件人（与现有脚本一致）。
3. 非 apk 管理：**重刷固件会丢**，`/mnt/data` 上的备份还在，重装一次即可恢复；后续打包成 `.apk` 可根治。
4. 修了密码后如果 SMTP 厂商要求"发件人=账号"，记得两处都改（发件人留空会自动用账号）。
5. 视图用原生 JS（不依赖 LuCI 的 JS 模块）；API/预览地址优先用 `build_url` 生成，**取不到就退回固定路径**，避免因一个依赖异常导致白屏。样式沿用 LuCI 的 `cbi-*` 类。

---


---

## 10. 变更记录

| 日期 | 版本 | 说明 |
|---|---|---|
| 2026-09-27 | 0.1.1 | **修复流量显示 0**（busybox awk `%d` 32 位溢出 → 改 `%.0f`）；新增 `router-logarchive` 日志真轮转；指标新增 `disk_pct`；日报增加数据盘占用与 DNS 防护拦截统计；异常白名单扩充 |
| 2026-09-26 | 0.1.0 | 首个版本：配置 + 测试发送 + 预览 + 补发；`router-daily-report` 增加 `WARN_THRESHOLD` 支持 |

---

## 11. 关于轻量

三个脚本都是**一次性执行、跑完即退**的普通 POSIX shell，没有常驻进程、没有守护线程、不引入任何运行时（Python/Node/Perl 都不需要，只用 busybox 自带的 `awk`/`sed`/`grep`/`df`）。

| 指标 | 实测 |
|---|---|
| 单次采集耗时 | ~0.02 s |
| 单次日志轮转耗时 | ~1.00 s |
| 日报生成（3.8 MB 日志） | 近瞬时 |
| 连续 30 次采集的内存增量 | +3.4 MB（页缓存，非泄漏），无累积 |
| 日志轮转后稳态占用 | < 50 MB |

设计上刻意规避了两类"监控工具常见病"：

1. **内存泄漏** —— 不写常驻循环，自然没有长生命周期的累积；`router-metrics` 每次执行都是全新进程。
2. **日志风暴** —— `router-logarchive` 负责轮转与压缩，`msmtp.log` 超 400 行自动收敛到 120 行，归档 30 天自动清理。**监控本身不会成为磁盘杀手。**

---

## 12. License

MIT License —— 见 [LICENSE](LICENSE)。
