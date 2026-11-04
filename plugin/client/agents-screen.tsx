import type { PluginScreenProps } from "@getpaseo/plugin/client";
import { openExternalUrl, useSettings } from "@getpaseo/plugin/client";
import { useMemo } from "react";
import { Pressable, ScrollView, Text, View } from "react-native";
import {
  displayTitle,
  groupAgents,
  menuTimestamp,
  relativeTime,
  type AgentBucket,
  type AgentLike,
} from "../shared/agent-state";
import { traySettings } from "../shared/settings";
import { useAgentDirectory } from "./use-agent-directory";
import { useTrayAppStatus } from "./use-tray-app-status";

const PREFIX: Record<Exclude<AgentBucket, "done">, string> = {
  needs_input: "○",
  failed: "✕",
  running: "●",
  attention: "✓",
};

interface Section {
  key: Exclude<AgentBucket, "done">;
  title: string;
  color: string;
  agents: AgentLike[];
}

export function AgentsScreen({ theme, layout, navigation }: PluginScreenProps) {
  const settings = useSettings(traySettings);
  const includeSubagents = settings.status === "ready" ? settings.values.includeSubagents : false;
  const directory = useAgentDirectory();
  const app = useTrayAppStatus();
  const downloadUrl = app.status?.installed === false ? app.status.downloadUrl : null;
  const groups = groupAgents(directory.entries, includeSubagents);

  const styles = useMemo(
    () => ({
      screen: {
        flex: 1,
        backgroundColor: theme.colors.surface0,
      },
      content: {
        padding: layout.compact ? 16 : 24,
        gap: 18,
      },
      summary: {
        flexDirection: "row" as const,
        alignItems: "center" as const,
        gap: 14,
      },
      summaryText: {
        color: theme.colors.foreground,
        fontSize: 13,
        fontVariant: ["tabular-nums"] as ("tabular-nums")[],
      },
      section: {
        gap: 8,
      },
      sectionTitle: {
        color: theme.colors.foregroundMuted,
        fontSize: 11,
        fontWeight: "600" as const,
        letterSpacing: 0.3,
      },
      card: {
        backgroundColor: theme.colors.surface1,
        borderColor: theme.colors.border,
        borderWidth: 1,
        borderRadius: 10,
        overflow: "hidden" as const,
      },
      row: {
        flexDirection: "row" as const,
        alignItems: "center" as const,
        gap: 10,
        paddingHorizontal: 12,
        paddingVertical: 10,
      },
      rowBorder: {
        borderTopColor: theme.colors.border,
        borderTopWidth: 1,
      },
      pressed: {
        backgroundColor: theme.colors.surface2,
      },
      prefix: {
        fontSize: 13,
        fontWeight: "600" as const,
        width: 16,
        textAlign: "center" as const,
      },
      body: {
        flex: 1,
        gap: 2,
      },
      title: {
        color: theme.colors.foreground,
        fontSize: 14,
      },
      meta: {
        color: theme.colors.foregroundMuted,
        fontSize: 12,
      },
      muted: {
        color: theme.colors.foregroundMuted,
        fontSize: 12,
      },
      footer: {
        color: theme.colors.foregroundMuted,
        fontSize: 11,
        lineHeight: 16,
      },
      retry: {
        color: theme.colors.accent,
        fontSize: 12,
        fontWeight: "600" as const,
      },
      installBanner: {
        borderColor: theme.colors.statusWarning,
        borderWidth: 1,
        backgroundColor: theme.colors.surface1,
        borderRadius: 10,
        padding: 12,
        gap: 3,
      },
      installTitle: {
        color: theme.colors.foreground,
        fontSize: 13,
        fontWeight: "600" as const,
      },
      installText: {
        color: theme.colors.foregroundMuted,
        fontSize: 12,
        lineHeight: 17,
      },
    }),
    [theme, layout.compact],
  );

  const sections: Section[] = [
    {
      key: "needs_input",
      title: "需要你处理",
      color: theme.colors.statusWarning,
      agents: groups.needsInput,
    },
    {
      key: "failed",
      title: "失败",
      color: theme.colors.statusDanger,
      agents: groups.failed,
    },
    {
      key: "running",
      title: "运行中",
      color: theme.colors.statusSuccess,
      agents: groups.running,
    },
    {
      key: "attention",
      title: "已完成",
      color: theme.colors.foregroundMuted,
      agents: groups.attention,
    },
  ].filter((section) => section.agents.length > 0) as Section[];

  return (
    <ScrollView style={styles.screen} contentContainerStyle={styles.content}>
      <View style={styles.summary}>
        <Text style={styles.summaryText}>▶ {groups.counts.running}</Text>
        <Text style={styles.summaryText}>✓ {groups.counts.finished}</Text>
        {groups.counts.actionable > 0 ? (
          <Text style={[styles.summaryText, { color: theme.colors.statusDanger }]}>
            ! {groups.counts.actionable}
          </Text>
        ) : null}
      </View>

      {downloadUrl ? (
        <Pressable
          accessibilityRole="button"
          onPress={() => void openExternalUrl(downloadUrl)}
          style={styles.installBanner}
        >
          <Text style={styles.installTitle}>Paseo Tray 未安装</Text>
          <Text style={styles.installText}>
            菜单栏托盘需要单独安装。点此下载安装包。
          </Text>
        </Pressable>
      ) : null}

      {directory.loading && directory.entries.length === 0 ? (
        <Text style={styles.muted}>加载中…</Text>
      ) : null}

      {directory.error ? (
        <View style={{ gap: 6 }}>
          <Text accessibilityRole="alert" style={styles.muted}>
            {directory.error}
          </Text>
          <Pressable accessibilityRole="button" onPress={directory.reload}>
            <Text style={styles.retry}>重试</Text>
          </Pressable>
        </View>
      ) : null}

      {!directory.loading && !directory.error && sections.length === 0 ? (
        <Text style={styles.muted}>暂无 agent</Text>
      ) : null}

      {sections.map((section) => (
        <View key={section.key} style={styles.section}>
          <Text style={styles.sectionTitle}>{section.title}</Text>
          <View style={styles.card}>
            {section.agents.map((agent, index) => {
              const time = relativeTime(menuTimestamp(agent));
              return (
                <Pressable
                  key={agent.id}
                  accessibilityRole="button"
                  accessibilityLabel={`${displayTitle(agent)} ${time}`}
                  disabled={!navigation}
                  onPress={() => navigation?.openAgent({ agentId: agent.id })}
                  style={({ pressed }) => [
                    styles.row,
                    index > 0 ? styles.rowBorder : null,
                    pressed ? styles.pressed : null,
                  ]}
                >
                  <Text style={[styles.prefix, { color: section.color }]}>
                    {PREFIX[section.key]}
                  </Text>
                  <View style={styles.body}>
                    <Text numberOfLines={1} style={styles.title}>
                      {displayTitle(agent)}
                    </Text>
                    <Text numberOfLines={1} style={styles.meta}>
                      {agent.provider}
                      {time ? ` · ${time}` : ""}
                    </Text>
                  </View>
                </Pressable>
              );
            })}
          </View>
        </View>
      ))}

      {directory.hasMore ? <Text style={styles.muted}>只显示前 200 个</Text> : null}

      {!navigation ? (
        <Text style={styles.muted}>当前客户端不支持跳转到 agent。</Text>
      ) : null}

      <Text style={styles.footer}>
        托盘设置由插件写入 ~/Library/Application Support/PaseoTray/config.json。
      </Text>
    </ScrollView>
  );
}
