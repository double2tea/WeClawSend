"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const protocol = require("../js/protocol.js");

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((resolvePromise, rejectPromise) => {
    resolve = resolvePromise;
    reject = rejectPromise;
  });
  return { promise, resolve, reject };
}

function createElement(id) {
  const listeners = {};
  return {
    id,
    listeners,
    textContent: "",
    value: id === "export-range" ? "entire" : "",
    checked: false,
    hidden: id === "preset-menu" || id === "output-actions" || id === "retry-send",
    disabled: false,
    className: "",
    title: "",
    addEventListener(type, listener) { listeners[type] = listener; },
    appendChild() {},
    contains() { return false; },
    focus() {},
    setAttribute() {}
  };
}

function createPanelHarness() {
  const elementIDs = [
    "sequence-name",
    "preset-picker",
    "preset-trigger",
    "preset-value",
    "preset-menu",
    "preset-search",
    "preset-options",
    "refresh-presets",
    "folder-path",
    "output-name",
    "export-range",
    "auto-send",
    "choose-folder",
    "refresh-sequence",
    "export",
    "output-actions",
    "reveal-output",
    "retry-send",
    "status"
  ];
  const elements = Object.fromEntries(elementIDs.map((id) => [id, createElement(id)]));
  const storage = new Map([
    ["autoSendAfterExport", "true"],
    ["selectedExportPreset", "/preset.epr"],
    ["selectedOutputFolder", "/output"]
  ]);
  const exportReplies = [];
  const sendResults = [];
  let activeSequenceName = "Sequence A";

  const document = {
    documentElement: { setAttribute() {} },
    getElementById(id) { return elements[id] || null; },
    createElement(id) { return createElement(id); },
    addEventListener() {}
  };
  const localStorage = {
    getItem(key) { return storage.has(key) ? storage.get(key) : null; },
    setItem(key, value) { storage.set(key, value); }
  };
  const cep = {
    addEventListener() {},
    getHostEnvironment() {
      return JSON.stringify({ appSkinInfo: { panelBackgroundColor: { color: { red: 30, green: 30, blue: 30 } } } });
    },
    evalScript(expression, callback) {
      if (expression.startsWith("$._WECLAW.activeSequenceName(")) {
        callback("OK|" + encodeURIComponent(activeSequenceName));
        return;
      }
      if (expression.startsWith("$._WECLAW.exportSequence(")) {
        callback(exportReplies.shift());
        return;
      }
      throw new Error("unexpected host call: " + expression);
    }
  };
  const window = {
    __adobe_cep__: cep,
    WeClawProtocol: protocol,
    WeClawPresetLibrary: {
      discoverPresets() {
        return { user: [{ name: "Preset", path: "/preset.epr" }], system: [] };
      }
    },
    WeClawBridgeClient: {
      checkHealth() { return Promise.resolve({ ok: true }); },
      sendFile() { return sendResults.shift().promise; }
    },
    cep_node: {
      Buffer,
      require(name) {
        if (name === "os") { return { homedir() { return "/tmp"; } }; }
        return {};
      }
    },
    addEventListener() {}
  };
  const context = {
    Boolean,
    Buffer,
    Error,
    JSON,
    Promise,
    String,
    console,
    document,
    encodeURIComponent,
    localStorage,
    window
  };
  vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, "../js/main.js"), "utf8"),
    context
  );

  return {
    elements,
    addExportSuccess(filePath) {
      exportReplies.push("OK|" + encodeURIComponent(filePath));
    },
    addExportFailure(message) {
      exportReplies.push("ERROR|" + encodeURIComponent(message));
    },
    addSendResult(result) {
      sendResults.push(result);
    },
    clickExport() {
      elements.export.listeners.click();
    },
    clickRetry() {
      elements["retry-send"].listeners.click();
    },
    setSequenceName(name) {
      activeSequenceName = name;
    }
  };
}

async function flushPromises() {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
}

test("unlocks export controls while background sending continues", async () => {
  const harness = createPanelHarness();
  const send = deferred();
  harness.addExportSuccess("/output/Sequence A.mp4");
  harness.addSendResult(send);

  harness.clickExport();
  await flushPromises();

  assert.equal(harness.elements.export.disabled, false);
  assert.match(harness.elements.status.textContent, /后台发送中/);
  send.resolve({ ok: true });
  await flushPromises();
});

test("an older send callback does not overwrite a newer export error", async () => {
  const harness = createPanelHarness();
  const firstSend = deferred();
  harness.addExportSuccess("/output/Sequence A.mp4");
  harness.addSendResult(firstSend);
  harness.clickExport();
  await flushPromises();

  harness.setSequenceName("Sequence B");
  harness.addExportFailure("输出文件已存在");
  harness.clickExport();
  await flushPromises();
  assert.match(harness.elements.status.textContent, /输出文件已存在/);

  firstSend.resolve({ ok: true });
  await flushPromises();
  assert.match(harness.elements.status.textContent, /输出文件已存在/);
});

test("retains multiple failed sends and retries them one at a time", async () => {
  const harness = createPanelHarness();
  const firstSend = deferred();
  const secondSend = deferred();
  harness.addExportSuccess("/output/Sequence A.mp4");
  harness.addSendResult(firstSend);
  harness.clickExport();
  await flushPromises();

  harness.setSequenceName("Sequence B");
  harness.addExportSuccess("/output/Sequence B.mp4");
  harness.addSendResult(secondSend);
  harness.clickExport();
  await flushPromises();

  firstSend.reject(new Error("A failed"));
  secondSend.reject(new Error("B failed"));
  await flushPromises();
  assert.match(harness.elements.status.textContent, /2 个文件发送失败/);
  assert.equal(harness.elements["retry-send"].textContent, "重试失败发送（2）");

  const retry = deferred();
  harness.addSendResult(retry);
  harness.clickRetry();
  await flushPromises();
  retry.resolve({ ok: true });
  await flushPromises();
  assert.equal(harness.elements["retry-send"].textContent, "仅重试发送");
  assert.match(harness.elements.status.textContent, /B failed/);

  const successfulResend = deferred();
  harness.addExportSuccess("/output/Sequence B.mp4");
  harness.addSendResult(successfulResend);
  harness.clickExport();
  await flushPromises();
  successfulResend.resolve({ ok: true });
  await flushPromises();
  assert.equal(harness.elements["retry-send"].hidden, true);
});
