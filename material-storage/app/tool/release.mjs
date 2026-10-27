// ms_app 发布脚本：material-storage/app/tool/release.mjs
// 用途：pubspec 版本处理 -> flutter build apk（--release --split-per-abi，仅保留 arm64）
//       -> 七牛表单直传版本化 APK -> rs copy 出固定名 APK（force 覆盖，不二次上传）
//       -> 生成并直传 app_version.json -> CDN 刷新固定名 APK 与 JSON 两个 URL -> 收尾打印
// 仅依赖 Node 内置模块（项目准则：未经允许不安装第三方库）
// 运行（cwd=material-storage/app）：node tool/release.mjs [选项]
//
// 选项：
//   --version=x.y.z   显式指定版本（x.y.z），build 号仍自动 +1
//   --no-bump         不改版本，按当前 version+build 原样重发（覆盖同键）
//   --changelog="..." 更新说明，写入 app_version.json，缺省空串
//   --dry-run         执行版本处理与 flutter build 并打印发布计划，跳过全部七牛网络操作
//                     （pubspec.yaml 会真实改写以验证改写逻辑，结束时还原）
//   --skip-build      跳过 flutter build 与产物清理（产物不存在时不再报错），可与 --dry-run 组合
//   默认（无参数）= patch+1、build+1 并改写回 pubspec.yaml
//   上传前会用 apksigner / aapt2 校验产物证书 MD5 与包名，不符即中止（工具缺失则只告警）
//
// 凭证与配置：worktree 根 scripts/env/qiniu.env（QINIU_HHSJ_*，gitignored，绝不硬编码）：
//   QINIU_HHSJ_ACCESS_KEY / QINIU_HHSJ_SECRET_KEY   七牛 AK/SK（必填）
//   QINIU_HHSJ_BUCKET                               桶名（必填，taoxi-resources）
//   QINIU_HHSJ_ZONE                                 区域（必填，z0；启动时经 uc 探测一次，
//                                                   探测结果与 env 不一致打警告但按 env 继续）
//   QINIU_HHSJ_CDN_BASE                             CDN 域名（必填，https://resources.taoxiplan.com）
//   QINIU_HHSJ_KEY_PREFIX                           对象键前缀（必填，huanhuashijie）

import fs from "node:fs";
import path from "node:path";
import https from "node:https";
import crypto from "node:crypto";
import { spawnSync } from "node:child_process";
import { fileURLToPath, pathToFileURL } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const projectRoot = path.resolve(__dirname, "..");
const PUBSPEC_FILE = path.join(projectRoot, "pubspec.yaml");
// 脚本位于 material-storage/app/tool，../../../ 即 worktree 根
const ENV_FILE = path.resolve(__dirname, "..", "..", "..", "scripts", "env", "qiniu.env");

// 固定命名口径（需求 F1-3/4/5 硬编码；键前缀来自 env 的 QINIU_HHSJ_KEY_PREFIX）
const FIXED_APK_NAME = "huanhuashijie.apk";
const VERSION_JSON_NAME = "app_version.json";
const KEEP_APK_NAME = "app-arm64-v8a-release.apk";

const UC_HOST = "uc.qbox.me";
// 七牛 CDN(融合 CDN)刷新 API:旧域名 cdn.qiniuapi.com 已在公网 DNS 消失
// (NXDOMAIN,2026-10-22 首发 HTTP 0 ENOTFOUND 实证),现行端点=fusion.qiniuapi.com
const CDN_REFRESH_HOST = "fusion.qiniuapi.com";

// 七牛区域 -> 上传/管理域名（上传入口域名与下载域名无关）
const ZONE_UPLOAD_HOSTS = {
  z0: "upload.qiniup.com",
  z1: "upload-z1.qiniup.com",
  z2: "upload-z2.qiniup.com",
  na0: "upload-na0.qiniup.com",
  as0: "upload-as0.qiniup.com",
};
const ZONE_RS_HOSTS = {
  z0: "rs-z0.qbox.me",
  z1: "rs-z1.qbox.me",
  z2: "rs-z2.qbox.me",
  na0: "rs-na0.qbox.me",
  as0: "rs-as0.qbox.me",
};

const USAGE = `用法：node tool/release.mjs [选项]
  --version=x.y.z   显式指定版本（x.y.z），build 号仍自动 +1
  --no-bump         不改版本，按当前 version+build 原样重发
  --changelog="..." 更新说明，写入 app_version.json，缺省空串
  --dry-run         执行版本处理与 flutter build 并打印发布计划，跳过全部七牛网络操作
  --skip-build      跳过 flutter build 与产物清理，可与 --dry-run 组合
  --help            显示本帮助`;

// ---------- 日志 ----------

function log(msg) {
  process.stdout.write(`[release] ${msg}\n`);
}

