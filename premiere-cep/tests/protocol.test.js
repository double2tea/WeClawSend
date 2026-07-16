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
