import crypto from "node:crypto";
import { mkdir, writeFile } from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";
import { WebSocket, WebSocketServer } from "ws";

const port = Number(process.env.MOCK_PORT ?? 6868);
const home = path.resolve(process.env.MOCK_HOME ?? path.join(process.cwd(), ".home"));
const serverId = process.env.MOCK_SERVER_ID ?? "srv_mock";
const token = process.env.MOCK_TOKEN ?? crypto.randomBytes(32).toString("base64url");
const authMode = process.env.MOCK_AUTH_MODE ?? "";
const ignoreFetch = process.env.MOCK_IGNORE_FETCH === "1";
const hasMore = process.env.MOCK_HAS_MORE === "1";
const failFirstFetch = process.env.MOCK_FAIL_FIRST_FETCH === "1";
const ignoreFirstFetch = process.env.MOCK_IGNORE_FIRST_FETCH === "1";
const alwaysFailFetch = process.env.MOCK_ALWAYS_FAIL_FETCH === "1";

await mkdir(home, { recursive: true });
await writeFile(
  path.join(home, "paseo.pid"),
  JSON.stringify({
    pid: process.pid,
    startedAt: new Date().toISOString(),
    hostname: os.hostname(),
    uid: process.getuid?.() ?? 0,
    listen: `127.0.0.1:${port}`,
    serverId,
    desktopManaged: false,
    heartbeat: true,
  }),
);
await writeFile(path.join(home, "local-credential"), `${token}\n`, { mode: 0o600 });
await writeFile(
  path.join(home, "config.json"),
  JSON.stringify({ version: 1, daemon: { listen: `127.0.0.1:${port}` } }, null, 2),
);

const agents = new Map();
const agentSubscribers = new Map();
const eventSubscribers = new Map();
const fetchCounts = new WeakMap();
// Mirrors the real daemon: clients outside the Paseo app version series only
// see legacy providers unless hello declares `all_providers: true`.
const legacyProviders = new Set(["claude", "codex", "opencode"]);
const acceptsAllProviders = new WeakMap();

function isAgentVisible(ws, agent) {
  return legacyProviders.has(agent.provider) || acceptsAllProviders.get(ws) === true;
}

function makeAgent(input) {
  const now = new Date().toISOString();
  return {
    id: input.id,
    provider: input.provider ?? "opencode",
    cwd: input.cwd ?? "/tmp/mock-project",
    workspaceId: input.workspaceId ?? "wks_mock",
    model: input.model ?? "mock/model",
    createdAt: input.createdAt ?? now,
    updatedAt: input.updatedAt ?? now,
    lastUserMessageAt: input.lastUserMessageAt ?? now,
    status: input.status ?? "idle",
    activeTurn: input.activeTurn ?? null,
    capabilities: {},
    currentModeId: null,
    availableModes: [],
    pendingPermissions: input.pendingPermissions ?? [],
    persistence: null,
    title: input.title ?? input.id,
    labels: input.labels ?? {},
    requiresAttention: input.requiresAttention ?? false,
    attentionReason: input.attentionReason ?? null,
    attentionTimestamp: input.attentionTimestamp ?? null,
    archivedAt: input.archivedAt ?? null,
    background: input.background ?? false,
    internal: input.internal ?? false,
  };
}

function projectFor(agent) {
  return {
    projectKey: "prj_mock",
    projectName: "Paseo Tray Mock",
    workspaceName: "Mock Workspace",
    checkout: {
      cwd: agent.cwd,
      currentBranch: "main",
      remoteUrl: null,
      worktreeRoot: "/tmp",
      isGit: true,
      isPaseoOwnedWorktree: false,
      mainRepoRoot: null,
    },
  };
}

function send(ws, payload) {
  if (ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(payload));
  }
}

function sendSession(ws, message) {
  send(ws, { type: "session", message });
}

