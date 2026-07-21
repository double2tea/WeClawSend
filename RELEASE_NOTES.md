# v1.7.1

- 设置页为 Premiere 插件与 DaVinci 脚本增加「卸载」。
- DaVinci 旁增加 Python 3 检测、「重新检测」与「安装指南」（打开官网 / 复制 Homebrew 安装命令）。
- App 只引导安装 Python，不会替你安装或卸载系统 / Homebrew Python，避免误清环境。
- 完善 README、使用说明与 DaVinci 文档中的完整 Python 安装步骤：检查 `python3 --version`、Homebrew（含首次安装 Homebrew）与官方安装包；推荐 3.11/3.12。
- 使用说明补充自行卸载 Python 的方式：Homebrew `brew uninstall` 与官网安装包清理路径，并明确不要删除 macOS 自带 `/usr/bin/python3`。

# v1.7.0

- DaVinci Resolve 脚本安装后会校验目标文件是否真实存在，避免“显示成功但目录为空”。
- 设置页安装成功后展示用户 Deliver 路径，并支持“显示路径”在 Finder 中打开。
- 使用说明补充 Python 3.6+ 要求、官方/Homebrew 安装方式，以及安装后必须彻底重启 Resolve。
- 明确脚本安装到当前用户目录，并补充下拉只有“无”时的排查步骤。

# v1.6.11

- 微信独立登录改为三个明确步骤：扫码确认、在 ClawBot 发送消息完成会话绑定、连接完成。
- 只有取得可发送文件的微信会话后才显示“已连接”，不再把扫码成功误认为全部完成。
- 发现新版本时会显示更新内容小弹窗；关闭后当前版本不再重复提醒。
- Release 现在强制携带对应版本的中文更新说明。
