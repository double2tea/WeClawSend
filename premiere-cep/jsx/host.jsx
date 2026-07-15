$._WECLAW = {
    ok: function (value) {
        return "OK|" + encodeURIComponent(value || "");
    },

    error: function (value) {
        return "ERROR|" + encodeURIComponent(value || "Premiere 操作失败");
    },

    chooseFolder: function () {
        var folder = Folder.selectDialog("选择导出文件夹");
        return folder ? this.ok(folder.fsName) : "CANCEL|";
    },

    activeSequenceName: function () {
        if (!app.project || !app.project.activeSequence) {
            return this.error("请先在 Premiere 中打开一个序列");
        }
        return this.ok(app.project.activeSequence.name);
    },

    exportSequence: function (presetPath, folderPath, outputName) {
        if (!app.project || !app.project.activeSequence) {
            return this.error("请先在 Premiere 中打开一个序列");
        }

        var preset = new File(presetPath);
        if (!preset.exists) {
            return this.error("导出预设不存在");
        }
        var folder = new Folder(folderPath);
        if (!folder.exists) {
            return this.error("输出文件夹不存在");
        }
        if (!outputName || /[\/:]/.test(outputName)) {
            return this.error("输出文件名无效");
        }

        var sequence = app.project.activeSequence;
        var extension = sequence.getExportFileExtension(preset.fsName);
        if (!extension) {
            return this.error("无法从导出预设读取文件扩展名");
        }

        var separator = Folder.fs === "Macintosh" ? "/" : "\\";
        var outputPath = folder.fsName + separator + outputName + "." + extension;
        if (!sequence.exportAsMediaDirect(outputPath, preset.fsName, 0)) {
            return this.error("Premiere 导出失败");
        }
        return this.ok(outputPath);
    }
};
