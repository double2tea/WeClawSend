<p align="center">
  <img src="Resources/brand-mark-1024.png" width="104" alt="WeClaw Send 图标">
</p>

<h1 align="center">WeClaw Send</h1>

<p align="center"><strong>把 Mac、Premiere 和 DaVinci 的文件直接发到微信。</strong></p>

<p align="center">原生 macOS 菜单栏应用 · 无需 WeClaw、OpenClaw、Node 或 Go 后台</p>

<p align="center">
  <a href="https://github.com/double2tea/WeClawSend/releases">下载最新版</a> ·
  <a href="docs/使用说明.md">使用说明</a> ·
  <a href="docs/INTEGRATION.md">本地接口</a>
</p>

## 界面

<p align="center">
  <img src="docs/images/app-main.png" width="48%" alt="WeClaw Send 主面板：选择文件与查看最近传输">
  <img src="docs/images/app-settings.png" width="48%" alt="WeClaw Send 设置页：在线更新与 Premiere、DaVinci 集成">
</p>

## 安装

1. 从 [Releases](https://github.com/double2tea/WeClawSend/releases) 下载 DMG 或 ZIP，把 App 放进“应用程序”。
2. 点击菜单栏纸飞机，在设置中扫码登录微信。
3. 拖入文件，或点击面板选择文件。

项目没有 Apple Developer ID，发布包使用 ad-hoc 签名。第一次打开若被系统拦截，请在“系统设置 → 隐私与安全性”中选择“仍要打开”。

完整步骤与常见问题见 [使用说明](docs/使用说明.md)。App 和编辑器组件都可以在设置页检查更新。

## 发送

- 拖放或多选文件，最多同时处理 3 个任务
- 显示准备、加密、上传和发送进度；支持取消与失败重试
- 保留最近 20 条记录
- 可将微信里的 `.mp4` 附件名显示为 `.m4v`，不修改本地文件
- 支持登录时启动；空闲 30 秒后自动收起

单个文件最大 200 MB。文件可以并行准备，但微信消息会按顺序提交，相邻两条至少间隔 2 秒。

## 隐私

WeClaw Send 不设自有云端存储，不会向开发者上传文件或账号信息。文件仅通过微信官方 ClawBot API 发送至用户本人的微信 ClawBot；登录凭据、偏好设置和传输记录仅保存在本机。

## Premiere 与 DaVinci

### Premiere Pro

插件支持 Premiere Pro 25、26；后续版本只要继续支持 CEP，也可以直接使用。

- 自动使用当前序列名，可选择完整序列或 I/O 范围
- 使用 Adobe 导出预设，并记住预设、输出文件夹与自动发送开关
- 导出完成后即可继续操作其他序列，发送在后台进行
- 发送失败时保留成片，只重试发送，不重新渲染

在 App 设置中一键安装，重启 Premiere 后从“窗口 → 扩展 → WeClaw Send”打开。自动发送需要开启“本地接口”。

更多说明见 [Premiere 插件文档](premiere-cep/README.md)。

### DaVinci Resolve

Deliver 后渲染脚本会在渲染完成后自动发送成片，可选择 `.m4v` 文件或 `.mp4` 视频模式。在 App 设置中一键安装，并开启“本地接口”即可使用。

手动安装、日志和发送模式见 [DaVinci 插件文档](davinci-resolve/README.md)。

## 微信会话限制

微信 iLink 会限制主动发送的会话窗口和消息额度。遇到 `ret=-2` 时，App 会提示你给 ClawBot 发一条消息；收到新上下文后自动续传，不需要重新选择文件。

刷新通知会自行淡出。如果 5 分钟内没有收到新消息，任务会结束并显示失败。相关背景见 [会话限制反馈](https://github.com/Tencent/openclaw-weixin/issues/202) 和 [`ret=-2` 反馈](https://github.com/Tencent/openclaw-weixin/issues/225)。

## 给本机脚本调用

菜单栏发送不需要本地接口。Premiere、DaVinci 和本机自动化需要在设置中开启它。接口只监听 `127.0.0.1:18790`，不会向局域网开放。

调用示例、字段和错误码见 [集成文档](docs/INTEGRATION.md)。

## 本地开发

<details>
<summary>构建、测试与发布</summary>

需要 macOS 14+ 与 Swift 工具链。

```sh
chmod +x scripts/*.sh
./scripts/install.sh
```

```sh
./scripts/test.sh
./scripts/build-app.sh
./scripts/functional-test.sh
./scripts/release.sh
```

`release.sh` 会生成通用 App 和发布附件。App、Premiere 与 DaVinci 可以独立升级；推送 `v*` 标签后，GitHub Actions 会自动创建 Release。

</details>

## 许可证

WeClaw Send 基于 [MIT License](LICENSE) 开源。第三方组件的许可信息见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。

## 联系

- [GitHub](https://github.com/double2tea/WeClawSend)
- [作品集](https://zeezhi.pages.dev/)
- [double_tea@foxmail.com](mailto:double_tea@foxmail.com)

微信 iLink 协议实现参考腾讯 [openclaw-weixin](https://github.com/Tencent/openclaw-weixin)（MIT），许可说明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
