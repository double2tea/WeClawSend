# WeClaw Send for Premiere Pro 25.3

这是项目唯一维护的 Premiere 插件：**CEP 12 面板**。不需要 UXP Developer Tool。

## 前置条件

- macOS 14+
- Premiere Pro 2025 25.0–25.5（已针对 25.3 验证）
- 已安装并登录 WeClaw Send

自动导出必须使用 Adobe `.epr` 预设，因为 Premiere 的脚本导出接口要求用预设确定格式、编码器和扩展名。面板会自动扫描并记住选择，不需要手动寻找 `.epr` 文件。

## 安装

双击 `安装.command`。安装程序会：

1. 把面板复制到 `~/Library/Application Support/Adobe/CEP/extensions`
2. 为 CEP 12 开启未签名本地扩展加载

安装后重新打开 Premiere，在 **窗口 → 扩展 → WeClaw Send** 打开面板。

## 使用

1. 在 WeClaw Send 的设置中开启「本地接口」。
2. 在 Premiere 打开一个序列。
3. 从面板内可搜索、可滚动的「我的预设」或「Premiere 系统预设」列表选择导出预设，再选择输出文件夹。
4. 输入不含扩展名的文件名。
5. 按需开启「导出完成后自动发送」，然后点击导出。

关闭自动发送时，面板只导出；开启时，导出成功后会通过本机接口发送到微信。导出由 Premiere 直接执行，不依赖 Adobe Media Encoder。

需要修改码率、分辨率等参数时，在 Premiere 原生导出页调整并保存为预设，再回到面板点击「刷新」。面板扫描：

- `~/Documents/Adobe/Adobe Media Encoder/25.0/Presets` 中的用户预设
- Premiere Pro 2025 内置系统预设（自动排除内部 `SequencePreview` 预设）

## 开发验证

```sh
node --test tests/protocol.test.js
../scripts/install-premiere-plugin.sh
```
