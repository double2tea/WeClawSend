(function () {
  "use strict";

  var AUTO_SEND_STORAGE_KEY = "autoSendAfterExport";
  var PRESET_STORAGE_KEY = "selectedExportPreset";
  var FOLDER_STORAGE_KEY = "selectedOutputFolder";
  var cep = window.__adobe_cep__;
  var protocol = window.WeClawProtocol;
  var presetLibrary = window.WeClawPresetLibrary;
  var selectedFolder = "";
  var selectedPresetPath = "";
  var presetGroups = { user: [], system: [] };
  var exporting = false;
  var shouldSendAfterExport = false;

  var sequenceName = requiredElement("sequence-name");
  var presetPicker = requiredElement("preset-picker");
  var presetTrigger = requiredElement("preset-trigger");
  var presetValue = requiredElement("preset-value");
  var presetMenu = requiredElement("preset-menu");
  var presetSearch = requiredElement("preset-search");
  var presetOptions = requiredElement("preset-options");
  var refreshPresets = requiredElement("refresh-presets");
  var folderPath = requiredElement("folder-path");
  var outputName = requiredElement("output-name");
  var autoSend = requiredElement("auto-send");
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
  selectedFolder = localStorage.getItem(FOLDER_STORAGE_KEY) || "";
  if (selectedFolder) {
    folderPath.textContent = selectedFolder;
  }
  updateExportButtonLabel();
  applyHostTheme();

  autoSend.addEventListener("change", function () {
    localStorage.setItem(AUTO_SEND_STORAGE_KEY, String(autoSend.checked));
    updateExportButtonLabel();
  });
  presetTrigger.addEventListener("click", togglePresetMenu);
  presetSearch.addEventListener("input", renderPresetOptions);
  presetMenu.addEventListener("keydown", function (event) {
    if (event.key === "Escape") {
      event.preventDefault();
      closePresetMenu();
      presetTrigger.focus();
    }
  });
  document.addEventListener("click", function (event) {
    if (!presetPicker.contains(event.target)) { closePresetMenu(); }
  });
  refreshPresets.addEventListener("click", loadPresets);
  chooseFolder.addEventListener("click", selectFolder);
  refreshSequence.addEventListener("click", function () { loadActiveSequence(true); });
  exportButton.addEventListener("click", startExport);
  cep.addEventListener("com.adobe.csxs.events.ThemeColorChanged", applyHostTheme);

  loadPresets();
  loadActiveSequence(false);

  function loadPresets() {
    if (!window.cep_node || typeof window.cep_node.require !== "function") {
      reportError(new Error("CEP 12 的 Node.js 接口不可用"));
      return;
    }

    try {
      var fileSystem = window.cep_node.require("fs");
      var pathModule = window.cep_node.require("path");
      var os = window.cep_node.require("os");
      presetGroups = presetLibrary.discoverPresets(fileSystem, pathModule, os.homedir());
    } catch (error) {
      reportError(new Error("扫描 Adobe 导出预设失败：" + error.message));
      return;
    }
    var storedPath = localStorage.getItem(PRESET_STORAGE_KEY);
    var presets = presetGroups.user.concat(presetGroups.system);
    var presetCount = presets.length;

    selectedPresetPath = "";
    presetValue.textContent = "请选择导出预设";
    if (storedPath) {
      var storedPreset = presets.filter(function (preset) { return preset.path === storedPath; })[0];
      if (storedPreset) { selectPreset(storedPreset, false); }
    }
    presetSearch.value = "";
    renderPresetOptions();

    if (presetCount === 0) {
      presetValue.textContent = "未发现导出预设";
      setStatus("请先在 Premiere 导出页保存一个预设", "error");
      return;
    }
    setStatus("已发现 " + presetCount + " 个导出预设", "neutral");
  }

  function togglePresetMenu() {
    if (presetMenu.hidden) {
      presetMenu.hidden = false;
      presetTrigger.setAttribute("aria-expanded", "true");
      presetSearch.value = "";
      renderPresetOptions();
      presetSearch.focus();
      return;
    }
    closePresetMenu();
  }

  function closePresetMenu() {
    presetMenu.hidden = true;
    presetTrigger.setAttribute("aria-expanded", "false");
  }

  function renderPresetOptions() {
    var query = presetSearch.value.trim().toLocaleLowerCase();
    var matchCount = 0;
    presetOptions.textContent = "";
    appendPresetGroup("我的预设", presetGroups.user, query);
    appendPresetGroup("Premiere 系统预设", presetGroups.system, query);

    function appendPresetGroup(label, presets, filterText) {
      var matches = presets.filter(function (preset) {
        return !filterText || preset.name.toLocaleLowerCase().indexOf(filterText) !== -1;
      });
      if (matches.length === 0) { return; }

      var heading = document.createElement("div");
      heading.className = "preset-group";
      heading.textContent = label;
      presetOptions.appendChild(heading);
      matches.forEach(function (preset) {
        var option = document.createElement("button");
        option.type = "button";
        option.className = "preset-option" + (preset.path === selectedPresetPath ? " selected" : "");
        option.textContent = preset.name;
        option.title = preset.path;
        option.addEventListener("click", function () { selectPreset(preset, true); });
        presetOptions.appendChild(option);
        matchCount += 1;
      });
    }

    if (matchCount === 0) {
      var empty = document.createElement("p");
      empty.className = "preset-empty";
      empty.textContent = query ? "没有匹配的预设" : "未发现导出预设";
      presetOptions.appendChild(empty);
    }
  }

  function selectPreset(preset, announce) {
    selectedPresetPath = preset.path;
    presetValue.textContent = preset.name;
    localStorage.setItem(PRESET_STORAGE_KEY, preset.path);
    if (announce) {
      closePresetMenu();
      presetTrigger.focus();
      setStatus("已选择：" + preset.name, "neutral");
      renderPresetOptions();
    }
  }

  function selectFolder() {
    callHost("chooseFolder", [], function (reply) {
      if (reply.status === "CANCEL") { return; }
      selectedFolder = reply.detail;
      localStorage.setItem(FOLDER_STORAGE_KEY, selectedFolder);
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
    if (!selectedPresetPath) {
      reportError(new Error("没有可用的 Adobe 导出预设"));
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
    callHost("exportSequence", [selectedPresetPath, selectedFolder, name], function (reply) {
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
    presetTrigger.disabled = value;
    if (value) { closePresetMenu(); }
    refreshPresets.disabled = value;
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
