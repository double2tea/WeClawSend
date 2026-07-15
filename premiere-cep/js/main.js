(function () {
  "use strict";

  var AUTO_SEND_STORAGE_KEY = "autoSendAfterExport";
  var cep = window.__adobe_cep__;
  var protocol = window.WeClawProtocol;
  var selectedPreset = "";
  var selectedFolder = "";
  var exporting = false;
  var shouldSendAfterExport = false;

  var sequenceName = requiredElement("sequence-name");
  var presetPath = requiredElement("preset-path");
  var folderPath = requiredElement("folder-path");
  var outputName = requiredElement("output-name");
  var autoSend = requiredElement("auto-send");
  var choosePreset = requiredElement("choose-preset");
  var chooseFolder = requiredElement("choose-folder");
  var refreshSequence = requiredElement("refresh-sequence");
  var exportButton = requiredElement("export");
  var status = requiredElement("status");

  if (!cep) {
    setStatus("此面板必须在 Premiere Pro 中运行", "error");
    setBusy(true);
    return;
  }

  autoSend.checked = localStorage.getItem(AUTO_SEND_STORAGE_KEY) === "true";
  updateExportButtonLabel();
  applyHostTheme();

  autoSend.addEventListener("change", function () {
    localStorage.setItem(AUTO_SEND_STORAGE_KEY, String(autoSend.checked));
    updateExportButtonLabel();
  });
  choosePreset.addEventListener("click", selectPreset);
  chooseFolder.addEventListener("click", selectFolder);
  refreshSequence.addEventListener("click", function () { loadActiveSequence(true); });
  exportButton.addEventListener("click", startExport);
  cep.addEventListener("com.adobe.csxs.events.ThemeColorChanged", applyHostTheme);

  loadActiveSequence(false);

  function selectPreset() {
    callHost("choosePreset", [], function (reply) {
      if (reply.status === "CANCEL") { return; }
      selectedPreset = reply.detail;
      presetPath.textContent = selectedPreset;
      setStatus("已选择导出预设", "neutral");
    });
  }

  function selectFolder() {
    callHost("chooseFolder", [], function (reply) {
      if (reply.status === "CANCEL") { return; }
      selectedFolder = reply.detail;
      folderPath.textContent = selectedFolder;
      setStatus("已选择输出位置", "neutral");
    });
  }

  function loadActiveSequence(replaceOutputName) {
    callHost("activeSequenceName", [], function (reply) {
      sequenceName.textContent = reply.detail;
      if (replaceOutputName || outputName.value.trim().length === 0) {
        outputName.value = reply.detail;
      }
    });
  }

  function startExport() {
    if (exporting) {
      reportError(new Error("已有导出任务正在进行"));
      return;
    }
    if (!selectedPreset) {
      reportError(new Error("请选择 Adobe .epr 导出预设"));
      return;
    }
    if (!selectedFolder) {
      reportError(new Error("请选择输出位置"));
      return;
    }

    var name;
    try {
      name = protocol.validateOutputName(outputName.value);
    } catch (error) {
      reportError(error);
      return;
    }

    exporting = true;
    shouldSendAfterExport = autoSend.checked;
    setBusy(true);
    setStatus("正在由 Premiere 导出…", "neutral");
    callHost("exportSequence", [selectedPreset, selectedFolder, name], function (reply) {
      if (!shouldSendAfterExport) {
        finish("导出完成", "success");
        return;
      }
      setStatus("导出完成，正在发送到微信…", "neutral");
      sendFile(reply.detail).then(function () {
        finish("导出并发送完成", "success");
      }).catch(finishWithError);
    }, function (error) {
      finishWithError(error);
    });
  }

  function sendFile(filePath) {
    if (!window.cep_node || typeof window.cep_node.require !== "function") {
      return Promise.reject(new Error("CEP 12 的 Node.js 接口不可用"));
    }
    var http = window.cep_node.require("http");
    var body = JSON.stringify({
      file_path: filePath,
      file_name: filePath.split("/").pop()
    });

    return new Promise(function (resolve, reject) {
      var request = http.request({
        hostname: "127.0.0.1",
        port: 18790,
        path: "/send",
        method: "POST",
        headers: {
          "Content-Type": "application/json; charset=utf-8",
          "Content-Length": window.cep_node.Buffer.byteLength(body)
        }
      }, function (response) {
        var chunks = [];
        response.on("data", function (chunk) { chunks.push(chunk); });
        response.on("end", function () {
          var text = window.cep_node.Buffer.concat(chunks).toString("utf8");
          var payload;
          try {
            payload = JSON.parse(text);
          } catch (_) {
            reject(new Error("WeClaw Send 返回了无效响应"));
            return;
          }
          if (response.statusCode !== 200 || payload.ok !== true) {
            reject(new Error(payload.error || "WeClaw Send 发送失败"));
            return;
          }
          resolve(payload);
        });
      });

      request.setTimeout(300000, function () {
        request.destroy(new Error("发送等待超过 5 分钟"));
      });
      request.on("error", function (error) {
        if (error && error.code === "ECONNREFUSED") {
          reject(new Error("请启动 WeClaw Send，并在设置中开启本地接口"));
          return;
        }
        reject(error);
      });
      request.end(body);
    });
  }

  function callHost(method, args, onSuccess, onFailure) {
    var expression = "$._WECLAW." + method + "(" + args.map(JSON.stringify).join(",") + ")";
    cep.evalScript(expression, function (value) {
      try {
        onSuccess(protocol.parseHostReply(value));
      } catch (error) {
        (onFailure || reportError)(error);
      }
    });
  }

  function applyHostTheme() {
    try {
      var environment = JSON.parse(cep.getHostEnvironment());
      var color = environment.appSkinInfo.panelBackgroundColor.color;
      var luminance = (color.red * 299 + color.green * 587 + color.blue * 114) / 1000;
      document.documentElement.setAttribute("data-theme", luminance > 150 ? "light" : "dark");
    } catch (error) {
      reportError(error);
    }
  }

  function finish(message, kind) {
    exporting = false;
    shouldSendAfterExport = false;
    setBusy(false);
    setStatus(message, kind);
  }

  function finishWithError(error) {
    finish(error instanceof Error ? error.message : String(error), "error");
  }

  function reportError(error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
  }

  function setBusy(value) {
    choosePreset.disabled = value;
    chooseFolder.disabled = value;
    refreshSequence.disabled = value;
    exportButton.disabled = value;
    outputName.disabled = value;
    autoSend.disabled = value;
  }

  function updateExportButtonLabel() {
    exportButton.textContent = autoSend.checked ? "导出并自动发送" : "导出";
  }

  function setStatus(message, kind) {
    status.textContent = message;
    status.className = "status" + (kind === "neutral" ? "" : " " + kind);
  }

  function requiredElement(id) {
    var element = document.getElementById(id);
    if (!element) {
      throw new Error("缺少界面元素：" + id);
    }
    return element;
  }
})();
