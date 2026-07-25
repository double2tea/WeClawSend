-- Read-only diagnostic for Resolve Deliver render-trigger globals.
-- The bootstrap namespace is copied before this script defines its own values.

local BOOTSTRAP_GLOBALS = {}
for key, value in pairs(_G) do
    BOOTSTRAP_GLOBALS[key] = value
end

local LOG_PATH = os.getenv("HOME") .. "/.davinci-clawbot-trigger-probe.log"
local CANDIDATES = {
    "job",
    "jobId",
    "jobID",
    "renderJob",
    "render_job",
    "renderJobId",
    "render_job_id",
    "status",
    "error",
    "resolve",
    "project",
    "timeline",
}

local function safe_value(value)
    local value_type = type(value)
    if value == nil then
        return ""
    end
    if value_type == "string" or value_type == "number" or value_type == "boolean" then
        local text = tostring(value):gsub("\n", "\\n"):gsub("\r", "\\r")
        return text:sub(1, 500)
    end
    return ""
end

local function describe(name)
    if BOOTSTRAP_GLOBALS[name] == nil then
        return name .. "=missing"
    end
    local value = BOOTSTRAP_GLOBALS[name]
    local text = name .. "=type:" .. type(value)
    local value_text = safe_value(value)
    if value_text ~= "" then
        text = text .. ",value:" .. value_text
    end
    return text
end

local function write_line(message)
    local line = string.format("[%s] %s", os.date("%Y-%m-%dT%H:%M:%S%z"), message)
    print(line)
    local handle = io.open(LOG_PATH, "a")
    if handle then
        handle:write(line .. "\n")
        handle:close()
    end
end

local function resolve_summary(resolve_handle)
    if resolve_handle == nil then
        write_line("resolve_api=missing")
        return
    end

    local version_ok, version = pcall(function()
        return resolve_handle:GetVersionString()
    end)
    if version_ok then
        write_line("resolve_version=" .. tostring(version))
    else
        write_line("resolve_version_error=" .. tostring(version))
    end

    local api_ok, api_error = pcall(function()
        local project_manager = resolve_handle:GetProjectManager()
        local project = project_manager:GetCurrentProject()
        if project == nil then
            write_line("resolve_project=missing")
            return
        end
        write_line("resolve_project=" .. tostring(project:GetName()))
        local jobs = project:GetRenderJobList() or {}
        local count = 0
        for _, item in ipairs(jobs) do
            count = count + 1
            local job_id = item.JobId
            local status = ""
            if job_id ~= nil then
                local status_ok, status_value = pcall(function()
                    return project:GetRenderJobStatus(job_id)
                end)
                status = status_ok and tostring(status_value.JobStatus or "") or "status_error"
            end
            write_line(string.format(
                "render_job[%d]=id:%s,name:%s,timeline:%s,target:%s,output:%s,status:%s",
                count,
                safe_value(job_id),
                safe_value(item.RenderJobName),
                safe_value(item.TimelineName),
                safe_value(item.TargetDir),
                safe_value(item.OutputFilename),
                status
            ))
        end
        write_line("render_job_count=" .. tostring(count))
    end)
    if not api_ok then
        write_line("resolve_api_error=" .. tostring(api_error))
    end
end

local function run()
    local keys = {}
    for key, _ in pairs(BOOTSTRAP_GLOBALS) do
        if type(key) == "string" and not key:match("^__") then
            table.insert(keys, key)
        end
    end
    table.sort(keys)
    write_line("language=lua")
    write_line("bootstrap_keys=" .. table.concat(keys, ","))
    for _, name in ipairs(CANDIDATES) do
        write_line(describe(name))
    end
    resolve_summary(BOOTSTRAP_GLOBALS.resolve)
end

local ok, error_message = pcall(run)
if not ok then
    write_line("fatal_error=" .. tostring(error_message))
end
