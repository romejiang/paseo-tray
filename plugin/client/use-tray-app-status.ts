import { useRpc } from "@getpaseo/plugin/client";
import { useCallback, useEffect, useState } from "react";
import { trayAppStatusRpc, type TrayAppStatus } from "../shared/app-status";

export interface TrayAppStatusState {
  status: TrayAppStatus | null;
  error: string | null;
  reload(): Promise<void>;
}

export function useTrayAppStatus(): TrayAppStatusState {
  const getStatus = useRpc(trayAppStatusRpc);
  const [status, setStatus] = useState<TrayAppStatus | null>(null);
  const [error, setError] = useState<string | null>(null);

  const reload = useCallback(async () => {
    try {
      setStatus(await getStatus({}));
      setError(null);
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    }
  }, [getStatus]);

  useEffect(() => {
    void reload();
  }, [reload]);

  return { status, error, reload };
}
