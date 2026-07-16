# WeClaw Send for Premiere Pro 25+

这是项目唯一维护的 Premiere 插件：**CEP 12 面板**。不需要 UXP Developer Tool。

## 前置条件

- macOS 14+
- Premiere Pro 25+（manifest 覆盖 25.0–99.9）
- 已安装并登录 WeClaw Send

自动导出必须使用 Adobe `.epr` 预设，因为 Premiere 的脚本导出接口要求用预设确定格式、编码器和扩展名。面板会自动扫描并记住预设、输出文件夹和自动发送开关，不需要手动寻找 `.epr` 文件。

## 安装

双击 `安装.command`。安装程序会：

1. 把面板复制到 `~/Library/Application Support/Adobe/CEP/extensions`
2. 为 CEP 12 开启未签名本地扩展加载

安装后重新打开 Premiere，在 **窗口 → 扩展 → WeClaw Send** 打开面板。

## 使用

1. 在 WeClaw Send 的设置中开启「本地接口」。
2. 在 Premiere 打开一个序列。
3. 从面板内可搜索、可滚动的「我的预设」或「Premiere 系统预设」列表选择导出预设，再选择输出文件夹。
4. 选择「完整序列」或「入点到出点（I/O）」；I/O 未设置或范围无效时会在导出前提示。
5. 输入不含扩展名的文件名。面板重新获得焦点时会同步当前序列名；手动修改过的文件名不会被覆盖。
6. 按需开启「导出完成后自动发送」，然后点击导出。

关闭自动发送时，面板只导出；开启时，面板会先检查本机接口，导出成功后再在后台发送到微信。渲染完成后可立即切换序列继续导出；一个或多个发送失败时可逐个直接重试发送，不会重复渲染。导出文件不会覆盖同名文件，完成后可从面板在 Finder 中显示。导出由 Premiere 直接执行，不依赖 Adobe Media Encoder。

需要修改码率、分辨率等参数时，在 Premiere 原生导出页调整并保存为预设，再回到面板点击「刷新」。面板扫描：

- `~/Documents/Adobe/Adobe Media Encoder/` 下所有 25+ 版本中的用户预设
- 所有已安装 Premiere Pro 25+ 的内置系统预设（自动排除内部 `SequencePreview` 预设）

## 开发验证

```sh
node --test tests/protocol.test.js
../scripts/install-premiere-plugin.sh
```
