// electron-builder afterPack hook: strip extended attributes (Finder info,
// iCloud/File Provider metadata, quarantine…) that codesign refuses, before
// the app is ad-hoc signed.
const { execFileSync } = require("node:child_process");

exports.default = async function afterPack(context) {
  execFileSync("xattr", ["-cr", context.appOutDir]);
};
