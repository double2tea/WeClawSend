import { describe, expect, it } from "vitest";

import {
  buildOutputFileName,
  buildOutputPath,
  buildSendURL,
  storedAutoSend
} from "../src/workflow.js";

describe("Premiere export workflow", () => {
  it("builds an output name from the preset extension", () => {
    expect(buildOutputFileName(" 成片 v06 ", " .mp4 ")).toBe("成片 v06.mp4");
  });

  it("rejects invalid output names and extensions", () => {
    expect(() => buildOutputFileName("", "mp4")).toThrow("请输入输出文件名");
    expect(() => buildOutputFileName("目录/成片", "mp4")).toThrow("不能包含 /");
    expect(() => buildOutputFileName("成片", "")).toThrow("没有提供文件扩展名");
  });

  it("joins macOS output paths", () => {
    expect(buildOutputPath("/Users/me/Movies", "成片.mp4")).toBe("/Users/me/Movies/成片.mp4");
    expect(buildOutputPath("/Users/me/Movies/", "成片.mp4")).toBe("/Users/me/Movies/成片.mp4");
    expect(() => buildOutputPath("", "成片.mp4")).toThrow("请选择输出位置");
  });

  it("encodes the WeClaw Send integration URL", () => {
    expect(buildSendURL("/Users/me/成片 v06.mp4", "成片 v06.mp4")).toBe(
      "weclaw-send://send?file_path=%2FUsers%2Fme%2F%E6%88%90%E7%89%87%20v06.mp4&file_name=%E6%88%90%E7%89%87%20v06.mp4"
    );
    expect(() => buildSendURL("relative.mp4", "relative.mp4")).toThrow("必须使用绝对路径");
  });

  it("keeps auto-send opt-in", () => {
    expect(storedAutoSend(null)).toBe(false);
    expect(storedAutoSend("false")).toBe(false);
    expect(storedAutoSend("true")).toBe(true);
  });
});
