import type { PluginSurfaceProps } from "@getpaseo/plugin/client";
import { openExternalUrl, useRpc, useSettings } from "@getpaseo/plugin/client";
import {
  SettingsAction,
  SettingsCard,
  SettingsRow,
  SettingsSection,
  SettingsSwitch,
} from "@getpaseo/plugin/client/ui";
import { useCallback, useEffect, useMemo, useState } from "react";
import { Text, View } from "react-native";
import { TRAY_DOWNLOAD_URL } from "../shared/app-status";
import { trayConfigStatusRpc, type TrayConfigStatus } from "../shared/config-status";
import { traySettings, type TraySettings } from "../shared/settings";
import { useTrayAppStatus } from "./use-tray-app-status";

const CONFIG_PATH = "~/Library/Application Support/PaseoTray/config.json";

export function TraySettingsScreen({ theme }: PluginSurfaceProps) {
  const settings = useSettings(traySettings);
  const app = useTrayAppStatus();
  const getConfigStatus = useRpc(trayConfigStatusRpc);
  const [sync, setSync] = useState<TrayConfigStatus | null>(null);
  const refreshSync = useCallback(async () => {
    try {
      setSync(await getConfigStatus({}));
    } catch (error) {
      setSync({
        ok: false,
        error: error instanceof Error ? error.message : String(error),
        path: CONFIG_PATH,
        syncedAt: null,
      });
    }
  }, [getConfigStatus]);
  useEffect(() => {
    void refreshSync();
  }, [refreshSync]);
  const muted = useMemo(
    () => ({
      color: theme.colors.foregroundMuted,
      fontSize: 12,
      lineHeight: 17,
    }),
    [theme],
  );

  if (settings.status === "loading") {
    return <Text style={muted}>加载设置…</Text>;
  }

  if (settings.status !== "ready") {
    return (
      <View style={{ gap: 12 }}>
        <SettingsSection title="托盘设置">
          <Text accessibilityRole="alert" style={muted}>
            {settings.error}
          </Text>
          <SettingsAction
            label="重新读取设置"
            actionLabel="重试"
            onPress={() => void settings.reload()}
          />
          {settings.status === "invalid" ? (
            <SettingsAction
              label="存储的设置无法解析"
              actionLabel="重置为默认值"
              onPress={() => void settings.reset()}
            />
          ) : null}
        </SettingsSection>
      </View>
    );
  }

  const save = (patch: Partial<TraySettings>) => {
    void (async () => {
      const saved = await settings.save(
        { ...settings.values, ...patch },
        settings.revision,
      );
      if (saved) await refreshSync();
    })();
  };

  return (
    <View style={{ gap: 16 }}>
      <SettingsSection title="托盘 App">
        <SettingsCard>
          <SettingsRow
            label="安装状态"
            error={app.error ?? (app.status && !app.status.installed ? "未安装" : undefined)}
          >
            <Text
              style={
                app.status && !app.status.installed
                  ? [muted, { color: theme.colors.statusWarning }]
                  : muted
              }
            >
              {app.status == null
                ? app.error
                  ? `检测失败：${app.error}`
                  : "检测中…"
                : app.status.installed
                  ? `已安装${app.status.version ? ` · v${app.status.version}` : ""}`
                  : "未安装，菜单栏托盘不会显示"}
            </Text>
          </SettingsRow>
          {app.status?.installed ? (
            <SettingsRow label="路径">
              <Text style={muted}>{app.status.path}</Text>
            </SettingsRow>
          ) : (
            <SettingsAction
              label="需要单独安装 Paseo Tray"
              actionLabel="下载"
              onPress={() =>
                void openExternalUrl(app.status?.downloadUrl ?? TRAY_DOWNLOAD_URL)
              }
            />
          )}
          <SettingsAction
            label="重新检测安装状态"
            actionLabel="检测"
            onPress={() => void app.reload()}
          />
        </SettingsCard>
      </SettingsSection>

      <SettingsSection title="菜单栏">
        <SettingsCard>
          <SettingsSwitch
            label="显示运行中数量"
            hint="关闭后标题只显示图标和其他计数"
            value={settings.values.showRunningCount}
            disabled={settings.saving}
            onValueChange={(showRunningCount) => save({ showRunningCount })}
          />
          <SettingsSwitch
            label="显示已完成数量"
            value={settings.values.showFinishedCount}
            disabled={settings.saving}
            onValueChange={(showFinishedCount) => save({ showFinishedCount })}
          />
          <SettingsSwitch
            label="包含子 agent"
            hint="默认隐藏带 paseo.parent-agent-id 标签的 agent"
            value={settings.values.includeSubagents}
            disabled={settings.saving}
            onValueChange={(includeSubagents) => save({ includeSubagents })}
          />
        </SettingsCard>
      </SettingsSection>

      <SettingsSection title="系统通知">
        <SettingsCard>
          <SettingsSwitch
            label="完成时通知"
            hint="Paseo 在前台时自动静默"
            value={settings.values.notifyOnFinish}
            disabled={settings.saving}
            onValueChange={(notifyOnFinish) => save({ notifyOnFinish })}
          />
          <SettingsSwitch
            label="出错时通知"
            value={settings.values.notifyOnError}
            disabled={settings.saving}
            onValueChange={(notifyOnError) => save({ notifyOnError })}
          />
          <SettingsSwitch
            label="需要权限时通知"
            value={settings.values.notifyOnPermission}
            disabled={settings.saving}
            onValueChange={(notifyOnPermission) => save({ notifyOnPermission })}
          />
          <SettingsSwitch
            label="播放声音"
            hint="通知声音；通知不可用时始终使用 beep 降级"
            value={settings.values.playSound}
            disabled={settings.saving}
            onValueChange={(playSound) => save({ playSound })}
          />
        </SettingsCard>
      </SettingsSection>

      <SettingsSection title="配置文件">
        <SettingsCard>
          <SettingsRow label="路径">
            <Text style={muted}>{CONFIG_PATH}</Text>
          </SettingsRow>
          <SettingsRow
            label="同步状态"
            error={sync && !sync.ok ? sync.error : undefined}
          >
            <Text
              style={
                sync && !sync.ok
                  ? [muted, { color: theme.colors.statusDanger }]
                  : muted
              }
            >
              {sync == null
                ? "检查中…"
                : sync.ok
                  ? `已同步${sync.syncedAt ? ` · ${new Date(sync.syncedAt).toLocaleTimeString()}` : ""}`
                  : sync.error
                    ? `写入失败：${sync.error}`
                    : "尚未同步"}
            </Text>
          </SettingsRow>
          <SettingsRow label="生效方式">
            <Text style={muted}>
              插件在 daemon 侧原子写入，托盘监听目录变化，保存后约 1 秒内生效。插件被禁用时托盘继续使用最后一次配置。
            </Text>
          </SettingsRow>
        </SettingsCard>
      </SettingsSection>

      {settings.saveError ? (
        <SettingsRow label="保存失败" error={settings.saveError}>
          <Text accessibilityRole="alert" style={muted}>
            {settings.saveError}
          </Text>
        </SettingsRow>
      ) : null}

      <SettingsSection title="恢复">
        <SettingsCard>
          <SettingsAction
            label="恢复默认设置"
            actionLabel="重置"
            disabled={settings.saving}
            onPress={() => void settings.reset()}
          />
        </SettingsCard>
      </SettingsSection>
    </View>
  );
}
