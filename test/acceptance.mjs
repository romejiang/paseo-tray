import { spawn } from "node:child_process";
import { mkdir, rename, rm, writeFile } from "node:fs/promises";
import path from "node:path";
import readline from "node:readline";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const tray = path.join(root, "tray/build/PaseoTray.app/Contents/MacOS/PaseoTray");
const mockScript = path.join(root, "test/mock-daemon.mjs");
const home = path.join(root, "test/.home");
const configPath = path.join(root, "test/.acceptance-config.json");
const port = Number(process.env.ACCEPTANCE_PORT ?? 6869);
const baseURL = `http://127.0.0.1:${port}`;

const failures = [];
let mock = null;
let trayProcess = null;
let trayLines = null;
const events = [];
const waiters = new Set();

function log(message) {
  console.log(message);
}

function pass(name, detail = "") {
  console.log(`PASS  ${name}${detail ? ` — ${detail}` : ""}`);
}

function fail(name, detail) {
  failures.push(`${name}: ${detail}`);
  console.log(`FAIL  ${name} — ${detail}`);
}

function assert(name, condition, detail) {
  if (condition) pass(name, detail);
  else fail(name, detail);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate, timeout = 8_000, label = "event") {
  const existing = events.findIndex(predicate);
  if (existing >= 0) {
    return events.splice(existing, 1)[0];
  }
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      waiters.delete(check);
      reject(new Error(`timed out waiting for ${label}`));
    }, timeout);
    const check = () => {
      const index = events.findIndex(predicate);
      if (index < 0) return;
      clearTimeout(timer);
      waiters.delete(check);
      resolve(events.splice(index, 1)[0]);
    };
    waiters.add(check);
    check();
  });
}

function drainEvents() {
  events.length = 0;
}