function fail(msg) {
  process.stderr.write(`[release][error] ${msg}\n`);
  process.exit(1);
}

// ---------- 参数解析 ----------

function parseArgs(argv) {
  const opts = {
    explicitVersion: null, // string x.y.z 或 null
    noBump: false,
    changelog: "",
    dryRun: false,
    skipBuild: false,
    help: false,
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--help" || a === "-h") {
      opts.help = true;
    } else if (a === "--no-bump") {
      opts.noBump = true;
    } else if (a === "--dry-run") {
      opts.dryRun = true;
    } else if (a === "--skip-build") {
      opts.skipBuild = true;
    } else if (a.startsWith("--version=")) {
      opts.explicitVersion = a.slice("--version=".length).trim();
    } else if (a === "--version") {
      opts.explicitVersion = i + 1 < argv.length ? String(argv[++i]).trim() : "";
    } else if (a.startsWith("--changelog=")) {
      opts.changelog = a.slice("--changelog=".length);
    } else if (a === "--changelog") {
      opts.changelog = i + 1 < argv.length ? String(argv[++i]) : "";
    } else {
      throw new Error(`未知参数：${a}\n${USAGE}`);
    }
  }
  if (opts.explicitVersion !== null && !/^\d+\.\d+\.\d+$/.test(opts.explicitVersion)) {
    throw new Error(`--version 需为 x.y.z 形式（如 --version=1.2.3），当前值：${opts.explicitVersion}`);
  }
  if (opts.explicitVersion !== null && opts.noBump) {
    throw new Error(`--version 与 --no-bump 互斥，二选一\n${USAGE}`);
  }
  return opts;
}

// ---------- env 解析 ----------

// 格式：KEY=VALUE 每行一条，# 开头为注释；值仅去首尾空白，不做引号剥离
function parseEnvFile(file) {
  if (!fs.existsSync(file)) {
    throw new Error(
      `未找到环境变量文件：${file}\n` +
        `请创建该文件并配置 QINIU_HHSJ_ACCESS_KEY / QINIU_HHSJ_SECRET_KEY / QINIU_HHSJ_BUCKET / ` +
        `QINIU_HHSJ_ZONE / QINIU_HHSJ_CDN_BASE / QINIU_HHSJ_KEY_PREFIX（格式：KEY=VALUE，# 注释）`
    );
  }
  const text = fs.readFileSync(file, "utf8");
  const vars = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.replace(/\r/g, "").trim();
    if (!line || line.startsWith("#")) continue; // 忽略空行与注释
    const idx = line.indexOf("=");
    if (idx === -1) continue;
    const key = line.slice(0, idx).trim();
    if (!key) continue;
    vars[key] = line.slice(idx + 1).trim();
  }
  return vars;
}

function loadReleaseEnv(envFile = ENV_FILE) {
  const vars = parseEnvFile(envFile);
  const required = [
    "QINIU_HHSJ_ACCESS_KEY",
    "QINIU_HHSJ_SECRET_KEY",
    "QINIU_HHSJ_BUCKET",
    "QINIU_HHSJ_ZONE",
    "QINIU_HHSJ_CDN_BASE",
    "QINIU_HHSJ_KEY_PREFIX",
  ];
  const missing = required.filter((k) => !vars[k]);
  if (missing.length) {
    throw new Error(
      `缺少环境变量：${missing.join(" / ")}\n请在 ${envFile} 中补齐后重试`
    );
  }
  return {
    accessKey: vars.QINIU_HHSJ_ACCESS_KEY,
    secretKey: vars.QINIU_HHSJ_SECRET_KEY,
    bucket: vars.QINIU_HHSJ_BUCKET,
    zone: vars.QINIU_HHSJ_ZONE.trim().toLowerCase(),
    cdnBase: vars.QINIU_HHSJ_CDN_BASE.trim().replace(/\/+$/, ""),
    keyPrefix: vars.QINIU_HHSJ_KEY_PREFIX.trim().replace(/^\/+|\/+$/g, ""),
  };
}

function resolveUploadHost(zone) {
  const host = ZONE_UPLOAD_HOSTS[zone];
  if (!host) {
    throw new Error(
      `未知的 QINIU_HHSJ_ZONE：${zone}（可选值：${Object.keys(ZONE_UPLOAD_HOSTS).join(" / ")}）`
    );
  }
  return host;
}

function resolveRsHost(zone) {
  const host = ZONE_RS_HOSTS[zone];
  if (!host) {
    throw new Error(
      `未知的 QINIU_HHSJ_ZONE：${zone}（可选值：${Object.keys(ZONE_RS_HOSTS).join(" / ")}）`
    );
  }
  return host;
}

// ---------- 版本处理 ----------

