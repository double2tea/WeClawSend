const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const protocol = require("../js/protocol.js");
const presetLibrary = require("../js/preset-library.js");

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
