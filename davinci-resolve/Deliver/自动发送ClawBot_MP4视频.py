#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
DaVinci Resolve 后渲染脚本：发送 MP4 渲染结果到 WeClaw Send。

本脚本只负责：
1. 从 DaVinci 后渲染环境读取 job/status/error
2. 通过 Resolve API 定位渲染输出文件
3. 调用 WeClaw Send 本地接口发送 MP4
"""

import hashlib
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

WECLAW_SEND_URL = "http://127.0.0.1:18790/send"
SEND_MODE = "mp4-video"
SEND_STATE_DIR = os.path.expanduser("~/.davinci-clawbot-postrender-state")
SEND_STATE_RETENTION_DAYS = 30
MAX_SEND_BYTES = 200 * 1024 * 1024
LOG_PATH = os.path.expanduser("~/.davinci-clawbot-postrender.log")
LOG_MAX_BYTES = 1024 * 1024
SEND_TIMEOUT_SECONDS = 900
SCRIPT_TIMEOUT_SECONDS = 1080
RENDER_STATUS_WAIT_SECONDS = 120
RENDER_STATUS_POLL_SECONDS = 2
CLAIM_LOCK_STALE_SECONDS = SCRIPT_TIMEOUT_SECONDS + 60
CURRENT_CLAIM = None


def log(message):
    print(message)
    try:
        rotate_log()
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write("[{}] {}\n".format(time.strftime("%Y-%m-%d %H:%M:%S"), message))
    except Exception:
        pass


def rotate_log():
    if not os.path.exists(LOG_PATH) or os.path.getsize(LOG_PATH) < LOG_MAX_BYTES:
        return
    rotated_path = LOG_PATH + ".1"
    if os.path.exists(rotated_path):
        os.remove(rotated_path)
    os.replace(LOG_PATH, rotated_path)


def cleanup_send_state():
    cutoff = time.time() - SEND_STATE_RETENTION_DAYS * 24 * 60 * 60
    for name in os.listdir(SEND_STATE_DIR):
        if not name.endswith(".sent"):
            continue
        path = os.path.join(SEND_STATE_DIR, name)
        try:
            if os.path.getmtime(path) < cutoff:
                os.remove(path)
        except FileNotFoundError:
            continue


def applescript_string(value):
    return '"' + str(value).replace("\\", "\\\\").replace('"', '\\"') + '"'


def notify(title, message):
    script = "display notification {} with title {}".format(
        applescript_string(message),
        applescript_string(title),
    )
    try:
        result = subprocess.run(
            ["osascript", "-e", script],
            timeout=5,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            detail = (result.stderr or result.stdout or str(result.returncode)).strip()
            log("系统通知失败: {}".format(detail))
    except subprocess.TimeoutExpired:
        log("系统通知失败: osascript 超时")


def start_watchdog():
    def watchdog():
        time.sleep(SCRIPT_TIMEOUT_SECONDS)
        message = "脚本超时 {} 秒，强制退出".format(SCRIPT_TIMEOUT_SECONDS)
        log("发送 MP4 到 WeClaw Send 失败: {}".format(message))
        if CURRENT_CLAIM is not None:
            release_send_claim(CURRENT_CLAIM)
        notify("DaVinci MP4 自动发送超时", message)
        os._exit(124)

    thread = threading.Thread(target=watchdog, daemon=True)
    thread.start()


def current_project():
    if "resolve" not in globals():
        raise RuntimeError("DaVinci Resolve API 不可用：未找到 resolve 全局变量")

    project_manager = globals()["resolve"].GetProjectManager()
    project = project_manager.GetCurrentProject()
    if project is None:
        raise RuntimeError("未找到当前项目")
    return project


def completed(status, completion):
    return status in {
        "Complete",
        "Completed",
        "RenderCompleted",
        "Success",
        "完成",
        "渲染完成",
        "成功",
        "已完成",
    } and int(completion) == 100


def failed(status):
    return status in {
        "Failed",
        "Cancelled",
        "Canceled",
        "Error",
        "失败",
        "已取消",
        "取消",
        "错误",
    }


def render_output_path(project, job_id):
    deadline = time.time() + RENDER_STATUS_WAIT_SECONDS
    while True:
        job_status = project.GetRenderJobStatus(job_id)
        if not job_status:
            raise RuntimeError("无法获取渲染任务状态: {}".format(job_id))

        status = job_status.get("JobStatus", "")
        completion = job_status.get("CompletionPercentage", 0)
        log("任务状态: {}, 完成度: {}%".format(status, completion))

        if completed(status, completion):
            break
        if failed(status):
            raise RuntimeError("渲染任务失败: {} {}%".format(status, completion))
        if time.time() >= deadline:
            raise RuntimeError("等待渲染完成超时: {} {}%".format(status, completion))

        time.sleep(RENDER_STATUS_POLL_SECONDS)

    for item in project.GetRenderJobList() or []:
        item_job_id = item.get("JobId") if isinstance(item, dict) else getattr(item, "JobId", None)
        if item_job_id != job_id:
            continue

        target_dir = item.get("TargetDir", "") if isinstance(item, dict) else getattr(item, "TargetDir", "")
        filename = item.get("OutputFilename", "") if isinstance(item, dict) else getattr(item, "OutputFilename", "")
        if not target_dir or not filename:
            raise RuntimeError("渲染任务缺少 TargetDir 或 OutputFilename")

        output = os.path.join(target_dir, filename)
        if not os.path.exists(output):
            raise RuntimeError("渲染输出文件不存在: {}".format(output))
        if os.path.getsize(output) <= 0:
            raise RuntimeError("渲染输出文件为空: {}".format(output))
        return output

    raise RuntimeError("在渲染队列中未找到任务: {}".format(job_id))


def send_fingerprint(file_path):
    stat = os.stat(file_path)
    mtime_ns = getattr(stat, "st_mtime_ns", int(stat.st_mtime * 1000000000))
    source = "{}\0{}\0{}\0{}".format(SEND_MODE, os.path.realpath(file_path), stat.st_size, mtime_ns)
    return hashlib.sha256(source.encode("utf-8")).hexdigest()


def create_claim_lock(lock_path, file_path):
    fd = os.open(lock_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        handle.write(
            "mode={}\npid={}\npath={}\ncreated_at={}\n".format(
                SEND_MODE,
                os.getpid(),
                file_path,
                int(time.time()),
            )
        )


def read_claim_lock(lock_path):
    values = {}
    with open(lock_path, "r", encoding="utf-8") as handle:
        for line in handle:
            key, _, value = line.strip().partition("=")
            if key:
                values[key] = value
    return values


def process_is_running(pid):
    result = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="],
        timeout=5,
        check=False,
        capture_output=True,
        text=True,
    )
    stat = result.stdout.strip()
    return result.returncode == 0 and stat and not stat.startswith("Z")


def claim_lock_is_stale(lock_path):
    lock_age = time.time() - os.path.getmtime(lock_path)
    if lock_age > CLAIM_LOCK_STALE_SECONDS:
        return True

    pid = read_claim_lock(lock_path).get("pid")
    if not pid:
        return False

    return not process_is_running(pid)


def verified_claim(lock_path, sent_path, file_path):
    if os.path.exists(sent_path):
        os.remove(lock_path)
        log("跳过重复发送，文件已发送: {}".format(file_path))
        return None
    return lock_path, sent_path


def claim_send(file_path):
    os.makedirs(SEND_STATE_DIR, exist_ok=True)
    cleanup_send_state()
    key = send_fingerprint(file_path)
    lock_path = os.path.join(SEND_STATE_DIR, key + ".lock")
    sent_path = os.path.join(SEND_STATE_DIR, key + ".sent")

    if os.path.exists(sent_path):
        log("跳过重复发送，文件已发送: {}".format(file_path))
        return None

    try:
        create_claim_lock(lock_path, file_path)
    except FileExistsError:
        if claim_lock_is_stale(lock_path):
            log("回收过期发送锁: {}".format(lock_path))
            os.remove(lock_path)
            try:
                create_claim_lock(lock_path, file_path)
                return verified_claim(lock_path, sent_path, file_path)
            except FileExistsError:
                log("跳过重复发送，已有脚本实例重新认领: {}".format(file_path))
                return None

        log("跳过重复发送，已有脚本实例正在处理: {}".format(file_path))
        return None

    return verified_claim(lock_path, sent_path, file_path)


def complete_send_claim(claim):
    lock_path, sent_path = claim
    os.replace(lock_path, sent_path)


def release_send_claim(claim):
    lock_path, _ = claim
    if os.path.exists(lock_path):
        os.remove(lock_path)


def format_bytes(size):
    return "{:.1f} MB".format(size / 1024 / 1024)


def send_file_too_large(file_path):
    size = os.path.getsize(file_path)
    if size <= MAX_SEND_BYTES:
        return False

    message = "文件过大，已跳过发送: {} > {}".format(format_bytes(size), format_bytes(MAX_SEND_BYTES))
    log(message)
    notify("DaVinci MP4 自动发送跳过", message)
    return True


def mp4_video_file(file_path):
    if os.path.splitext(file_path)[1].lower() != ".mp4":
        raise RuntimeError("MP4 视频版只支持 .mp4 输出: {}".format(file_path))
    return file_path, os.path.basename(file_path)


def post_to_weclaw_send(file_path, file_name):
    payload = {
        "file_path": file_path,
        "file_name": file_name,
    }
    data = json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        WECLAW_SEND_URL,
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urllib.request.urlopen(request, timeout=SEND_TIMEOUT_SECONDS) as response:
            body = response.read().decode("utf-8")
            log("WeClaw Send 响应: {}".format(body))
            result = json.loads(body)
            if not result.get("ok"):
                raise RuntimeError(result.get("error", body))
            return result
    except urllib.error.HTTPError as error:
        body = error.read().decode("utf-8")
        raise RuntimeError("WeClaw Send HTTP {}: {}".format(error.code, body))
    except urllib.error.URLError as error:
        raise RuntimeError("无法连接 WeClaw Send: {}".format(error))


def main():
    global CURRENT_CLAIM

    start_watchdog()
    log("DaVinci MP4 自动发送到 WeClaw Send 启动")

    job_id = globals().get("job")
    if not job_id:
        raise RuntimeError("未找到 DaVinci 后渲染 job 变量")

    if globals().get("error"):
        raise RuntimeError("DaVinci 渲染错误: {}".format(globals().get("error")))

    project = current_project()
    file_path = render_output_path(project, job_id)
    log("输出文件: {}".format(file_path))

    claim = claim_send(file_path)
    if claim is None:
        return

    CURRENT_CLAIM = claim
    try:
        if send_file_too_large(file_path):
            complete_send_claim(claim)
            CURRENT_CLAIM = None
            return

        send_path, send_name = mp4_video_file(file_path)
        log("发送用 MP4 视频文件: {}".format(send_path))
        result = post_to_weclaw_send(send_path, send_name)
        complete_send_claim(claim)
        CURRENT_CLAIM = None
    except Exception:
        release_send_claim(claim)
        CURRENT_CLAIM = None
        raise

    log("WeClaw Send MP4 发送完成: {}".format(result.get("status", "sent")))
    notify("DaVinci MP4 自动发送完成", send_name)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        log("发送 MP4 到 WeClaw Send 失败: {}".format(exc))
        notify("DaVinci MP4 自动发送失败", str(exc))
        sys.exit(1)
