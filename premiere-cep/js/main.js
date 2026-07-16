(function () {
  "use strict";

  var AUTO_SEND_STORAGE_KEY = "autoSendAfterExport";
  var PRESET_STORAGE_KEY = "selectedExportPreset";
  var FOLDER_STORAGE_KEY = "selectedOutputFolder";
  var cep = window.__adobe_cep__;
  var protocol = window.WeClawProtocol;
  var presetLibrary = window.WeClawPresetLibrary;
  var bridgeClient = window.WeClawBridgeClient;
  var selectedFolder = "";
  var selectedPresetPath = "";
  var presetGroups = { user: [], system: [] };
  var exporting = false;
  var sequenceRequestID = 0;
  var lastAutoOutputName = "";
  var lastExportedPath = "";
  var failedSends = [];
  var activeSendCount = 0;
  var retryingSendPath = "";
  var statusRevision = 0;
  var protectedErrorRevision = -1;

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
  var exportRange = requiredElement("export-range");
  var autoSend = requiredElement("auto-send");
  var chooseFolder = requiredElement("choose-folder");
  var refreshSequence = requiredElement("refresh-sequence");
  var exportButton = requiredElement("export");
  var outputActions = requiredElement("output-actions");
  var revealOutput = requiredElement("reveal-output");
  var retrySend = requiredElement("retry-send");
  var status = requiredElement("status");

  if (!cep || !bridgeClient) {
    setStatus("此面板必须在 Premiere Pro 中运行", "error");
    setExportBusy(true);
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
  refreshSequence.addEventListener("click", loadActiveSequence);
  exportButton.addEventListener("click", startExport);
  revealOutput.addEventListener("click", revealExportedFile);
  retrySend.addEventListener("click", retryFailedSend);
  window.addEventListener("focus", function () {
    if (!exporting) { loadActiveSequence(); }
  });
  cep.addEventListener("com.adobe.csxs.events.ThemeColorChanged", applyHostTheme);

  loadPresets();
  loadActiveSequence();

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

  function loadActiveSequence(onSuccess, onFailure) {
    var requestID = ++sequenceRequestID;
    callHost("activeSequenceName", [], function (reply) {
      if (requestID !== sequenceRequestID) { return; }
      sequenceName.textContent = reply.detail;
      if (protocol.shouldReplaceAutoName(outputName.value, lastAutoOutputName)) {
        outputName.value = reply.detail;
      }
      lastAutoOutputName = reply.detail;
      if (typeof onSuccess === "function") { onSuccess(reply.detail); }
    }, function (error) {
      if (requestID !== sequenceRequestID) { return; }
      sequenceName.textContent = "未打开序列";
      if (typeof onFailure === "function") {
        onFailure(error);
      } else {
        reportError(error);
      }
    });
  }

  function startExport() {
    if (exporting) {
      reportError(new Error("已有导出任务正在进行"));
      return;
    }
    statusRevision += 1;
    protectedErrorRevision = -1;
    if (!selectedPresetPath) {
      reportExportError(new Error("没有可用的 Adobe 导出预设"));
      return;
    }
    if (!selectedFolder) {
      reportExportError(new Error("请选择输出位置"));
      return;
    }

    exporting = true;
    setExportBusy(true);
    var sendAfterExport = autoSend.checked;
    var exportRevision = statusRevision;

    function prepareExport() {
      setStatus("正在读取当前序列…", "neutral");
      loadActiveSequence(function (activeSequenceName) {
        var name;
        try {
          name = protocol.validateOutputName(outputName.value);
        } catch (error) {
          finishExportWithError(error);
          return;
        }

        setStatus(exportRange.value === "inOut" ? "正在由 Premiere 导出 I/O 范围…" : "正在由 Premiere 导出…", "neutral");
        callHost("exportSequence", [selectedPresetPath, selectedFolder, name, exportRange.value, activeSequenceName], function (reply) {
          lastExportedPath = reply.detail;
          updateOutputActions();
          finishExport(sendAfterExport ? "导出完成，可继续导出；正在后台发送…" : "导出完成", sendAfterExport ? "neutral" : "success");
          if (sendAfterExport) {
            sendInBackground(reply.detail, false, exportRevision);
          } else {
            renderSendStatus("", exportRevision);
          }
        }, finishExportWithError);
      }, finishExportWithError);
    }

    if (!sendAfterExport) {
      prepareExport();
      return;
    }

    setStatus("正在检查 WeClaw Send 本地接口…", "neutral");
    bridgeClient.checkHealth(window.cep_node).then(prepareExport).catch(finishExportWithError);
  }

  function sendInBackground(filePath, isRetry, operationRevision) {
    activeSendCount += 1;
    if (isRetry) { retryingSendPath = filePath; }
    updateOutputActions();
    renderSendStatus("", operationRevision);

    bridgeClient.sendFile(window.cep_node, filePath).then(function () {
      activeSendCount -= 1;
      removeFailedSend(filePath);
      if (isRetry) {
        retryingSendPath = "";
      }
      updateOutputActions();
      renderSendStatus(isRetry ? "重新发送完成" : "后台发送完成", operationRevision);
    }).catch(function (error) {
      activeSendCount -= 1;
      if (isRetry) { retryingSendPath = ""; }
      recordFailedSend(filePath, error instanceof Error ? error.message : String(error));
      updateOutputActions();
      renderSendStatus("", operationRevision);
    });
  }

  function retryFailedSend() {
    if (failedSends.length === 0 || retryingSendPath) { return; }
    statusRevision += 1;
    protectedErrorRevision = -1;
    sendInBackground(failedSends[0].path, true, statusRevision);
  }

  function revealExportedFile() {
    if (!lastExportedPath || !window.cep_node || typeof window.cep_node.require !== "function") { return; }
    try {
      var child = window.cep_node.require("child_process").spawn(
        "/usr/bin/open",
        ["-R", lastExportedPath],
        { detached: true, stdio: "ignore" }
      );
      child.on("error", reportError);
      child.unref();
    } catch (error) {
      reportError(error);
    }
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

  function finishExport(message, kind) {
    exporting = false;
    setExportBusy(false);
    setStatus(message, kind);
  }

  function finishExportWithError(error) {
    protectedErrorRevision = statusRevision;
    finishExport(error instanceof Error ? error.message : String(error), "error");
  }

  function reportExportError(error) {
    protectedErrorRevision = statusRevision;
    reportError(error);
  }

  function reportError(error) {
    setStatus(error instanceof Error ? error.message : String(error), "error");
  }

  function setExportBusy(value) {
    presetTrigger.disabled = value;
    if (value) { closePresetMenu(); }
    refreshPresets.disabled = value;
    chooseFolder.disabled = value;
    refreshSequence.disabled = value;
    exportButton.disabled = value;
    outputName.disabled = value;
    exportRange.disabled = value;
    autoSend.disabled = value;
    updateOutputActions();
  }

  function updateOutputActions() {
    var failedCount = failedSends.length;
    outputActions.hidden = !lastExportedPath && failedCount === 0;
    revealOutput.hidden = !lastExportedPath;
    revealOutput.disabled = exporting;
    retrySend.hidden = failedCount === 0;
    retrySend.disabled = exporting || Boolean(retryingSendPath);
    retrySend.textContent = failedCount > 1 ? "重试失败发送（" + failedCount + "）" : "仅重试发送";
    retrySend.title = failedSends.map(function (failure) { return failure.path; }).join("\n");
  }

  function recordFailedSend(filePath, message) {
    removeFailedSend(filePath);
    failedSends.push({ path: filePath, message: message });
  }

  function removeFailedSend(filePath) {
    for (var index = failedSends.length - 1; index >= 0; index -= 1) {
      if (failedSends[index].path === filePath) { failedSends.splice(index, 1); }
    }
  }

  function renderSendStatus(successMessage, operationRevision) {
    if (exporting) { return; }
    if (protectedErrorRevision === statusRevision) { return; }
    if (retryingSendPath) {
      setStatus("正在重新发送已导出的文件…", "neutral");
      return;
    }
    if (failedSends.length === 1) {
      setStatus("发送失败：" + failedSends[0].message + "；可仅重试发送", "error");
      return;
    }
    if (failedSends.length > 1) {
      setStatus(failedSends.length + " 个文件发送失败；可逐个重试发送", "error");
      return;
    }
    if (activeSendCount > 0) {
      setStatus("导出已完成，可继续导出；后台发送中（" + activeSendCount + "）", "neutral");
      return;
    }
    if (successMessage && operationRevision === statusRevision) {
      setStatus(successMessage, "success");
    }
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
