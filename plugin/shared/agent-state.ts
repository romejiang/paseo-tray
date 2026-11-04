export type AgentBucket = "needs_input" | "failed" | "running" | "attention" | "done";

/**
 * Structural subset of the daemon's AgentSnapshotPayload. Keeping this local
 * avoids importing @getpaseo/protocol into the client bundle.
 */
export interface AgentLike {
  readonly id: string;
  readonly title?: string | null;
  readonly provider: string;
  readonly status: string;
  readonly requiresAttention?: boolean;
  readonly attentionReason?: string | null;
  readonly attentionTimestamp?: string | null;
  readonly pendingPermissions?: readonly unknown[] | null;
  readonly labels?: Readonly<Record<string, string>> | null;
  readonly background?: boolean;
  readonly internal?: boolean;
  readonly archivedAt?: string | null;
  readonly activeTurn?: { readonly startedAt?: string | null } | null;
  readonly updatedAt: string;
  readonly createdAt?: string;
}

export function shortId(id: string): string {
  return id.slice(0, 8);
}

export function displayTitle(agent: AgentLike): string {
  const title = agent.title?.trim();
  return title && title.length > 0 ? title : shortId(agent.id);
}

export function deriveBucket(agent: AgentLike): AgentBucket {
  if ((agent.pendingPermissions?.length ?? 0) > 0 || agent.attentionReason === "permission") {
    return "needs_input";
  }
  if (agent.status === "error" || agent.attentionReason === "error") {
    return "failed";
  }
  if (agent.status === "running") {
    return "running";
  }
  if (agent.requiresAttention) {
    return "attention";
  }
  return "done";
}

export function isSubagent(agent: AgentLike): boolean {
  return (agent.labels?.["paseo.parent-agent-id"] ?? "").trim().length > 0;
}

export function isVisibleAgent(agent: AgentLike, includeSubagents: boolean): boolean {
  if (agent.background === true) return false;
  if (agent.internal === true) return false;
  if (agent.archivedAt) return false;
  if (!includeSubagents && isSubagent(agent)) return false;
  return deriveBucket(agent) !== "done";
}

export function menuTimestamp(agent: AgentLike): string {
  const bucket = deriveBucket(agent);
  if (bucket === "running") {
    return agent.activeTurn?.startedAt ?? agent.updatedAt;
  }
  if (bucket === "needs_input" || bucket === "failed" || bucket === "attention") {
    return agent.attentionTimestamp ?? agent.updatedAt;
  }
  return agent.updatedAt;
}

export function relativeTime(value: string | null | undefined, now = Date.now()): string {
  if (!value) return "";
  const timestamp = Date.parse(value);
  if (Number.isNaN(timestamp)) return "";
  const seconds = Math.max(0, Math.floor((now - timestamp) / 1000));
  if (seconds < 60) return `${seconds}s`;
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3600)}h`;
  return `${Math.floor(seconds / 86_400)}d`;
}

export interface AgentCounts {
  running: number;
  finished: number;
  needsInput: number;
  failed: number;
  actionable: number;
  total: number;
}

export interface AgentGroups {
  needsInput: AgentLike[];
  failed: AgentLike[];
  running: AgentLike[];
  attention: AgentLike[];
  counts: AgentCounts;
}

function timeOf(agent: AgentLike): number {
  const timestamp = Date.parse(menuTimestamp(agent));
  return Number.isNaN(timestamp) ? 0 : timestamp;
}

function ascendingByAttention(a: AgentLike, b: AgentLike): number {
  const left = Date.parse(a.attentionTimestamp ?? a.updatedAt);
  const right = Date.parse(b.attentionTimestamp ?? b.updatedAt);
  const safeLeft = Number.isNaN(left) ? 0 : left;
  const safeRight = Number.isNaN(right) ? 0 : right;
  if (safeLeft === safeRight) return timeOf(a) - timeOf(b);
  return safeLeft - safeRight;
}

function descendingByAttention(a: AgentLike, b: AgentLike): number {
  return -ascendingByAttention(a, b);
}

function ascendingByRun(a: AgentLike, b: AgentLike): number {
  const left = Date.parse(a.activeTurn?.startedAt ?? a.updatedAt);
  const right = Date.parse(b.activeTurn?.startedAt ?? b.updatedAt);
  const safeLeft = Number.isNaN(left) ? 0 : left;
  const safeRight = Number.isNaN(right) ? 0 : right;
  if (safeLeft === safeRight) return timeOf(a) - timeOf(b);
  return safeLeft - safeRight;
}

export function groupAgents(agents: readonly AgentLike[], includeSubagents: boolean): AgentGroups {
  const visible = agents.filter((agent) => isVisibleAgent(agent, includeSubagents));
  const counts: AgentCounts = {
    running: 0,
    finished: 0,
    needsInput: 0,
    failed: 0,
    actionable: 0,
    total: 0,
  };
  const groups: AgentGroups = {
    needsInput: [],
    failed: [],
    running: [],
    attention: [],
    counts,
  };
  for (const agent of visible) {
    switch (deriveBucket(agent)) {
      case "needs_input":
        groups.needsInput.push(agent);
        counts.needsInput += 1;
        break;
      case "failed":
        groups.failed.push(agent);
        counts.failed += 1;
        break;
      case "running":
        groups.running.push(agent);
        counts.running += 1;
        break;
      case "attention":
        groups.attention.push(agent);
        counts.finished += 1;
        break;
      case "done":
        break;
    }
  }
  groups.needsInput.sort(ascendingByAttention);
  groups.failed.sort(ascendingByAttention);
  groups.running.sort(ascendingByRun);
  groups.attention.sort(descendingByAttention);
  counts.actionable = counts.needsInput + counts.failed;
  counts.total = counts.running + counts.finished + counts.actionable;
  return groups;
}

export function countsFor(agents: readonly AgentLike[], includeSubagents: boolean): AgentCounts {
  return groupAgents(agents, includeSubagents).counts;
}