// 解析 pubspec.yaml 的 version 行（x.y.z+n）
function parsePubspecVersion(text) {
  const m = text.match(/^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)[ \t]*$/m);
  if (!m) return null;
  return { major: +m[1], minor: +m[2], patch: +m[3], build: +m[4] };
}

// 计算目标版本：默认 patch+1/build+1；显式指定 x.y.z 时 build 仍 +1；--no-bump 原样
function computeTargetVersion({ current, explicitVersion = null, noBump = false }) {
  if (noBump) {
    return {
      version: `${current.major}.${current.minor}.${current.patch}`,
      build: current.build,
    };
  }
  const build = current.build + 1;
  const parts = explicitVersion
    ? explicitVersion.split(".").map(Number)
    : [current.major, current.minor, current.patch + 1];
  return { version: parts.join("."), build };
}

// 精确替换 ^version: 行（仅替换行内容本身，行终止符与其余内容字节不变）
function rewriteVersionLine(text, version, build) {
  const re = /^version:[^\r\n]*/m;
  if (!re.test(text)) {
    throw new Error("pubspec.yaml 中未找到 version 行，无法改写");
  }
  return text.replace(re, `version: ${version}+${build}`);
}

// ---------- 七牛签名与上传 ----------

// base64url：七牛 URLSafeBase64Encode 规范——标准 base64 后仅把 +/ 替换为 -_，保留 = 填充
// （注意：不同于 JWT 的去 padding 写法；HMAC 消息含 padding，去掉会导致签名与官方 SDK 不一致而 bad token）
function base64url(input) {
  const b64 = Buffer.isBuffer(input)
    ? input.toString("base64")
    : Buffer.from(input, "utf8").toString("base64");
  return b64.replace(/\+/g, "-").replace(/\//g, "_");
}

// 上传凭证：putPolicy = {"scope":"<bucket>:<key>","deadline":<now+3600>}
// （scope 锁 桶:键；勿设 insertOnly，允许覆盖同键；encodedPutPolicy = base64url(putPolicy)；
//   sign = base64url(HMAC-SHA1(SK, encodedPutPolicy))；token = "AK:sign:encodedPutPolicy"）
function buildUploadToken({ accessKey, secretKey, bucket, key, deadline }) {
  const putPolicy = JSON.stringify({
    scope: `${bucket}:${key}`,
    deadline: deadline || Math.floor(Date.now() / 1000) + 3600,
  });
  const encodedPutPolicy = base64url(putPolicy);
  const sign = crypto
    .createHmac("sha1", secretKey)
    .update(encodedPutPolicy, "utf8")
    .digest();
  const encodedSign = base64url(sign);
  const uploadToken = `${accessKey}:${encodedSign}:${encodedPutPolicy}`;
  return { putPolicy, encodedPutPolicy, uploadToken };
}

// 管理凭证（QBox）：signingStr = path + "\n" + body（body 为空时即 path + "\n"；
// query 为空不做拼接；json body 需计入签名）
function buildQboxAuthorization({ accessKey, secretKey, path: urlPath, body = "" }) {
  const signingStr = urlPath + "\n" + body;
  const sign = crypto
    .createHmac("sha1", secretKey)
    .update(signingStr, "utf8")
    .digest();
  const encodedSign = base64url(sign);
  return `QBox ${accessKey}:${encodedSign}`;
}

// 手工构造 multipart/form-data 的头尾（文件体以流的方式夹在中间，避免整包读进内存翻倍）
// 字段顺序：key、token、file
function buildMultipart({
  boundary,
  key,
  token,
  filename,
  fileSize,
  contentType = "application/vnd.android.package-archive",
}) {
  const head = Buffer.from(
    [
      `--${boundary}`,
      `Content-Disposition: form-data; name="key"`,
      ``,
      key,
      `--${boundary}`,
      `Content-Disposition: form-data; name="token"`,
      ``,
      token,
      `--${boundary}`,
      `Content-Disposition: form-data; name="file"; filename="${filename}"`,
      `Content-Type: ${contentType}`,
      ``,
      ``,
    ].join("\r\n"),
    "utf8"
  );
  const tail = Buffer.from(`\r\n--${boundary}--\r\n`, "utf8");
  return { head, tail, contentLength: head.length + fileSize + tail.length };
}

// 七牛表单直传（multipart 流式写入文件体）
function qiniuFormUpload({
  localPath,
  objectKey,
  uploadToken,
  host,
  fileContentType = "application/vnd.android.package-archive",
}) {
  return new Promise((resolve, reject) => {
    const fileSize = fs.statSync(localPath).size;
    const boundary =
      "----QiniuFormBoundary" + crypto.randomBytes(16).toString("hex");
    const { head, tail, contentLength } = buildMultipart({
      boundary,
      key: objectKey,
      token: uploadToken,
      filename: objectKey,
      fileSize,
      contentType: fileContentType,
    });
    log(
      `  文件大小 ${(fileSize / 1024 / 1024).toFixed(2)} MB，POST https://${host}/`
    );

    const req = https.request(
      {
        hostname: host,
        port: 443,
        path: "/",
        method: "POST",
        headers: {
          Host: host,
          "Content-Type": `multipart/form-data; boundary=${boundary}`,
          "Content-Length": contentLength,
        },
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () => {
          const text = Buffer.concat(chunks).toString("utf8");
          let parsed = null;
          try {
            parsed = text ? JSON.parse(text) : null;
          } catch {
            // 保留原始文本用于报错
          }
          if (res.statusCode === 200 && parsed && !parsed.error) {
            log(`  上传成功：${objectKey}（hash=${parsed.hash || "-"}）`);
            resolve(parsed);
          } else {
            reject(
              new Error(
                `七牛上传失败：HTTP ${res.statusCode} - ${text.slice(0, 500)}`
              )
            );
          }
        });
      }
    );
    req.on("error", reject);

    req.write(head);
    const stream = fs.createReadStream(localPath);
    stream.on("error", reject);
    stream.on("end", () => req.end(tail));
    stream.pipe(req, { end: false });
  });
}

