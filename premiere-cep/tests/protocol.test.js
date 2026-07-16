const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const vm = require("node:vm");
const protocol = require("../js/protocol.js");
const presetLibrary = require("../js/preset-library.js");
const bridgeClient = require("../js/bridge-client.js");

function createBridgeNode(statusCode, payload, inspectRequest) {
  return {
    Buffer,
    require(name) {
      assert.equal(name, "http");
      return {
        request(options, onResponse) {
          const requestHandlers = {};
          return {
            setTimeout() {},
            on(event, handler) {
              requestHandlers[event] = handler;
              return this;
            },
            destroy(error) {
              requestHandlers.error(error);
            },
            end(body) {
              if (inspectRequest) { inspectRequest(options, body); }
              const responseHandlers = {};
              onResponse({
                statusCode,
                on(event, handler) {
                  responseHandlers[event] = handler;
                  return this;
                }
              });
              responseHandlers.data(Buffer.from(JSON.stringify(payload)));
              responseHandlers.end();
            }
          };
        }
      };
    }
  };
}

function createInterruptedBridgeNode(eventName) {
  return {
    Buffer,
    require(name) {
      assert.equal(name, "http");
      return {
        request(_options, onResponse) {
          return {
            setTimeout() {},
            on() { return this; },
            end() {
              const responseHandlers = {};
              onResponse({
                statusCode: 200,
                on(event, handler) {
                  responseHandlers[event] = handler;
                  return this;
                }
              });
              if (eventName === "error") {
                responseHandlers.error(new Error("response failed"));
              } else {
                responseHandlers.aborted();
              }
            }
          };
        }
      };
    }
  };
}

test("parses encoded host values", () => {
  assert.deepEqual(protocol.parseHostReply("OK|%E6%88%90%E7%89%87%20v1"), {
    status: "OK",
    detail: "成片 v1"
  });
});

test("throws explicit host errors", () => {
  assert.throws(
    () => protocol.parseHostReply("ERROR|%E6%97%A0%E6%B4%BB%E5%8A%A8%E5%BA%8F%E5%88%97"),
    /无活动序列/
  );
});

test("validates output names", () => {
  assert.equal(protocol.validateOutputName("  成片 v1  "), "成片 v1");
  assert.throws(() => protocol.validateOutputName(""), /请输入输出文件名/);
  assert.throws(() => protocol.validateOutputName("a/b"), /不能包含/);
  assert.throws(() => protocol.validateOutputName("a:b"), /不能包含/);
});

test("only replaces an empty or previous automatic output name", () => {
  assert.equal(protocol.shouldReplaceAutoName("", "旧序列"), true);
  assert.equal(protocol.shouldReplaceAutoName("旧序列", "旧序列"), true);
  assert.equal(protocol.shouldReplaceAutoName("手动文件名", "旧序列"), false);
  assert.equal(protocol.shouldReplaceAutoName("手动文件名", ""), false);
});

test("checks the local bridge before sending", async () => {
  let healthOptions;
  const health = await bridgeClient.checkHealth(createBridgeNode(200, {
    ok: true,
    service: "weclaw-send"
  }, (options) => { healthOptions = options; }));
  assert.equal(health.service, "weclaw-send");
  assert.equal(healthOptions.method, "GET");
  assert.equal(healthOptions.path, "/health");

  await assert.rejects(
    bridgeClient.checkHealth(createBridgeNode(503, { ok: false, error: "接口未就绪" })),
    /接口未就绪/
  );
});

test("rejects interrupted local bridge responses", async () => {
  await assert.rejects(
    bridgeClient.checkHealth(createInterruptedBridgeNode("error")),
    /response failed/
  );
  await assert.rejects(
    bridgeClient.checkHealth(createInterruptedBridgeNode("aborted")),
    /响应中断/
  );
});

test("loads the bridge client in a CEP renderer with Node globals", () => {
  const context = {
    window: {},
    module: { exports: {} },
    Promise,
    globalThis: {}
  };
  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../js/bridge-client.js"), "utf8"), context);
  assert.equal(typeof context.window.WeClawBridgeClient.checkHealth, "function");
  assert.equal(context.module.exports, context.window.WeClawBridgeClient);
});

test("sends only the exported file path", async () => {
  let sentBody;
  await bridgeClient.sendFile(createBridgeNode(200, { ok: true }, (options, body) => {
    assert.equal(options.method, "POST");
    assert.equal(options.path, "/send");
    sentBody = JSON.parse(body);
  }), "/output/成片.mp4");
  assert.deepEqual(sentBody, {
    file_path: "/output/成片.mp4",
    file_name: "成片.mp4"
  });
});

