(function (root, factory) {
  var library = factory();
  root.WeClawPresetLibrary = library;
  if (typeof module === "object" && module.exports) {
    module.exports = library;
  }
})(typeof window === "object" ? window : globalThis, function () {
  "use strict";

  function scanPresetDirectory(fileSystem, pathModule, directory, excludedNames) {
    if (!fileSystem.existsSync(directory)) {
      return [];
    }

    var presets = [];
    fileSystem.readdirSync(directory, { withFileTypes: true }).forEach(function (entry) {
      var entryPath = pathModule.join(directory, entry.name);
      if (entry.isDirectory()) {
        if (excludedNames.indexOf(entry.name) === -1) {
          presets = presets.concat(
            scanPresetDirectory(fileSystem, pathModule, entryPath, excludedNames)
          );
        }
        return;
      }
      if (entry.isFile() && pathModule.extname(entry.name).toLowerCase() === ".epr") {
        presets.push({
          name: pathModule.basename(entry.name, pathModule.extname(entry.name)),
          path: entryPath
        });
      }
    });
    return presets;
  }

  function discoverPresets(fileSystem, pathModule, homeDirectory, applicationsDirectory) {
    var mediaEncoderDirectory = pathModule.join(
      homeDirectory,
      "Documents",
      "Adobe",
      "Adobe Media Encoder"
    );
    var user = [];
    var system = [];
    applicationsDirectory = applicationsDirectory || "/Applications";

    if (fileSystem.existsSync(mediaEncoderDirectory)) {
      fileSystem.readdirSync(mediaEncoderDirectory, { withFileTypes: true }).forEach(function (entry) {
        if (!entry.isDirectory() || !isSupportedMajorVersion(entry.name)) {
          return;
        }
        user = user.concat(scanPresetDirectory(
          fileSystem,
          pathModule,
          pathModule.join(mediaEncoderDirectory, entry.name, "Presets"),
          []
        ));
      });
    }

    if (fileSystem.existsSync(applicationsDirectory)) {
      fileSystem.readdirSync(applicationsDirectory, { withFileTypes: true }).forEach(function (entry) {
        if (!entry.isDirectory() || !isSupportedPremiereApplication(entry.name)) {
          return;
        }
        var presetDirectory = pathModule.join(
          applicationsDirectory,
          entry.name,
          entry.name + ".app",
          "Contents",
          "Settings",
          "EncoderPresets"
        );
        system = system.concat(
          scanPresetDirectory(fileSystem, pathModule, presetDirectory, ["SequencePreview"])
        );
      });
    }

    function byName(left, right) {
      return left.name.localeCompare(right.name, "zh-CN");
    }

    return {
      user: user.sort(byName),
      system: system.sort(byName)
    };
  }

  function isSupportedMajorVersion(version) {
    return /^\d+\.\d+$/.test(version) && parseInt(version, 10) >= 25;
  }

  function isSupportedPremiereApplication(name) {
    var match = /^Adobe Premiere Pro (\d{4})$/.exec(name);
    return match && parseInt(match[1], 10) >= 2025;
  }

  return {
    discoverPresets: discoverPresets,
    scanPresetDirectory: scanPresetDirectory
  };
});
