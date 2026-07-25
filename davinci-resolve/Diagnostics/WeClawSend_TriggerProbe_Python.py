#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Read-only diagnostic for Resolve Deliver render-trigger globals.

Resolve injects the render context before evaluating a Deliver trigger script.
Capture that bootstrap namespace before this file defines anything of its own,
then record only names/types and read-only render-queue metadata.
"""

from __future__ import print_function

import json
import os
import re
import time
import traceback


_BOOTSTRAP_GLOBALS = dict(globals())
LOG_PATH = os.path.expanduser("~/.davinci-clawbot-trigger-probe.log")
_CANDIDATES = (
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
)


def _safe_value(value):
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        return value[:500]
    return None


def _describe(value):
    result = {"type": type(value).__name__}
    safe_value = _safe_value(value)
    if safe_value is not None:
        result["value"] = safe_value
    return result


def _append(record):
    line = json.dumps(record, ensure_ascii=False, sort_keys=True)
    print(line)
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")
    except Exception as exc:
        print("probe log write failed: {}".format(exc))


def _job_field(item, key):
    if isinstance(item, dict):
        return item.get(key)
    return getattr(item, key, None)


def _resolve_summary(resolve_handle):
    if resolve_handle is None:
        return {"available": False}

    summary = {"available": True}
    try:
        summary["version"] = resolve_handle.GetVersionString()
    except Exception as exc:
        summary["version_error"] = str(exc)

    try:
        project_manager = resolve_handle.GetProjectManager()
        project = project_manager.GetCurrentProject()
        summary["project"] = project.GetName() if project is not None else None
        jobs = project.GetRenderJobList() if project is not None else []
        summary["jobs"] = []
        for item in jobs or []:
            job_id = _job_field(item, "JobId")
            job_summary = {
                "JobId": _safe_value(job_id),
                "RenderJobName": _safe_value(_job_field(item, "RenderJobName")),
                "TimelineName": _safe_value(_job_field(item, "TimelineName")),
                "TargetDir": _safe_value(_job_field(item, "TargetDir")),
                "OutputFilename": _safe_value(_job_field(item, "OutputFilename")),
            }
            if job_id is not None and project is not None:
                try:
                    job_summary["status"] = project.GetRenderJobStatus(job_id)
                except Exception as exc:
                    job_summary["status_error"] = str(exc)
            summary["jobs"].append(job_summary)
    except Exception as exc:
        summary["api_error"] = str(exc)
    return summary


def main():
    bootstrap_keys = sorted(
        key for key in _BOOTSTRAP_GLOBALS
        if isinstance(key, str) and not key.startswith("__")
    )
    interesting_keys = [
        key for key in bootstrap_keys
        if re.search(r"job|status|error|render|resolve", key, re.IGNORECASE)
    ]
    injected = {}
    for key in _CANDIDATES:
        injected[key] = (
            {"present": False}
            if key not in _BOOTSTRAP_GLOBALS
            else {"present": True, **_describe(_BOOTSTRAP_GLOBALS[key])}
        )

    _append(
        {
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "language": "python",
            "bootstrap_keys": bootstrap_keys,
            "interesting_keys": interesting_keys,
            "injected": injected,
            "resolve": _resolve_summary(_BOOTSTRAP_GLOBALS.get("resolve")),
        }
    )


if __name__ == "__main__":
    try:
        main()
    except Exception:
        _append(
            {
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
                "language": "python",
                "fatal_error": traceback.format_exc(),
            }
        )
