import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import path from "node:path";

const home = process.env.PASEO_HOME
  ? path.resolve(process.env.PASEO_HOME)
  : path.join(homedir(), ".paseo");
const pid = JSON.parse(readFileSync(path.join(home, "paseo.pid"), "utf8"));
const token = readFileSync(path.join(home, "local-credential"), "utf8").trim();
const configPath = path.join(
  homedir(),
  "Library",
  "Application Support",
  "PaseoTray",
  "config.json",
);

const socket = new WebSocket(`ws://${pid.listen}/ws`);
const pending = new Map();
let connected = false;
let nextId = 0;

function fail(message) {
  console.error(`FAIL  ${message}`);
  process.exitCode = 1;
}

function send(payload) {
  socket.send(JSON.stringify(payload));
}

function invoke(method, input) {
  const requestId = `probe-${++nextId}`;
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      pending.delete(requestId);
      reject(new Error(`timed out invoking ${method}`));
    }, 8_000);
    pending.set(requestId, {
      resolve: (value) => {
        clearTimeout(timer);
        resolve(value);
      },
      reject: (error) => {
        clearTimeout(timer);
        reject(error);
      },
    });
    send({
      type: "session",
      message: {
        type: "plugin.rpc.invoke.request",
        requestId,
        pluginId: "paseo-tray",
        method,
        input,
      },
    });
  });
}

function waitForConnected() {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => reject(new Error("timed out waiting for server_info")), 8_000);
    const check = () => {
      if (!connected) return;
      clearTimeout(timer);
      resolve();
    };
    connectedCheck = check;
    check();
  });
}

let connectedCheck = () => {};

socket.addEventListener("open", () => {
  send({
    type: "hello",
    clientId: `paseo-tray-probe-${Date.now()}`,
    clientType: "cli",
    protocolVersion: 1,
    appVersion: "0.1.0",
    auth: { kind: "localCredential", token },
    capabilities: {
      owned_subscriptions: true,
      explicit_event_subscriptions: true,
      hello_rejection: true,
    },
  });
});

socket.addEventListener("message", (event) => {
  const frame = JSON.parse(typeof event.data === "string" ? event.data : event.data.toString());
  if (frame.type !== "session") return;
  const message = frame.message;
  if (message.type === "status" && message.payload?.status === "server_info") {
    connected = true;
    connectedCheck();
    return;
  }
  if (message.type === "plugin.rpc.invoke.response") {
    const entry = pending.get(message.payload.requestId);
    if (!entry) return;
    pending.delete(message.payload.requestId);
    entry.resolve(message.payload.output);
    return;
  }
  if (message.type === "rpc_error") {
    const entry = pending.get(message.payload.requestId);
    if (!entry) return;
    pending.delete(message.payload.requestId);
    entry.reject(new Error(message.payload.error ?? "rpc_error"));
  }
});

socket.addEventListener("error", () => {
  console.error("FAIL  WebSocket error");
  process.exit(1);
});

await waitForConnected();
console.log(`connected to ${pid.listen} (${pid.serverId})`);

const read = await invoke("settings.tray.read", {});
if (read?.status !== "ready") {
  fail(`settings read returned ${JSON.stringify(read)}`);
  socket.close();
  process.exit(1);
}
const original = read.values;
console.log(`settings read: ready (notifyOnFinish=${original.notifyOnFinish})`);

let currentRevision = read.revision;
let restored = false;

try {
  const written = await invoke("settings.tray.write", {
    revision: currentRevision,
    values: { ...original, notifyOnFinish: true },
  });
  if (written?.status !== "saved") {
    fail(`settings write returned ${JSON.stringify(written)}`);
  } else {
    currentRevision = written.revision;
    console.log("settings write: saved (notifyOnFinish=true)");
  }

  const status = await invoke("tray.config.status", {});
  if (
    status?.ok === true &&
    typeof status.path === "string" &&
    status.path.endsWith("PaseoTray/config.json") &&
    typeof status.syncedAt === "string"
  ) {
    console.log(`PASS  tray.config.status ok path=${status.path} syncedAt=${status.syncedAt}`);
  } else {
    fail(`tray.config.status returned ${JSON.stringify(status)}`);
  }

  const appStatus = await invoke("tray.app.status", {});
  if (
    appStatus?.installed === true &&
    typeof appStatus.path === "string" &&
    typeof appStatus.version === "string"
  ) {
    console.log(
      `PASS  tray.app.status installed path=${appStatus.path} version=${appStatus.version}`,
    );
  } else {
    fail(`tray.app.status returned ${JSON.stringify(appStatus)}`);
  }

  const config = JSON.parse(readFileSync(configPath, "utf8"));
  if (config.notifyOnFinish === true) {
    console.log("PASS  config file contains notifyOnFinish=true");
  } else {
    fail(`config file notifyOnFinish=${config.notifyOnFinish}`);
  }

  const restoredWrite = await invoke("settings.tray.write", {
    revision: currentRevision,
    values: original,
  });
  if (restoredWrite?.status !== "saved") {
    fail(`restore write returned ${JSON.stringify(restoredWrite)}`);
  } else {
    currentRevision = restoredWrite.revision;
    restored = true;
    console.log(`settings restored (notifyOnFinish=${original.notifyOnFinish})`);
  }
} finally {
  if (!restored) {
    try {
      await invoke("settings.tray.write", {
        revision: currentRevision,
        values: original,
      });
      console.log("settings restored in finally");
    } catch (error) {
      console.error(`FAIL  could not restore settings: ${String(error)}`);
      process.exitCode = 1;
    }
  }
  socket.close();
}
