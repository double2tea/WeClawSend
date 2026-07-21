--[[
  DaVinci Resolve 后渲染脚本（Lua 版）：WeClawSend_Lua

  不依赖 Python。通过 macOS 自带 /usr/bin/curl 请求 WeClaw Send 本地接口。
  适用于：Resolve 只枚举 Lua、或本机未装/未接入 Python 的环境。

  MP4/M4V 显示名由 App「发送时 .mp4 显示为 .m4v」处理。
]]

local WECLAW_SEND_URL = "http://127.0.0.1:18790/send"
local WECLAW_HEALTH_URL = "http://127.0.0.1:18790/health"
local SEND_STATE_DIR = os.getenv("HOME") .. "/.davinci-clawbot-postrender-state"
local LOG_PATH = os.getenv("HOME") .. "/.davinci-clawbot-postrender.log"
local CURL = "/usr/bin/curl"
local HEALTH_TIMEOUT_SECONDS = 3
local SEND_TIMEOUT_SECONDS = 900
local RENDER_STATUS_WAIT_SECONDS = 120
local RENDER_STATUS_POLL_SECONDS = 2

-- Resolve may inject a global named `error`; never call it as a function.
local function raise(message)
    assert(false, tostring(message))
end

local function shell_quote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

local function log(message)
    print(message)
    local handle = io.open(LOG_PATH, "a")
    if handle then
        handle:write(string.format("[%s] %s\n", os.date("%Y-%m-%d %H:%M:%S"), tostring(message)))
        handle:close()
    end
end

local function notify(title, message)
    local script = string.format(
        "display notification %s with title %s",
        shell_quote(message),
        shell_quote(title)
    )
    os.execute("/usr/bin/osascript -e " .. shell_quote(script) .. " >/dev/null 2>&1")
end

local function is_completed(status, completion)
    local done = {
        Complete = true,
        Completed = true,
        RenderCompleted = true,
        Success = true,
        ["完成"] = true,
        ["渲染完成"] = true,
        ["成功"] = true,
        ["已完成"] = true,
    }
    if done[tostring(status)] == true then
        local n = tonumber(completion)
        return n == nil or n >= 100
    end
    return false
end

local function is_failed(status)
    local bad = {
        Failed = true,
        Cancelled = true,
        Canceled = true,
        Error = true,
        ["失败"] = true,
        ["已取消"] = true,
        ["取消"] = true,
        ["错误"] = true,
    }
    return bad[tostring(status)] == true
end

local function current_project()
    if type(resolve) == "nil" then
        raise("DaVinci Resolve API 不可用：未找到 resolve 全局变量")
    end
    local project_manager = resolve:GetProjectManager()
    local project = project_manager:GetCurrentProject()
    if project == nil then
        raise("未找到当前项目")
    end
    return project
end

local function render_output_path(project, job_id)
    local deadline = os.time() + RENDER_STATUS_WAIT_SECONDS
    while true do
        local job_status = project:GetRenderJobStatus(job_id)
        if type(job_status) ~= "table" then
            raise("无法获取渲染任务状态: " .. tostring(job_id))
        end

        local status_text = job_status.JobStatus or ""
        local completion = job_status.CompletionPercentage or 0
        log(string.format("任务状态: %s, 完成度: %s%%", tostring(status_text), tostring(completion)))

        if is_completed(status_text, completion) then
            break
        end
        if is_failed(status_text) then
            raise(string.format("渲染任务失败: %s %s%%", tostring(status_text), tostring(completion)))
        end
        if os.time() >= deadline then
            raise(string.format("等待渲染完成超时: %s %s%%", tostring(status_text), tostring(completion)))
        end

        os.execute("sleep " .. tostring(RENDER_STATUS_POLL_SECONDS))
    end

    local jobs = project:GetRenderJobList() or {}
    for _, item in ipairs(jobs) do
        if tostring(item.JobId) == tostring(job_id) then
            local target_dir = item.TargetDir or ""
            local filename = item.OutputFilename or ""
            if target_dir == "" or filename == "" then
                raise("渲染任务缺少 TargetDir 或 OutputFilename")
            end
            if target_dir:sub(-1) == "/" or target_dir:sub(-1) == "\\" then
                return target_dir .. filename
            end
            local separator = "/"
            if target_dir:find("\\") and not target_dir:find("/") then
                separator = "\\"
            end
            return target_dir .. separator .. filename
        end
    end

    raise("在渲染队列中未找到任务: " .. tostring(job_id))
end

local function file_exists(path)
    local handle = io.open(path, "rb")
    if not handle then
        return false, 0
    end
    local size = handle:seek("end")
    handle:close()
    return true, size or 0
end

local function ensure_state_dir()
    os.execute("/bin/mkdir -p " .. shell_quote(SEND_STATE_DIR))
end

local function simple_hash(text)
    local h1, h2 = 2166136261, 0
    for i = 1, #text do
        local b = text:byte(i)
        h1 = (h1 * 16777619 + b) % 4294967296
        h2 = (h2 * 33 + b) % 4294967296
    end
    return string.format("%08x%08x", h1, h2)
end