function broadcastAgent(agent) {
  for (const [ws, subscriptionId] of agentSubscribers) {
    if (!isAgentVisible(ws, agent)) continue;
    sendSession(ws, {
      type: "agent_update",
      payload: {
        subscriptionId,
        kind: "upsert",
        agent,
        project: projectFor(agent),
      },
    });
  }
}

function broadcastRemove(agentId) {
  for (const [ws, subscriptionId] of agentSubscribers) {
    sendSession(ws, {
      type: "agent_update",
      payload: { subscriptionId, kind: "remove", agentId },
    });
  }
}

function broadcastAttention(agentId, reason, timestamp) {
  for (const [ws, subscriptionId] of eventSubscribers) {
    sendSession(ws, {
      type: "agent_attention_required",
      payload: {
        subscriptionId,
        agentId,
        reason,
        timestamp,
        shouldNotify: false,
        notification: {
          title: "Agent needs attention",
          body: `Mock ${reason} event`,
          data: { serverId, agentId, reason },
        },
      },
    });
  }
}

const server = http.createServer(async (request, response) => {
  const url = new URL(request.url ?? "/", `http://127.0.0.1:${port}`);
  const json = (status, body) => {
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify(body));
  };
  const body = async () => {
    const chunks = [];
    for await (const chunk of request) chunks.push(chunk);
    if (chunks.length === 0) return {};
    return JSON.parse(Buffer.concat(chunks).toString("utf8"));
  };

  try {
    if (request.method === "GET" && url.pathname === "/health") {
      return json(200, { ok: true, serverId, agents: agents.size });
    }
    if (request.method === "GET" && url.pathname === "/state") {
      return json(200, {
        serverId,
        agents: [...agents.values()],
        agentSubscriptions: agentSubscribers.size,
        eventSubscriptions: eventSubscribers.size,
      });
    }
    if (request.method === "POST" && url.pathname === "/state") {
      const input = await body();
      const next = new Map();
      for (const item of input.agents ?? []) {
        const agent = makeAgent(item);
        next.set(agent.id, agent);
      }
      for (const id of agents.keys()) {
        if (!next.has(id)) broadcastRemove(id);
      }
      agents.clear();
      for (const [id, agent] of next) {
        agents.set(id, agent);
        broadcastAgent(agent);
      }
      return json(200, { ok: true, agents: agents.size });
    }
    if (request.method === "POST" && url.pathname === "/upsert") {
      const input = await body();
      const agent = makeAgent(input.agent ?? input);
      agents.set(agent.id, agent);
      broadcastAgent(agent);
      return json(200, { ok: true, agent });
    }
    if (request.method === "POST" && url.pathname === "/remove") {
      const input = await body();
      if (!input.agentId) return json(400, { error: "agentId required" });
      agents.delete(input.agentId);
      broadcastRemove(input.agentId);
      return json(200, { ok: true });
    }
    if (request.method === "POST" && url.pathname === "/attention") {
      const input = await body();
      const agent = agents.get(input.agentId);
      if (!agent) return json(404, { error: "unknown agent" });
      const timestamp = input.timestamp ?? new Date().toISOString();
      agent.requiresAttention = true;
      agent.attentionReason = input.reason;
      agent.attentionTimestamp = timestamp;
      agent.status = input.reason === "error" ? "error" : "idle";
      agent.activeTurn = null;
      if (input.reason === "permission" && agent.pendingPermissions.length === 0) {
        agent.pendingPermissions = [{ requestId: `mock-${Date.now()}` }];
      }
      agent.updatedAt = new Date().toISOString();
      broadcastAgent(agent);
      broadcastAttention(agent.id, input.reason, timestamp);
      return json(200, { ok: true, agent });
    }
    if (request.method === "POST" && url.pathname === "/attention-orphan") {
      const input = await body();
      if (!input.agentId || !input.reason) {
        return json(400, { error: "agentId and reason required" });
      }
      const timestamp = input.timestamp ?? new Date().toISOString();
      broadcastAttention(input.agentId, input.reason, timestamp);
      return json(200, { ok: true });
    }
    if (request.method === "POST" && url.pathname === "/clear-attention") {
      const input = await body();
      const agent = agents.get(input.agentId);
      if (!agent) return json(404, { error: "unknown agent" });
      agent.requiresAttention = false;
      agent.attentionReason = null;
      agent.attentionTimestamp = null;
      agent.pendingPermissions = [];
      agent.status = "idle";
      agent.activeTurn = null;
      agent.updatedAt = new Date().toISOString();
      broadcastAgent(agent);
      return json(200, { ok: true, agent });
    }
    if (request.method === "POST" && url.pathname === "/shutdown") {
      json(200, { ok: true });
      setTimeout(() => process.exit(0), 50);
      return;
    }
    return json(404, { error: "not found" });
  } catch (error) {
    return json(500, { error: error instanceof Error ? error.message : String(error) });
  }
});

