import type { premierepro, Sequence } from "@adobe/premierepro";

import {
  AUTO_SEND_STORAGE_KEY,
  buildOutputFileName,
  buildOutputPath,
  buildSendURL,
  storedAutoSend
} from "./workflow.js";

// UXP host modules are provided by Premiere at runtime.
// eslint-disable-next-line @typescript-eslint/no-require-imports
const ppro = require("premierepro") as premierepro;
// eslint-disable-next-line @typescript-eslint/no-require-imports
const uxp = require("uxp") as typeof import("uxp");

interface NativeFile {
  readonly isFile: true;
  readonly name: string;
  readonly nativePath: string;
}

interface NativeFolder {
  readonly isFolder: true;
  readonly nativePath: string;
}

interface LocalFileSystem {
  getFileForOpening(options: {
    readonly allowMultiple: boolean;
    readonly types: string[];
  }): Promise<unknown>;
  getFolder(options: Record<string, never>): Promise<unknown>;
}

const localFileSystem = (
  uxp as unknown as { readonly storage: { readonly localFileSystem: LocalFileSystem } }
).storage.localFileSystem;

const sequenceName = requiredElement<HTMLSpanElement>("#sequence-name");
const presetPath = requiredElement<HTMLParagraphElement>("#preset-path");
const folderPath = requiredElement<HTMLParagraphElement>("#folder-path");
const outputName = requiredElement<HTMLInputElement>("#output-name");
const autoSend = requiredElement<HTMLInputElement>("#auto-send");
const choosePreset = requiredElement<HTMLButtonElement>("#choose-preset");
const chooseFolder = requiredElement<HTMLButtonElement>("#choose-folder");
const refreshSequence = requiredElement<HTMLButtonElement>("#refresh-sequence");
const exportButton = requiredElement<HTMLButtonElement>("#export");
const status = requiredElement<HTMLParagraphElement>("#status");

let selectedPreset: NativeFile | null = null;
let selectedFolder: NativeFolder | null = null;
let exporting = false;

autoSend.checked = storedAutoSend(localStorage.getItem(AUTO_SEND_STORAGE_KEY));
updateExportButtonLabel();

autoSend.addEventListener("change", () => {
  localStorage.setItem(AUTO_SEND_STORAGE_KEY, String(autoSend.checked));
  updateExportButtonLabel();
});

choosePreset.addEventListener("click", () => {
  void selectPreset().catch(reportError);
});
chooseFolder.addEventListener("click", () => {
  void selectFolder().catch(reportError);
});
refreshSequence.addEventListener("click", () => {
  void loadActiveSequence(true).catch(reportError);
});
exportButton.addEventListener("click", () => {
  void startExport().catch(reportError);
});

uxp.entrypoints.setup({
  panels: {
    // @ts-expect-error Adobe's panel entrypoint typing does not match its runtime API.
    weclawSend: {
      show(): void {
        void loadActiveSequence(false).catch(reportError);
      }
    }
  }
});

void loadActiveSequence(false).catch(reportError);

async function selectPreset(): Promise<void> {
  const selection = await localFileSystem.getFileForOpening({
    types: ["epr"],
    allowMultiple: false
  });
  if (selection === null) {
    return;
  }
  if (!isNativeFile(selection)) {
    throw new Error("请选择有效的 Adobe .epr 导出预设");
  }
  selectedPreset = selection;
  presetPath.textContent = selection.nativePath;
  setStatus("已选择导出预设", "neutral");
}

async function selectFolder(): Promise<void> {
  const selection = await localFileSystem.getFolder({});
  if (selection === null) {
    return;
  }
  if (!isNativeFolder(selection)) {
    throw new Error("请选择有效的输出文件夹");
  }
  selectedFolder = selection;
  folderPath.textContent = selection.nativePath;
  setStatus("已选择输出位置", "neutral");
}

async function loadActiveSequence(replaceOutputName: boolean): Promise<Sequence | null> {
  const project = await ppro.Project.getActiveProject();
  const sequence = await project?.getActiveSequence();
  if (!sequence) {
    sequenceName.textContent = "没有活动序列";
    if (replaceOutputName) {
      outputName.value = "";
    }
    setStatus("请先在 Premiere 中打开一个序列", "error");
    return null;
  }

  sequenceName.textContent = sequence.name;
  if (replaceOutputName || outputName.value.trim().length === 0) {
    outputName.value = sequence.name;
  }
  return sequence;
}

async function startExport(): Promise<void> {
  if (exporting) {
    throw new Error("已有导出任务正在进行");
  }
  if (!selectedPreset) {
    throw new Error("请选择 Adobe .epr 导出预设");
  }
  if (!selectedFolder) {
    throw new Error("请选择输出位置");
  }
  exporting = true;
  setBusy(true);
  try {
    const sequence = await loadActiveSequence(false);
    if (!sequence) {
      return;
    }

    setStatus("正在准备导出…", "neutral");
    const encoder = ppro.EncoderManager.getManager();
    const extension = await ppro.EncoderManager.getExportFileExtension(
      sequence,
      selectedPreset.nativePath
    );
    const fileName = buildOutputFileName(outputName.value, extension);
    const outputPath = buildOutputPath(selectedFolder.nativePath, fileName);
    const shouldSend = autoSend.checked;

    setStatus("正在导出…", "neutral");
    // IMMEDIATELY resolves for this export, avoiding an unscoped global completion event.
    const accepted = await encoder.exportSequence(
      sequence,
      ppro.Constants.ExportType.IMMEDIATELY,
      outputPath,
      selectedPreset.nativePath
    );
    if (!accepted) {
      throw new Error("Premiere 导出失败或已取消");
    }
    if (!shouldSend) {
      setStatus("导出完成", "success");
      return;
    }

    setStatus("导出完成，正在提交给 WeClaw Send…", "neutral");
    const result = await uxp.shell.openExternal(
      buildSendURL(outputPath, fileName),
      "允许 WeClaw Send 发送本次导出的文件"
    );
    if (result.length > 0) {
      throw new Error(result);
    }
    setStatus("已提交给 WeClaw Send", "success");
  } finally {
    exporting = false;
    setBusy(false);
  }
}

function isNativeFile(value: unknown): value is NativeFile {
  return (
    typeof value === "object" &&
    value !== null &&
    "isFile" in value &&
    value.isFile === true &&
    "name" in value &&
    typeof value.name === "string" &&
    "nativePath" in value &&
    typeof value.nativePath === "string"
  );
}

function isNativeFolder(value: unknown): value is NativeFolder {
  return (
    typeof value === "object" &&
    value !== null &&
    "isFolder" in value &&
    value.isFolder === true &&
    "nativePath" in value &&
    typeof value.nativePath === "string"
  );
}

function requiredElement<T extends Element>(selector: string): T {
  const element = document.querySelector<T>(selector);
  if (!element) {
    throw new Error(`缺少界面元素：${selector}`);
  }
  return element;
}

function setBusy(busy: boolean): void {
  exportButton.disabled = busy;
  choosePreset.disabled = busy;
  chooseFolder.disabled = busy;
  refreshSequence.disabled = busy;
  outputName.disabled = busy;
  autoSend.disabled = busy;
}

function updateExportButtonLabel(): void {
  exportButton.textContent = autoSend.checked ? "导出并自动发送" : "导出";
}

function setStatus(message: string, tone: "neutral" | "success" | "error"): void {
  status.textContent = message;
  status.className = tone === "neutral" ? "status" : `status ${tone}`;
}

function reportError(error: unknown): void {
  setStatus(error instanceof Error ? error.message : String(error), "error");
}
