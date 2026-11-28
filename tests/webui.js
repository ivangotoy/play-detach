// Test of WebUI logic in module/webroot/app.js, called by tests/run.sh:
//   node tests/webui.js <repo root> <scratch folder>
// The functions are taken by name from the real app.js (never a copy) and run
// with a fake root bridge: exec() runs the command with sh, and STORAGE (internal
// storage as root sees it) is a folder in the scratch folder.
// Prints "ok <name>" / "FAIL <name>"; exits 1 when a check failed.
"use strict";
const fs = require("fs");
const path = require("path");
const cp = require("child_process");

const [root, work] = process.argv.slice(2);
const src = fs.readFileSync(path.join(root, "module/webroot/app.js"), "utf8");

// "const <name> = ...;" on one line
function constLine(name) {
  const m = src.match(new RegExp(`^const ${name} = .*;$`, "m"));
  if (!m) throw new Error(`app.js: const ${name} not found`);
  return m[0];
}
// "[async ]function <name>(...) {" up to the first "}" at the start of a line
function fn(name) {
  const start = src.search(new RegExp(`^(async )?function ${name}\\(`, "m"));
  if (start < 0) throw new Error(`app.js: function ${name} not found`);
  const end = src.indexOf("\n}\n", start);
  if (end < 0) throw new Error(`app.js: end of function ${name} not found`);
  return src.slice(start, end + 2);
}

function load(storage, exec) {
  const body = [constLine("sq"), constLine("BACKUP_DIR"), fn("startDir"), "return { sq, startDir, BACKUP_DIR };"].join("\n");
  return new Function("STORAGE", "exec", body)(storage, exec);
}

const shExec = (cmd) => {
  const r = cp.spawnSync("sh", ["-c", cmd], { cwd: work, encoding: "utf8" });
  return Promise.resolve({ errno: r.status, stdout: r.stdout || "", stderr: r.stderr || "" });
};

let fails = 0;
function check(name, good) {
  console.log(`${good ? "ok" : "FAIL"} ${name}`);
  if (!good) fails++;
}

async function main() {
  // startDir: the Play-Detach folder, Download when Play-Detach is missing or
  // a link, internal storage when neither can be used
  const s1 = path.join(work, "s1");
  fs.mkdirSync(path.join(s1, "Play-Detach"), { recursive: true });
  fs.mkdirSync(path.join(s1, "Download"));
  check("startDir: the Play-Detach folder", (await load(s1, shExec).startDir()) === `${s1}/Play-Detach`);

  const s2 = path.join(work, "s2");
  fs.mkdirSync(path.join(s2, "Download"), { recursive: true });
  fs.mkdirSync(path.join(work, "elsewhere"));
  fs.symlinkSync(path.join(work, "elsewhere"), path.join(s2, "Play-Detach"));
  check("startDir: Play-Detach as a link is not used, Download is", (await load(s2, shExec).startDir()) === `${s2}/Download`);

  const s3 = path.join(work, "s3");
  fs.mkdirSync(s3);
  fs.symlinkSync(path.join(work, "elsewhere"), path.join(s3, "Download"));
  check("startDir: no usable folder, internal storage", (await load(s3, shExec).startDir()) === s3);

  const outside = async () => ({ errno: 0, stdout: "/etc\n", stderr: "" });
  check("startDir: an answer outside internal storage is not used", (await load(s1, outside).startDir()) === s1);

  // sq: any text reaches the shell as one argument, never as shell code
  const { sq } = load(s1, shExec);
  const texts = [
    ["a quote", "it's"],
    ["a command substitution", "$(touch pwned)"],
    ["backquotes", "`touch pwned`"],
    ["quotes and a backslash", "a'b'\\'c"],
    ["a newline", "line\nline"],
    ["an empty text", ""],
  ];
  for (const [label, text] of texts) {
    const r = cp.spawnSync("sh", ["-c", `printf %s ${sq(text)}`], { cwd: work, encoding: "utf8" });
    check(`sq: ${label} passed as text`, r.status === 0 && r.stdout === text);
  }
  check("sq: nothing ran from a quoted text", !fs.existsSync(path.join(work, "pwned")));
}

main().then(
  () => process.exit(fails ? 1 : 0),
  (e) => {
    console.log(`FAIL webui test: ${e.message}`);
    process.exit(1);
  }
);
