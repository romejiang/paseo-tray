import { usePaseo } from "@getpaseo/plugin/client";
import { useCallback, useEffect, useState } from "react";
import { countsFor, type AgentCounts, type AgentLike } from "../shared/agent-state";

export interface AgentDirectoryState {
  entries: AgentLike[];
  hasMore: boolean;
  loading: boolean;
  error: string | null;
}

export interface AgentDirectory extends AgentDirectoryState {
  reload(): void;
}

const initialState: AgentDirectoryState = {
  entries: [],
  hasMore: false,
  loading: true,
  error: null,
};

function upsert(entries: AgentLike[], agent: AgentLike): AgentLike[] {
  const index = entries.findIndex((entry) => entry.id === agent.id);
  if (index < 0) return [...entries, agent];
  const next = entries.slice();
  next[index] = agent;
  return next;
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/**
 * One owned agent-directory subscription for the selected host. The SDK
 * re-bootstraps the subscription after a reconnect and calls `snapshot` again.
 */
export function useAgentDirectory(): AgentDirectory {
  const paseo = usePaseo();
  const [state, setState] = useState<AgentDirectoryState>(initialState);
  const [revision, setRevision] = useState(0);

  const reload = useCallback(() => {
    setRevision((value) => value + 1);
  }, []);

  useEffect(() => {
    let cancelled = false;
    let unsubscribe: (() => void) | null = null;
    let release: (() => void) | null = null;

    setState((current) => ({
      ...current,
      loading: current.entries.length === 0,
      error: null,
    }));

    void (async () => {
      try {
        const result = await paseo.agents.list({
          scope: "active",
          filter: { includeArchived: false, includeBackground: false },
          page: { limit: 200 },
          subscribe: {},
        });
        if (cancelled) {
          void result.subscription.release();
          return;
        }

        setState({
          entries: result.entries.map((entry) => entry.agent),
          hasMore: result.pageInfo.hasMore,
          loading: false,
          error: null,
        });
        release = () => {
          void result.subscription.release();
        };
        unsubscribe = result.subscription.subscribe({
          snapshot: (snapshot) => {
            if (cancelled) return;
            setState({
              entries: snapshot.entries.map((entry) => entry.agent),
              hasMore: snapshot.pageInfo.hasMore,
              loading: false,
              error: null,
            });
          },
          update: (message) => {
            if (cancelled) return;
            if (message.type !== "agent_update") return;
            const payload = message.payload;
            if (payload.kind === "upsert") {
              setState((current) => ({
                ...current,
                entries: upsert(current.entries, payload.agent),
              }));
              return;
            }
            if (payload.kind === "remove") {
              setState((current) => ({
                ...current,
                entries: current.entries.filter((entry) => entry.id !== payload.agentId),
              }));
            }
          },
          error: (error) => {
            if (cancelled) return;
            setState((current) => ({ ...current, error: errorMessage(error) }));
          },
        });
      } catch (error) {
        if (cancelled) return;
        setState((current) => ({
          ...current,
          loading: false,
          error: errorMessage(error),
        }));
      }
    })();

    return () => {
      cancelled = true;
      unsubscribe?.();
      release?.();
    };
  }, [paseo, revision]);

  return { ...state, reload };
}

export interface AgentCountSummary extends AgentCounts {
  loading: boolean;
  error: string | null;
  hasMore: boolean;
}

export function useAgentCounts(includeSubagents: boolean): AgentCountSummary {
  const directory = useAgentDirectory();
  const counts = countsFor(directory.entries, includeSubagents);
  return {
    ...counts,
    loading: directory.loading,
    error: directory.error,
    hasMore: directory.hasMore,
  };
}