const wss = new WebSocketServer({ server, path: "/ws" });

wss.on("connection", (ws) => {
  ws.on("message", (raw) => {
    let frame;
    try {
      frame = JSON.parse(raw.toString());
    } catch {
      return;
    }
    if (frame.type === "hello") {
      acceptsAllProviders.set(ws, frame.capabilities?.all_providers === true);
      if (authMode === "reject") {
        send(ws, { type: "hello.rejected", reason: "password_required", accepts: ["password"] });
        return;
      }
      if (authMode === "incompatible") {
        send(ws, { type: "hello.rejected", reason: "incompatible_protocol", accepts: [] });
        return;
      }
      sendSession(ws, {
        type: "status",
        payload: {
          status: "server_info",
          protocolVersion: 1,
          serverId,
          version: "0.14.0-mock",
          hostname: os.hostname(),
          desktopManaged: false,
          features: { ownedSubscriptions: true, explicitEventSubscriptions: true },
        },
      });
      return;
    }
    if (frame.type === "ping") {
      send(ws, { type: "pong" });
      return;
    }
    if (frame.type !== "session") return;
    const message = frame.message;
    if (message?.type === "fetch_agents_request") {
      if (alwaysFailFetch) {
        sendSession(ws, {
          type: "rpc_error",
          payload: {
            requestId: message.requestId,
            requestType: message.type,
            error: "mock fetch always fails",
            code: "mock_failure",
          },
        });
        return;
      }
      const count = (fetchCounts.get(ws) ?? 0) + 1;
      fetchCounts.set(ws, count);
      if (count === 1 && failFirstFetch) {
        sendSession(ws, {
          type: "rpc_error",
          payload: {
            requestId: message.requestId,
            requestType: message.type,
            error: "mock fetch failed",
            code: "mock_failure",
          },
        });
        return;
      }
      if (count === 1 && ignoreFirstFetch) return;
      if (ignoreFetch) return;
      const subscriptionId = `sub_${crypto.randomUUID()}`;
      agentSubscribers.set(ws, subscriptionId);
      sendSession(ws, {
        type: "fetch_agents_response",
        payload: {
          requestId: message.requestId,
          subscriptionId,
          entries: [...agents.values()]
            .filter((agent) => isAgentVisible(ws, agent))
            .map((agent) => ({
              agent,
              project: projectFor(agent),
            })),
          pageInfo: { nextCursor: null, prevCursor: null, hasMore },
        },
      });
      return;
    }
    if (message?.type === "session.events.set_subscription.request") {
      const subscriptionId = `evt_${crypto.randomUUID()}`;
      eventSubscribers.set(ws, subscriptionId);
      sendSession(ws, {
        type: "session.events.set_subscription.response",
        payload: { requestId: message.requestId, subscriptionId },
      });
    }
  });

  ws.on("close", () => {
    agentSubscribers.delete(ws);
    eventSubscribers.delete(ws);
  });
});

server.listen(port, "127.0.0.1", () => {
  console.log(`[mock] listening ws://127.0.0.1:${port}/ws home=${home} serverId=${serverId}`);
});

function shutdown() {
  for (const ws of wss.clients) ws.close();
  wss.close();
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(0), 500);
}

process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