// ---------- 七牛管理 API（QBox 签名） ----------

// 通用 https 请求：返回 { statusCode, body }；body 为字符串（可为空串）时计入 Content-Length
function managementRequest({
  hostname,
  urlPath,
  method = "GET",
  headers = {},
  body = null,
  timeoutMs = 15000,
}) {
  return new Promise((resolve, reject) => {
    const payload = body === null ? null : Buffer.from(body, "utf8");
    const req = https.request(
      {
        hostname,
        port: 443,
        path: urlPath,
        method,
        headers: payload
          ? { Host: hostname, ...headers, "Content-Length": payload.length }
          : { Host: hostname, ...headers },
        timeout: timeoutMs,
      },
      (res) => {
        const chunks = [];
        res.on("data", (c) => chunks.push(c));
        res.on("end", () =>
          resolve({
            statusCode: res.statusCode,
            body: Buffer.concat(chunks).toString("utf8"),
          })
        );
      }
    );
    req.on("timeout", () =>
      req.destroy(new Error(`请求超时（${timeoutMs}ms）：https://${hostname}${urlPath}`))
    );
    req.on("error", reject);
    if (payload) req.write(payload);
    req.end();
  });
}

// rs copy：POST /copy/<URLSafeBase64(srcBucket:srcKey)>/<URLSafeBase64(destBucket:destKey)>/force/true
// 成功 = HTTP 200 且（body 为空 或 JSON 无 error）；rs 成功时 body 为空是官方行为
async function rsCopy({ env, rsHost, srcKey, destKey }) {
  const entrySrc = `${env.bucket}:${srcKey}`;
  const entryDest = `${env.bucket}:${destKey}`;
  const urlPath = `/copy/${base64url(entrySrc)}/${base64url(entryDest)}/force/true`;
  const authorization = buildQboxAuthorization({
    accessKey: env.accessKey,
    secretKey: env.secretKey,
    path: urlPath,
    body: "",
  });
  const res = await managementRequest({
    hostname: rsHost,
    urlPath,
    method: "POST",
    headers: { Authorization: authorization, "Content-Type": "application/x-www-form-urlencoded" },
    body: "",
  });
  let parsed = null;
  try {
    parsed = res.body ? JSON.parse(res.body) : null;
  } catch {
    // 保留原始文本用于报错
  }
  if (res.statusCode === 200 && (res.body.trim() === "" || (parsed && !parsed.error))) {
    log(`  copy 成功：${srcKey} -> ${destKey}`);
    return;
  }
  throw new Error(`rs copy 失败：HTTP ${res.statusCode} - ${res.body.slice(0, 500)}`);
}

// CDN 刷新：POST https://fusion.qiniuapi.com/refresh（2026-10-22 首发实测：
// 旧域名 cdn.qiniuapi.com 公网 DNS 已 NXDOMAIN；且 QBox 签名串仅计入
// form-urlencoded 的 body——JSON body 不参与签名，签 body 会被 401 bad token，
// rs copy(表单空 body)同函数签名则 200，规则差异以此实证固化）
// 刷新是异步动作：失败只打印响应体不阻断（可人工到控制台补刷）
async function cdnRefresh({ env, urls }) {
  const urlPath = "/refresh";
  const body = JSON.stringify({ urls });
  const authorization = buildQboxAuthorization({
    accessKey: env.accessKey,
    secretKey: env.secretKey,
    path: urlPath,
    body: "", // JSON body 不计入 QBox 签名（见上注释）
  });
  try {
    const res = await managementRequest({
      hostname: CDN_REFRESH_HOST,
      urlPath,
      method: "POST",
      headers: { Authorization: authorization, "Content-Type": "application/json" },
      body,
    });
    return { ok: res.statusCode === 200, statusCode: res.statusCode, body: res.body };
  } catch (e) {
    return { ok: false, statusCode: 0, body: e.message };
  }
}

