# Resolve Deliver 触发上下文诊断

这两个脚本只读取 Resolve 的后渲染触发上下文和渲染队列，不发送文件、不修改项目：

- `WeClawSend_TriggerProbe_Lua.lua`
- `WeClawSend_TriggerProbe_Python.py`

将其中一个安装到 Resolve 的 `Deliver` 脚本目录后，在 Deliver 的“在渲染作业结束时触发脚本”中选择对应入口。只用一个很短的测试渲染，并从 Deliver 页面执行渲染，不要从 Workspace → Scripts 手动运行。

诊断结果写入：

```text
~/.davinci-clawbot-trigger-probe.log
```

测试完成后切回 `WeClawSend_Lua` 或 `WeClawSend_Python`。诊断脚本不会调用 WeClaw Send。