async function startMock(extraEnv = {}) {
  const child = spawn(process.execPath, [mockScript], {
    env: {
      ...process.env,
      MOCK_HOME: home,
      MOCK_PORT: String(port),
      ...extraEnv,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  child.stdout.on("data", (chunk) => process.stdout.write(`[mock] ${chunk}`));
  child.stderr.on("data", (chunk) => process.stderr.write(`[mock] ${chunk}`));
  for (let attempt = 0; attempt < 50; attempt += 1) {
    try {
      const response = await fetch(`${baseURL}/health`);
      if (response.ok) return child;
    } catch {
      // not ready yet
    }
    await sleep(100);
  }
  throw new Error("mock daemon did not become healthy");
}

async function stopMock(child) {
  if (!child || child.exitCode !== null) return;
  child.kill("SIGTERM");
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 2_000);
    child.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

async function post(pathname, body) {
  const response = await fetch(`${baseURL}${pathname}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${pathname} returned ${response.status}`);
  return response.json();
}

async function setConfig(values) {
  await mkdir(path.dirname(configPath), { recursive: true });
  const temporary = `${configPath}.${process.pid}.${Date.now()}.tmp`;
  await writeFile(temporary, `${JSON.stringify(values, null, 2)}\n`, { mode: 0o644 });
  await rename(temporary, configPath);
}

function startTray() {
  trayProcess = spawn(tray, ["--watch-json"], {
    env: {
      ...process.env,
      PASEO_HOME: home,
      PASEOTRAY_CONFIG_PATH: configPath,
    },
    stdio: ["ignore", "pipe", "pipe"],
  });
  trayLines = readline.createInterface({ input: trayProcess.stdout });
  trayLines.on("line", (line) => {
    try {
      const event = JSON.parse(line);
      events.push(event);
      for (const waiter of [...waiters]) waiter();
    } catch {
      // Ignore non-JSON diagnostics.
    }
  });
  trayProcess.stderr.on("data", (chunk) => process.stderr.write(`[tray] ${chunk}`));
  return trayProcess;
}

async function stopTray() {
  if (!trayProcess || trayProcess.exitCode !== null) return;
  trayProcess.kill("SIGTERM");
  await new Promise((resolve) => {
    const timer = setTimeout(resolve, 1_500);
    trayProcess.once("exit", () => {
      clearTimeout(timer);
      resolve();
    });
  });
}

function counts(event) {
  return event.counts ?? {};
}

function order(event) {
  return event.order ?? {};
}

function agent(id, overrides = {}) {
  const now = Date.now();
  return {
    id,
    title: id,
    provider: "mock",
    status: "idle",
    activeTurn: null,
    requiresAttention: false,
    attentionReason: null,
    attentionTimestamp: null,
    pendingPermissions: [],
    labels: {},
    background: false,
    internal: false,
    archivedAt: null,
    updatedAt: new Date(now - 60_000).toISOString(),
    createdAt: new Date(now - 3_600_000).toISOString(),
    ...overrides,
  };
}

function running(id, minutesAgo, overrides = {}) {
  return agent(id, {
    status: "running",
    activeTurn: {
      turnId: `turn-${id}`,
      startedAt: new Date(Date.now() - minutesAgo * 60_000).toISOString(),
    },
    ...overrides,
  });
}

function finished(id, minutesAgo, overrides = {}) {
  return agent(id, {
    requiresAttention: true,
    attentionReason: "finished",
    attentionTimestamp: new Date(Date.now() - minutesAgo * 60_000).toISOString(),
    ...overrides,
  });
}

async function run() {
  await rm(home, { recursive: true, force: true });
  await rm(configPath, { force: true });
  await setConfig({
    showRunningCount: true,
    showFinishedCount: true,
    notifyOnFinish: false,
    notifyOnError: false,
    notifyOnPermission: false,
    playSound: false,
    includeSubagents: false,
  });

  mock = await startMock();
  startTray();

  const initialConfig = await waitFor((event) => event.event === "config", 5_000, "initial config");
  assert(
    "config watcher sees the shared file",
    initialConfig.config.notifyOnFinish === false,
    configPath,
  );

  const empty = await waitFor((event) => event.event === "snapshot", 8_000, "empty snapshot");
  assert(
    "1. empty daemon shows zero counts",
    counts(empty).total === 0 && counts(empty).running === 0 && counts(empty).finished === 0,
    JSON.stringify(counts(empty)),
  );
  assert("server id comes from server_info", empty.serverId === "srv_mock", empty.serverId);

  const orphanTimestamp = new Date(Date.now() - 60_000).toISOString();
  await post("/attention-orphan", {
    agentId: "late",
    reason: "finished",
    timestamp: orphanTimestamp,
  });
  const orphanAnnounce = await waitFor(
    (event) => event.event === "announce" && event.agentId === "late",
    5_000,
    "orphan announce",
  );
  assert(
    "1b. attention before snapshot still announces",
    orphanAnnounce.flashed === !orphanAnnounce.suppressedFrontmost,
    `flashed=${orphanAnnounce.flashed} frontmost=${orphanAnnounce.suppressedFrontmost}`,
  );
  await post("/upsert", { agent: running("late", 1) });
  const lateUpdate = await waitFor(
    (event) =>
      event.event === "update" &&
      counts(event).finished === 1 &&
      order(event).attention.includes("late"),
    5_000,
    "late attention merge",
  );
  assert(
    "1c. pending attention merges into the next upsert",
    counts(lateUpdate).finished === 1,
    JSON.stringify(counts(lateUpdate)),
  );
  await sleep(0.4);
  assert(
    "1d. orphan attention announces exactly once",
    !events.some((event) => event.event === "announce" && event.agentId === "late"),
    "no duplicate announce",
  );
  await post("/clear-attention", { agentId: "late" });
  await waitFor(
    (event) => event.event === "update" && counts(event).total === 0,
    5_000,
    "late cleared",
  );

  await post("/upsert", { agent: running("mock-running", 5) });
  const runningEvent = await waitFor(
    (event) => event.event === "update" && counts(event).running === 1,
    5_000,
    "running update",
  );
  assert(
    "2. running agent increments the running count",
    order(runningEvent).running[0] === "mock-running",
    JSON.stringify(order(runningEvent).running),
  );

  const finishTimestamp = new Date(Date.now() - 2 * 60_000).toISOString();
  await post("/attention", {
    agentId: "mock-running",
    reason: "finished",
    timestamp: finishTimestamp,
  });
  const finishEvent = await waitFor(
    (event) =>
      event.event === "attention" &&
      event.agentId === "mock-running" &&
      event.reason === "finished",
    5_000,
    "finished event",
  );
  assert(
    "3. attention(finished) moves the agent to finished",
    counts(finishEvent).finished === 1 && counts(finishEvent).running === 0,
    JSON.stringify(counts(finishEvent)),
  );
  assert(
    "3b. notifications are off by default",
    finishEvent.notifyEnabled === false,
    `notifyEnabled=${finishEvent.notifyEnabled}`,
  );
  const finishAnnounce = await waitFor(
    (event) =>
      event.event === "announce" &&
      event.agentId === "mock-running" &&
      event.reason === "finished",
    5_000,
    "finished announce",
  );
  assert(
    "3d. new attention flashes when Paseo is not frontmost",
    finishAnnounce.flashed === !finishAnnounce.suppressedFrontmost,
    `flashed=${finishAnnounce.flashed} frontmost=${finishAnnounce.suppressedFrontmost}`,
  );
  await post("/attention", {
    agentId: "mock-running",
    reason: "finished",
    timestamp: finishTimestamp,
  });
  await sleep(0.6);
  assert(
    "3e. duplicate attention does not announce twice",
    !events.some(
      (event) =>
        event.event === "announce" &&
        event.agentId === "mock-running" &&
        event.reason === "finished" &&
        event.timestamp === finishTimestamp,
    ),
    "no duplicate announce",
  );

  await setConfig({
    showRunningCount: true,
    showFinishedCount: true,
    notifyOnFinish: true,
    notifyOnError: false,
    notifyOnPermission: false,
    playSound: false,
    includeSubagents: false,
  });
  const changedConfig = await waitFor(
    (event) => event.event === "config" && event.config.notifyOnFinish === true,
    3_000,
    "config change",
  );
  assert(
    "9. config change reaches the tray within one second",
    changedConfig.config.notifyOnFinish === true,
    "notifyOnFinish=true",
  );

  await post("/upsert", { agent: running("mock-finish-2", 1) });
  await waitFor((event) => event.event === "update" && counts(event).running === 1, 5_000, "second running");
  await post("/attention", {
    agentId: "mock-finish-2",
    reason: "finished",
    timestamp: new Date().toISOString(),
  });
  const notified = await waitFor(
    (event) => event.event === "attention" && event.agentId === "mock-finish-2",
    5_000,
    "second finished event",
  );
  assert(
    "3c. enabling notifyOnFinish makes the finish event notifiable",
    notified.notifyEnabled === true &&
      notified.wouldNotify === !notified.paseoFrontmost,
    `enabled=${notified.notifyEnabled} frontmost=${notified.paseoFrontmost}`,
  );

  await post("/upsert", { agent: agent("mock-permission") });
  await post("/attention", {
    agentId: "mock-permission",
    reason: "permission",
    timestamp: new Date(Date.now() - 3 * 60_000).toISOString(),
  });
  const permissionEvent = await waitFor(
    (event) => event.event === "attention" && event.reason === "permission",
    5_000,
    "permission event",
  );
  assert(
    "4. permission maps to needs_input",
    counts(permissionEvent).needsInput === 1 &&
      order(permissionEvent).needsInput[0] === "mock-permission",
    JSON.stringify(counts(permissionEvent)),
  );

  await post("/clear-attention", { agentId: "mock-running" });
  await post("/clear-attention", { agentId: "mock-finish-2" });
  await post("/clear-attention", { agentId: "mock-permission" });
  const cleared = await waitFor(
    (event) => event.event === "update" && counts(event).total === 0,
    5_000,
    "cleared state",
  );
  assert(
    "5. clearing attention removes the counts",
    counts(cleared).finished === 0 && counts(cleared).needsInput === 0,
    JSON.stringify(counts(cleared)),
  );

  drainEvents();
  await post("/state", {
    agents: [
      running("run-old", 10),
      running("run-new", 5),
      finished("done-1", 20),
      finished("done-2", 10),
      agent("perm-1", {
        requiresAttention: true,
        attentionReason: "permission",
        attentionTimestamp: new Date(Date.now() - 15 * 60_000).toISOString(),
        pendingPermissions: [{ requestId: "p1" }],
      }),
      agent("fail-1", {
        status: "error",
        requiresAttention: true,
        attentionReason: "error",
        attentionTimestamp: new Date(Date.now() - 12 * 60_000).toISOString(),
      }),
      running("bg-1", 30, { background: true }),
      running("sub-1", 6, { labels: { "paseo.parent-agent-id": "run-old" } }),
      running("int-1", 40, { internal: true }),
      finished("arch-1", 60, { archivedAt: new Date().toISOString() }),
    ],
  });
  const multi = await waitFor(
    (event) =>
      event.event === "update" &&
      counts(event).running === 2 &&
      counts(event).finished === 2 &&
      counts(event).needsInput === 1 &&
      counts(event).failed === 1,
    5_000,
    "multi-agent state",
  );
  assert(
    "12. six visible agents across four buckets",
    counts(multi).total === 6,
    JSON.stringify(counts(multi)),
  );
  assert(
    "12b. needs_input sorts oldest first",
    JSON.stringify(order(multi).needsInput) === JSON.stringify(["perm-1"]),
    JSON.stringify(order(multi).needsInput),
  );
  assert(
    "12c. failed sorts before running",
    JSON.stringify(order(multi).failed) === JSON.stringify(["fail-1"]),
    JSON.stringify(order(multi).failed),
  );
  assert(
    "12d. running sorts by active turn start",
    JSON.stringify(order(multi).running) === JSON.stringify(["run-old", "run-new"]),
    JSON.stringify(order(multi).running),
  );
  assert(
    "12e. finished sorts newest first",
    JSON.stringify(order(multi).attention) === JSON.stringify(["done-2", "done-1"]),
    JSON.stringify(order(multi).attention),
  );
  assert(
    "12f. background, internal, subagent, and archived are hidden",
    !multi.agents.some((entry) =>
      ["bg-1", "int-1", "sub-1", "arch-1"].includes(entry.id),
    ),
    multi.agents.map((entry) => entry.id).join(","),
  );

  await setConfig({
    showRunningCount: true,
    showFinishedCount: true,
    notifyOnFinish: true,
    notifyOnError: false,
    notifyOnPermission: false,
    playSound: false,
    includeSubagents: true,
  });
  await waitFor((event) => event.event === "config" && event.config.includeSubagents === true, 3_000, "subagent config");
  await post("/upsert", { agent: running("run-old", 10) });
  const subagents = await waitFor(
    (event) => event.event === "update" && counts(event).running === 3,
    5_000,
    "subagent included",
  );
  assert(
    "12g. includeSubagents adds the child agent",
    order(subagents).running.includes("sub-1"),
    JSON.stringify(order(subagents).running),
  );

  log("... restarting mock daemon for reconnect test");
  await stopMock(mock);
  mock = null;
  const offline = await waitFor(
    (event) => event.event === "status" && event.phase === "offline",
    8_000,
    "offline status",
  );
  assert("6a. tray notices daemon loss", offline.phase === "offline", offline.detail);

  mock = await startMock();
  const reconnected = await waitFor(
    (event) => event.event === "status" && event.phase === "connected",
    20_000,
    "reconnected status",
  );
  assert("6b. tray reconnects after daemon restart", reconnected.phase === "connected", "connected");
  const resnapshot = await waitFor(
    (event) => event.event === "snapshot" && event.serverId === "srv_mock",
    10_000,
    "post-reconnect snapshot",
  );
  assert(
    "6c. reconnect re-subscribes and gets a fresh snapshot",
    counts(resnapshot).total === 0,
    JSON.stringify(counts(resnapshot)),
  );

  log("... testing rpc_error subscription retry");
  await stopMock(mock);
  mock = null;
  mock = await startMock({ MOCK_FAIL_FIRST_FETCH: "1" });
  const retryConnected = await waitFor(
    (event) => event.event === "status" && event.phase === "connected",
    20_000,
    "rpc retry connection",
  );
  assert("6d. tray reconnects for subscription retry", retryConnected.phase === "connected", "connected");
  const retryError = await waitFor(
    (event) =>
      event.event === "status" &&
      typeof event.subscriptionError === "string" &&
      event.subscriptionError.length > 0,
    10_000,
    "subscription rpc error",
  );
  assert(
    "6e. rpc_error is surfaced",
    retryError.subscriptionError.includes("mock fetch failed"),
    retryError.subscriptionError,
  );
  const retrySnapshot = await waitFor(
    (event) => event.event === "snapshot",
    10_000,
    "rpc retry snapshot",
  );
  assert(
    "6f. rpc_error retry recovers",
    counts(retrySnapshot).total === 0,
    JSON.stringify(counts(retrySnapshot)),
  );

  log("... testing timeout subscription retry");
  await stopMock(mock);
  mock = null;
  mock = await startMock({ MOCK_IGNORE_FIRST_FETCH: "1" });
  const timeoutConnected = await waitFor(
    (event) => event.event === "status" && event.phase === "connected",
    20_000,
    "timeout retry connection",
  );
  assert("6g. timeout retry starts on the same connection", timeoutConnected.phase === "connected", "connected");
  const timeoutError = await waitFor(
    (event) =>
      event.event === "status" &&
      typeof event.subscriptionError === "string" &&
      event.subscriptionError.includes("订阅超时"),
    15_000,
    "subscription timeout",
  );
  assert(
    "6h. timeout is surfaced and retried",
    timeoutError.subscriptionError.includes("正在重试"),
    timeoutError.subscriptionError,
  );
  const timeoutSnapshot = await waitFor(
    (event) => event.event === "snapshot",
    10_000,
    "timeout retry snapshot",
  );
  assert(
    "6i. timeout retry recovers",
    counts(timeoutSnapshot).total === 0,
    JSON.stringify(counts(timeoutSnapshot)),
  );

  log("... testing reconnect backoff after repeated subscription failure");
  drainEvents();
  await stopMock(mock);
  mock = null;
  mock = await startMock({ MOCK_ALWAYS_FAIL_FETCH: "1" });
  const backoffAttempts = [];
  const backoffTimes = [];
  for (let index = 0; index < 3; index += 1) {
    const offline = await waitFor(
      (event) =>
        event.event === "status" &&
        event.phase === "offline" &&
        typeof event.detail === "string" &&
        event.detail.includes("订阅失败"),
      20_000,
      `backoff offline ${index}`,
    );
    backoffAttempts.push(offline.attempt);
    backoffTimes.push(Date.now());
  }
  assert(
    "6j. reconnect attempts increase after repeated subscription failure",
    backoffAttempts[0] < backoffAttempts[1] && backoffAttempts[1] < backoffAttempts[2],
    JSON.stringify(backoffAttempts),
  );
  const intervals = backoffTimes.slice(1).map((time, index) => time - backoffTimes[index]);
  log(`... backoff attempts=${JSON.stringify(backoffAttempts)} intervals=${JSON.stringify(intervals)}ms`);

  log("");
  log("=== mock acceptance summary ===");
  if (failures.length === 0) {
    log("ALL PASS");
  } else {
    for (const failure of failures) log(`FAILED: ${failure}`);
    process.exitCode = 1;
  }
}

try {
  await run();
} catch (error) {
  fail("acceptance harness", error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
} finally {
  await stopTray();
  await stopMock(mock);
}