test("exports the selected Premiere range", () => {
  const workAreaTypes = [];
  const sequence = {
    name: "Current Sequence",
    getInPoint: () => "1",
    getOutPoint: () => "2",
    getExportFileExtension: () => "mp4",
    exportAsMediaDirect: (_outputPath, _presetPath, workAreaType) => {
      workAreaTypes.push(workAreaType);
      return true;
    }
  };
  const HostFile = function (fsName) {
    this.fsName = fsName;
    this.exists = fsName === "/preset.epr" || fsName === "/output/existing.mp4";
  };
  const HostFolder = function (fsName) {
    this.fsName = fsName;
    this.exists = true;
  };
  HostFolder.fs = "Macintosh";
  const context = {
    app: { project: { activeSequence: sequence } },
    File: HostFile,
    Folder: HostFolder,
    $: {},
    encodeURIComponent
  };

  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../jsx/host.jsx"), "utf8"), context);

  assert.deepEqual(protocol.parseHostReply(context.$._WECLAW.exportSequence(
    "/preset.epr",
    "/output",
    "entire-sequence",
    "entire",
    "Current Sequence"
  )), { status: "OK", detail: "/output/entire-sequence.mp4" });
  assert.deepEqual(protocol.parseHostReply(context.$._WECLAW.exportSequence(
    "/preset.epr",
    "/output",
    "in-out",
    "inOut",
    "Current Sequence"
  )), { status: "OK", detail: "/output/in-out.mp4" });
  assert.deepEqual(workAreaTypes, [0, 1]);
  assert.throws(
    () => protocol.parseHostReply(context.$._WECLAW.exportSequence(
      "/preset.epr",
      "/output",
      "invalid-range",
      "workArea",
      "Current Sequence"
    )),
    /导出范围无效/
  );
  assert.throws(
    () => protocol.parseHostReply(context.$._WECLAW.exportSequence(
      "/preset.epr",
      "/output",
      "existing",
      "entire",
      "Current Sequence"
    )),
    /输出文件已存在/
  );
  assert.throws(
    () => protocol.parseHostReply(context.$._WECLAW.exportSequence(
      "/preset.epr",
      "/output",
      "wrong-sequence",
      "entire",
      "Previous Sequence"
    )),
    /当前序列已切换/
  );
});

test("rejects unset or reversed I/O points before exporting", () => {
  let exportCount = 0;
  const sequence = {
    name: "Current Sequence",
    getInPoint: () => "-400000",
    getOutPoint: () => "-400000",
    getExportFileExtension: () => "mp4",
    exportAsMediaDirect: () => { exportCount += 1; return true; }
  };
  const HostFile = function (fsName) {
    this.fsName = fsName;
    this.exists = fsName === "/preset.epr";
  };
  const HostFolder = function (fsName) {
    this.fsName = fsName;
    this.exists = true;
  };
  HostFolder.fs = "Macintosh";
  const context = {
    app: { project: { activeSequence: sequence } },
    File: HostFile,
    Folder: HostFolder,
    $: {},
    encodeURIComponent,
    isFinite,
    Number
  };

  vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../jsx/host.jsx"), "utf8"), context);
  assert.throws(
    () => protocol.parseHostReply(context.$._WECLAW.exportSequence(
      "/preset.epr",
      "/output",
      "unset",
      "inOut",
      "Current Sequence"
    )),
    /设置有效的入点和出点/
  );

  sequence.getInPoint = () => "5";
  sequence.getOutPoint = () => "4";
  assert.throws(
    () => protocol.parseHostReply(context.$._WECLAW.exportSequence(
      "/preset.epr",
      "/output",
      "reversed",
      "inOut",
      "Current Sequence"
    )),
    /设置有效的入点和出点/
  );
  assert.equal(exportCount, 0);
});

test("scans EPR files and excludes internal preview presets", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "weclaw-presets-"));
  fs.mkdirSync(path.join(root, "SequencePreview"));
  fs.mkdirSync(path.join(root, "Custom"));
  fs.writeFileSync(path.join(root, "Custom", "H.264 1080p.epr"), "");
  fs.writeFileSync(path.join(root, "Custom", "notes.txt"), "");
  fs.writeFileSync(path.join(root, "SequencePreview", "Internal.epr"), "");

  const result = presetLibrary.scanPresetDirectory(fs, path, root, ["SequencePreview"]);
  assert.deepEqual(result, [{
    name: "H.264 1080p",
    path: path.join(root, "Custom", "H.264 1080p.epr")
  }]);
  fs.rmSync(root, { recursive: true });
});

test("discovers Premiere and Media Encoder presets from every supported version", () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), "weclaw-all-presets-"));
  const home = path.join(root, "home");
  const applications = path.join(root, "Applications");

  for (const version of ["24.0", "25.0", "26.0", "27.0"]) {
    const presets = path.join(home, "Documents", "Adobe", "Adobe Media Encoder", version, "Presets");
    fs.mkdirSync(presets, { recursive: true });
    fs.writeFileSync(path.join(presets, `AME ${version}.epr`), "");
  }
  for (const year of [2022, 2025, 2026, 2027]) {
    const presets = path.join(
      applications,
      `Adobe Premiere Pro ${year}`,
      `Adobe Premiere Pro ${year}.app`,
      "Contents",
      "Settings",
      "EncoderPresets"
    );
    fs.mkdirSync(presets, { recursive: true });
    fs.writeFileSync(path.join(presets, `Premiere ${year}.epr`), "");
  }

  const result = presetLibrary.discoverPresets(fs, path, home, applications);
  assert.deepEqual(result.user.map((preset) => preset.name), ["AME 25.0", "AME 26.0", "AME 27.0"]);
  assert.deepEqual(result.system.map((preset) => preset.name), ["Premiere 2025", "Premiere 2026", "Premiere 2027"]);
  fs.rmSync(root, { recursive: true });
});