// zone 探测（尽力而为）：GET https://uc.qbox.me/v4/query?ak=<AK>&bucket=<bucket>
// 返回 { ok, region?, error? }，不 throw
async function probeZone({ accessKey, bucket }) {
  try {
    const urlPath = `/v4/query?ak=${encodeURIComponent(accessKey)}&bucket=${encodeURIComponent(bucket)}`;
    const res = await managementRequest({
      hostname: UC_HOST,
      urlPath,
      method: "GET",
      timeoutMs: 10000,
    });
    if (res.statusCode !== 200) {
      return { ok: false, error: `HTTP ${res.statusCode} - ${res.body.slice(0, 200)}` };
    }
    let parsed = null;
    try {
      parsed = JSON.parse(res.body);
    } catch {
      return { ok: false, error: `响应不是 JSON：${res.body.slice(0, 200)}` };
    }
    const host0 = parsed && Array.isArray(parsed.hosts) ? parsed.hosts[0] : null;
    if (!host0) return { ok: false, error: "响应中无 hosts" };
    let region = host0.region ? String(host0.region).toLowerCase() : null;
    if (!region && host0.up && Array.isArray(host0.up.domains)) {
      // 回退：从上传域名推断（upload.qiniup.com -> z0，upload-z2.qiniup.com -> z2）
      for (const d of host0.up.domains) {
        const m = String(d).match(/^upload(?:-([a-z0-9]+))?\.qiniup\.com$/i);
        if (m) {
          region = m[1] ? m[1].toLowerCase() : "z0";
          break;
        }
      }
    }
    if (!region) return { ok: false, error: "响应中未识别 region 字段" };
    return { ok: true, region };
  } catch (e) {
    return { ok: false, error: e.message };
  }
}

// ---------- 键名 / URL / JSON ----------

function buildObjectKeys({ keyPrefix, version }) {
  const p = String(keyPrefix).replace(/^\/+|\/+$/g, "");
  return {
    versionedApk: `${p}/huanhuashijie-${version}.apk`,
    fixedApk: `${p}/${FIXED_APK_NAME}`,
    versionJson: `${p}/${VERSION_JSON_NAME}`,
  };
}

function buildPublicUrls({ cdnBase, keyPrefix, version }) {
  const base = String(cdnBase).replace(/\/+$/, "");
  const { versionedApk, fixedApk, versionJson } = buildObjectKeys({ keyPrefix, version });
  return {
    versionedApk: `${base}/${versionedApk}`,
    fixedApk: `${base}/${fixedApk}`,
    versionJson: `${base}/${versionJson}`,
  };
}

// ---------- flutter build ----------

function flutterBuild() {
  log("开始 flutter build apk --release --split-per-abi");
  const cmd = process.platform === "win32" ? "flutter.bat" : "flutter";
  const res = spawnSync(cmd, ["build", "apk", "--release", "--split-per-abi"], {
    cwd: projectRoot,
    stdio: "inherit",
    shell: true,
  });
  if (res.status !== 0) throw new Error(`flutter build 失败，退出码 ${res.status}`);
  log("flutter build 完成");
}

// 只保留 arm64 产物，删除其余 ABI 产物
function cleanApkOutputs(keepFile) {
  const apkDir = path.join(projectRoot, "build", "app", "outputs", "flutter-apk");
  if (!fs.existsSync(apkDir)) throw new Error(`未找到 APK 输出目录：${apkDir}`);
  const keepPath = path.join(apkDir, keepFile);
  if (!fs.existsSync(keepPath)) throw new Error(`未找到目标产物：${keepPath}`);

  for (const name of fs.readdirSync(apkDir)) {
    if (name === keepFile) continue;
    const p = path.join(apkDir, name);
    try {
      fs.rmSync(p, { recursive: true, force: true });
    } catch (e) {
      log(`清理失败（忽略）：${p} - ${e.message}`);
    }
  }
  log(`已保留产物：${keepPath}`);
  return keepPath;
}

// ---------- 签名 / 包名闸 ----------
// 自 0.1.9 起 release 由正式证书签名(scripts/env/huanhuashijie-release.jks)。
// keystore.properties 缺失时 gradle 会回退 debug 签名——那种包与 App 备案登记的公钥/证书
// MD5 不一致,也无法覆盖升级既有安装,绝不能发出去,故在真正上传前拦一道。
// 工具缺失或解析失败一律放行(只告警),仅在"确认读到不匹配的值"时中止。
const EXPECTED_CERT_MD5 = "9467fc1b5be3b57d5ae7cdf3cb58da57";
const EXPECTED_APP_ID = "com.taoxiplan.huanhuashijie";