local function claim_paths(file_path, size)
    ensure_state_dir()
    local key = simple_hash("file\0" .. file_path .. "\0" .. tostring(size))
    return SEND_STATE_DIR .. "/" .. key .. ".lock", SEND_STATE_DIR .. "/" .. key .. ".sent"
end

local function claim_send(file_path, size)
    local lock_path, sent_path = claim_paths(file_path, size)
    local sent = io.open(sent_path, "r")
    if sent then
        sent:close()
        log("跳过重复发送，文件已发送: " .. file_path)
        return nil, nil
    end

    local lock = io.open(lock_path, "r")
    if lock then
        lock:close()
        log("跳过重复发送，已有脚本实例正在处理: " .. file_path)
        return nil, nil
    end

    local created = io.open(lock_path, "w")
    if not created then
        raise("无法创建发送锁: " .. lock_path)
    end
    created:write("path=" .. file_path .. "\ncreated_at=" .. tostring(os.time()) .. "\n")
    created:close()
    return lock_path, sent_path
end

local function complete_claim(lock_path, sent_path)
    os.rename(lock_path, sent_path)
end

local function release_claim(lock_path)
    if lock_path then
        os.remove(lock_path)
    end
end

local function run_curl(args)
    local command = CURL .. " " .. table.concat(args, " ")
    local handle = io.popen(command .. " 2>&1; printf '\\n__EXIT__%s' $?", "r")
    if handle == nil then
        raise("无法启动 curl")
    end
    local output = handle:read("*a") or ""
    handle:close()
    local exit_code = tonumber(output:match("__EXIT__(%d+)%s*$") or "")
    local body = output:gsub("\n?__EXIT__%d+%s*$", "")
    return exit_code, body
end

local function current_max_send_bytes()
    local code, body = run_curl({
        "-sS",
        "--max-time",
        tostring(HEALTH_TIMEOUT_SECONDS),
        shell_quote(WECLAW_HEALTH_URL),
    })
    if code ~= 0 then
        raise("无法连接 WeClaw Send: curl 退出码 " .. tostring(code) .. " " .. tostring(body))
    end
    local max_bytes = body:match('"max_send_bytes"%s*:%s*(%d+)')
    if not max_bytes then
        raise("WeClaw Send 未返回有效的文件大小上限: " .. tostring(body))
    end
    return tonumber(max_bytes)
end

local function format_bytes(size)
    return string.format("%.1f MB", size / 1024 / 1024)
end

local function json_escape(value)
    return tostring(value)
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
end

local function post_to_weclaw_send(file_path, file_name)
    local payload = string.format(
        '{"file_path":"%s","file_name":"%s"}',
        json_escape(file_path),
        json_escape(file_name)
    )
    local code, body = run_curl({
        "-sS",
        "--max-time",
        tostring(SEND_TIMEOUT_SECONDS),
        "-X",
        "POST",
        "-H",
        shell_quote("Content-Type: application/json"),
        "-d",
        shell_quote(payload),
        shell_quote(WECLAW_SEND_URL),
    })
    log("WeClaw Send 响应: " .. tostring(body))
    if code ~= 0 then
        raise("无法连接 WeClaw Send: curl 退出码 " .. tostring(code) .. " " .. tostring(body))
    end
    if body:find('"ok"%s*:%s*false') or (not body:find('"ok"%s*:%s*true') and body:find('"error"')) then
        local err = body:match('"error"%s*:%s*"(.-)"') or body
        raise(tostring(err))
    end
    if not body:find('"ok"%s*:%s*true') then
        raise("WeClaw Send 响应异常: " .. tostring(body))
    end
    return body
end

local function run()
    log("DaVinci 自动发送到 WeClaw Send 启动（Lua 版）")

    if type(job) == "nil" or job == "" then
        raise("未找到 DaVinci 后渲染 job 变量")
    end

    local render_error = rawget(_G, "error")
    if type(render_error) == "string" and render_error ~= "" then
        raise("DaVinci 渲染错误: " .. render_error)
    end

    local project = current_project()
    local file_path = render_output_path(project, job)
    local exists, size = file_exists(file_path)
    if not exists then
        raise("渲染输出文件不存在: " .. tostring(file_path))
    end
    if size <= 0 then
        raise("渲染输出文件为空: " .. tostring(file_path))
    end

    local send_name = file_path:match("([^/\\]+)$") or file_path
    log("输出文件: " .. tostring(file_path))

    local lock_path, sent_path = claim_send(file_path, size)
    if lock_path == nil then
        return
    end

    local ok, err = pcall(function()
        local max_send_bytes = current_max_send_bytes()
        if size > max_send_bytes then
            local message = string.format(
                "文件过大，已跳过发送: %s > %s",
                format_bytes(size),
                format_bytes(max_send_bytes)
            )
            log(message)
            notify("DaVinci 自动发送跳过", message)
            release_claim(lock_path)
            return
        end

        post_to_weclaw_send(file_path, send_name)
        complete_claim(lock_path, sent_path)
        log("WeClaw Send 发送完成")
        notify("DaVinci 自动发送完成", send_name)
    end)

    if not ok then
        release_claim(lock_path)
        raise(err)
    end
end

local ok, err = pcall(run)
if not ok then
    log("发送到 WeClaw Send 失败: " .. tostring(err))
    notify("DaVinci 自动发送失败", tostring(err))
    raise(err)
end
