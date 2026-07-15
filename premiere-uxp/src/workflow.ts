export const AUTO_SEND_STORAGE_KEY = "autoSendAfterExport";

export function buildOutputFileName(baseName: string, extension: string): string {
  const trimmedName = baseName.trim();
  const normalizedExtension = extension.trim().replace(/^\./, "");
  if (trimmedName.length === 0) {
    throw new Error("请输入输出文件名");
  }
  if (trimmedName.includes("/")) {
    throw new Error("输出文件名不能包含 /");
  }
  if (normalizedExtension.length === 0) {
    throw new Error("导出预设没有提供文件扩展名");
  }
  if (!/^[A-Za-z0-9]+$/.test(normalizedExtension)) {
    throw new Error("导出预设提供了无效的文件扩展名");
  }
  return `${trimmedName}.${normalizedExtension}`;
}

export function buildOutputPath(folderPath: string, fileName: string): string {
  if (folderPath.length === 0) {
    throw new Error("请选择输出位置");
  }
  if (!folderPath.startsWith("/")) {
    throw new Error("输出位置必须是 macOS 绝对路径");
  }
  return `${folderPath.endsWith("/") ? folderPath : `${folderPath}/`}${fileName}`;
}

export function buildSendURL(filePath: string, fileName: string): string {
  if (!filePath.startsWith("/")) {
    throw new Error("发送文件必须使用绝对路径");
  }
  return `weclaw-send://send?file_path=${encodeURIComponent(filePath)}&file_name=${encodeURIComponent(fileName)}`;
}

export function storedAutoSend(value: string | null): boolean {
  return value === "true";
}