function findBuildToolsDir() {
  const sdk = process.env.ANDROID_HOME || process.env.ANDROID_SDK_ROOT;
  if (!sdk) return null;
  const btDir = path.join(sdk, "build-tools");
  if (!fs.existsSync(btDir)) return null;
  const versions = fs
    .readdirSync(btDir)
    .filter((v) => /^\d+\.\d+\.\d+$/.test(v))
    .sort((a, b) => {
      const [a1, a2, a3] = a.split(".").map(Number);
      const [b1, b2, b3] = b.split(".").map(Number);
      return a1 - b1 || a2 - b2 || a3 - b3;
    });
  for (let i = versions.length - 1; i >= 0; i--) {
    const dir = path.join(btDir, versions[i]);
    if (toolPath(dir, "apksigner")) return dir;
  }
  return null;
}

// apksigner 在 Windows 是 .bat、aapt2 是 .exe，按候选后缀取第一个存在的
function toolPath(dir, name) {
  const candidates =
    process.platform === "win32" ? [`${name}.bat`, `${name}.exe`, name] : [name];
  for (const c of candidates) {
    const p = path.join(dir, c);
    if (fs.existsSync(p)) return p;
  }
  return null;
}

function runTool(dir, name, args) {
  const exe = toolPath(dir, name);
  if (!exe) return null;
  const res = spawnSync(`"${exe}" ${args}`, { shell: true, encoding: "utf8" });
  return { status: res.status, out: `${res.stdout || ""}${res.stderr || ""}` };
}

function verifyApkArtifact(apkPath) {
  const btDir = findBuildToolsDir();
  if (!btDir) {
    log("[warn] 未找到 Android build-tools（ANDROID_HOME/ANDROID_SDK_ROOT），跳过签名与包名校验");
    return;
  }

  const sign = runTool(btDir, "apksigner", `verify --print-certs "${apkPath}"`);
  if (!sign || sign.status !== 0) {
    log(`[warn] apksigner 执行失败，跳过签名校验（请人工确认证书）`);
  } else {
    const md5 = (sign.out.match(/certificate MD5 digest:\s*([0-9a-f]{32})/i) || [])[1];
    const dn = (sign.out.match(/certificate DN:\s*(.+)/i) || [])[1];
    if (!md5) {
      log("[warn] 未能从 apksigner 输出解析证书 MD5，跳过签名校验");
    } else if (md5.toLowerCase() !== EXPECTED_CERT_MD5) {
      throw new Error(
        `APK 签名证书不匹配：实际 MD5=${md5.toLowerCase()}（DN=${dn ? dn.trim() : "未知"}），` +
          `期望 ${EXPECTED_CERT_MD5}。\n` +
          "  多半是 scripts/env/keystore.properties 缺失导致 gradle 回退 debug 签名；" +
          "该包与 App 备案登记的公钥/MD5 不一致，且无法覆盖升级既有安装，禁止发布。"
      );
    } else {
      log(`签名校验通过：证书 MD5=${md5.toLowerCase()}（${dn ? dn.trim() : "DN 未知"}）`);
    }
  }

  const badging = runTool(btDir, "aapt2", `dump badging "${apkPath}"`);
  const pkg = badging && badging.out.match(/package: name='([^']+)'/);
  if (!pkg) {
    log("[warn] aapt2 未能读取包名，跳过包名校验");
  } else if (pkg[1] !== EXPECTED_APP_ID) {
    throw new Error(
      `APK 包名不匹配：实际 ${pkg[1]}，期望 ${EXPECTED_APP_ID}。可能是 --skip-build 复用了旧产物。`
    );
  } else {
    log(`包名校验通过：${pkg[1]}`);
  }
}

// ---------- 发布计划打印 ----------

function printPlan({ env, uploadHost, rsHost, target, changelog, keys, urls, versionJson, apkPath, dryRun }) {
  log("========== 发布计划" + (dryRun ? "（dry-run）" : "") + " ==========");
  log(`  版本：${target.version}+${target.build}，changelog=${JSON.stringify(changelog)}`);
  log(`  APK 本地产物：${apkPath || "（无，不上传）"}`);
  log(`  桶：${env.bucket}，zone：${env.zone}（upload ${uploadHost} / rs ${rsHost}）`);
  log("  对象键：");
  log(`    版本化 APK：${keys.versionedApk}`);
  log(`    固定名 APK：${keys.fixedApk}`);
  log(`    版本 JSON：${keys.versionJson}`);
  log(`  双命名 copy：${keys.versionedApk} -> ${keys.fixedApk}（force=true，不二次上传）`);
  log("  app_version.json 内容：");
  for (const line of versionJson.replace(/\n$/, "").split("\n")) {
    log(`    ${line}`);
  }
  log("  CDN 刷新 URL（仅固定名两件；版本化键名唯一不刷）：");
  log(`    - ${urls.fixedApk}`);
  log(`    - ${urls.versionJson}`);
  log(`  新用户直链：${urls.fixedApk}`);
  log(`  版本 JSON 地址：${urls.versionJson}`);
  log("==========================================");
}

// ---------- 主流程 ----------

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    process.stdout.write(USAGE + "\n");
    return;
  }

  const modeTags = [];
  if (opts.dryRun) modeTags.push("dry-run");
  if (opts.skipBuild) modeTags.push("skip-build");
  if (opts.noBump) modeTags.push("no-bump");
  if (opts.explicitVersion) modeTags.push(`version=${opts.explicitVersion}`);
  log(
    `启动${modeTags.length ? `（${modeTags.join("，")}）` : "（默认：patch+1、build+1）"}`
  );

  // 1. 凭证与配置（fail fast；绝不硬编码）
  const env = loadReleaseEnv(ENV_FILE);
  const uploadHost = resolveUploadHost(env.zone);
  const rsHost = resolveRsHost(env.zone);
  log(`桶=${env.bucket}，zone=${env.zone}（upload ${uploadHost} / rs ${rsHost}）`);
  log(`CDN=${env.cdnBase}，键前缀=${env.keyPrefix}/`);

  // 2. 版本处理：dry-run 也真实改写 pubspec（验证改写逻辑），结束时在 finally 还原
  const pubspecBefore = fs.readFileSync(PUBSPEC_FILE, "utf8");
  const current = parsePubspecVersion(pubspecBefore);
  if (!current) {
    throw new Error(
      `pubspec.yaml 中未找到合法 version 行（期望 x.y.z+n）：${PUBSPEC_FILE}`
    );
  }
  const target = computeTargetVersion({
    current,
    explicitVersion: opts.explicitVersion,
    noBump: opts.noBump,
  });
  log(
    `版本：${current.major}.${current.minor}.${current.patch}+${current.build} -> ${target.version}+${target.build}` +
      (opts.noBump ? "（--no-bump 原样重发）" : "")
  );
  fs.writeFileSync(PUBSPEC_FILE, rewriteVersionLine(pubspecBefore, target.version, target.build), "utf8");
  log(
    `已改写 pubspec.yaml：version: ${target.version}+${target.build}` +
      (opts.dryRun ? "（dry-run 结束时还原）" : "")
  );

  try {
    // 3. zone 探测（dry-run 跳过全部七牛网络操作；探测结果与 env 不一致打警告但按 env 继续）
    if (!opts.dryRun) {
      const probe = await probeZone({ accessKey: env.accessKey, bucket: env.bucket });
      if (probe.ok && probe.region !== env.zone) {
        log(`[warn] uc 探测 zone=${probe.region} 与 env 配置 ${env.zone} 不一致，按 env 继续`);
      } else if (probe.ok) {
        log(`uc 探测 zone=${probe.region}，与 env 配置一致`);
      } else {
        log(`[warn] uc 探测失败（按 env 继续）：${probe.error}`);
      }
    }

    // 4. 打包（--skip-build 跳过构建与产物清理，产物不存在时不再报错）
    let apkPath = null;
    if (opts.skipBuild) {
      log("跳过 flutter build 与产物清理（--skip-build）");
    } else {
      flutterBuild();
      apkPath = cleanApkOutputs(KEEP_APK_NAME);
    }

    // 5. 对象键 / URL / JSON 内容
    const keys = buildObjectKeys({ keyPrefix: env.keyPrefix, version: target.version });
    const urls = buildPublicUrls({
      cdnBase: env.cdnBase,
      keyPrefix: env.keyPrefix,
      version: target.version,
    });
    const versionJsonText = JSON.stringify(
      {
        version: target.version,
        build: target.build,
        changelog: opts.changelog,
        force: false,
        android: { url: urls.versionedApk },
      },
      null,
      2
    ) + "\n";

    // 6. 本地版本化副本（F1-3：复制保留产物为 huanhuashijie-<version>.apk）
    const versionedLocalName = `huanhuashijie-${target.version}.apk`;
    if (!apkPath && opts.skipBuild) {
      const expected = path.join(projectRoot, "build", "app", "outputs", "flutter-apk", KEEP_APK_NAME);
      if (fs.existsSync(expected)) {
        apkPath = expected;
        log(`（--skip-build）使用已有产物：${expected}`);
      } else if (opts.dryRun) {
        log(`[warn] 未找到已有产物（${expected}），dry-run 仅打印计划`);
      } else {
        throw new Error(
          `未找到 APK 产物：${expected}（--skip-build 下不执行构建；请先构建或去掉 --skip-build）`
        );
      }
    }
    if (apkPath) {
      const versionedLocal = path.join(path.dirname(apkPath), versionedLocalName);
      fs.copyFileSync(apkPath, versionedLocal);
      log(`已复制版本化副本：${versionedLocal}`);
      apkPath = versionedLocal;
    }

    // 7. 打印发布计划（dry-run 到此为止）
    printPlan({
      env,
      uploadHost,
      rsHost,
      target,
      changelog: opts.changelog,
      keys,
      urls,
      versionJson: versionJsonText,
      apkPath,
      dryRun: opts.dryRun,
    });
    if (opts.dryRun) {
      log("dry-run 完成：未执行任何七牛网络操作");
      return;
    }

    // 7.5 上传前闸：证书 MD5 与包名必须与 App 备案登记口径一致
    if (apkPath) verifyApkArtifact(apkPath);

    // 8. 上传版本化 APK（scope 锁 桶:键，允许覆盖）
    log(`直传版本化 APK：${keys.versionedApk}`);
    const apkToken = buildUploadToken({
      accessKey: env.accessKey,
      secretKey: env.secretKey,
      bucket: env.bucket,
      key: keys.versionedApk,
    }).uploadToken;
    await qiniuFormUpload({
      localPath: apkPath,
      objectKey: keys.versionedApk,
      uploadToken: apkToken,
      host: uploadHost,
    });

    // 9. rs copy 固定名包（force 覆盖，不二次上传）
    log(`copy 固定名包：${keys.versionedApk} -> ${keys.fixedApk}（force=true）`);
    await rsCopy({ env, rsHost, srcKey: keys.versionedApk, destKey: keys.fixedApk });

    // 10. 生成并上传版本 JSON（同表单直传，scope 锁键）
    const jsonLocal = path.join(path.dirname(apkPath), VERSION_JSON_NAME);
    fs.writeFileSync(jsonLocal, versionJsonText, "utf8");
    log(`直传版本 JSON：${keys.versionJson}`);
    const jsonToken = buildUploadToken({
      accessKey: env.accessKey,
      secretKey: env.secretKey,
      bucket: env.bucket,
      key: keys.versionJson,
    }).uploadToken;
    await qiniuFormUpload({
      localPath: jsonLocal,
      objectKey: keys.versionJson,
      uploadToken: jsonToken,
      host: uploadHost,
      fileContentType: "application/json",
    });

    // 11. CDN 刷新固定名 APK 与 JSON（失败不阻断，异步可人工补刷）
    log(`CDN 刷新：${urls.fixedApk} 与 ${urls.versionJson}`);
    const refresh = await cdnRefresh({ env, urls: [urls.fixedApk, urls.versionJson] });
    if (refresh.ok) {
      log(`CDN 刷新已受理：HTTP ${refresh.statusCode}${refresh.body ? ` - ${refresh.body.slice(0, 200)}` : ""}`);
    } else {
      log(
        `[warn] CDN 刷新失败（不阻断，可人工到七牛控制台补刷）：HTTP ${refresh.statusCode} - ${refresh.body.slice(0, 500)}`
      );
    }

    // 12. 收尾打印
    log("发布完成");
    log(`  新用户直链：${urls.fixedApk}`);
    log(`  版本 JSON 地址：${urls.versionJson}`);
    log(`  对象键：${keys.versionedApk} | ${keys.fixedApk} | ${keys.versionJson}`);
    log(`  版本：${target.version}+${target.build}${opts.changelog ? `（changelog：${opts.changelog}）` : ""}`);
  } finally {
    if (opts.dryRun) {
      fs.writeFileSync(PUBSPEC_FILE, pubspecBefore, "utf8");
      log("已还原 pubspec.yaml（dry-run 不保留版本改写）");
    }
  }
}

// 导出供本地自测（不发起任何网络请求）；直接运行本脚本时才执行 main
export {
  USAGE,
  parseArgs,
  parseEnvFile,
  loadReleaseEnv,
  resolveUploadHost,
  resolveRsHost,
  parsePubspecVersion,
  computeTargetVersion,
  rewriteVersionLine,
  base64url,
  buildUploadToken,
  buildQboxAuthorization,
  buildMultipart,
  buildObjectKeys,
  buildPublicUrls,
};

if (
  process.argv[1] &&
  import.meta.url === pathToFileURL(path.resolve(process.argv[1])).href
) {
  main().catch((e) => fail(e.stack || e.message));
}
