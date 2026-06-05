/**
 * Zig Format Check Extension
 *
 * After every write_file or edit_file to a .zig file, runs `zig fmt` to
 * auto-correct formatting. If `zig fmt` encounters errors (syntax issues),
 * the error is surfaced to the LLM in the tool result so it can fix them
 * in the same turn instead of waiting for `zig build` to fail.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  // Cache whether `zig` binary is available (checked once on first use)
  let zigAvailable: boolean | null = null;
  let formatCount: number = 0;

  async function ensureZigAvailable(): Promise<boolean> {
    if (zigAvailable !== null) return zigAvailable;
    const { code } = await pi.exec("which", ["zig"]);
    zigAvailable = code === 0;
    return zigAvailable;
  }

  pi.on("tool_result", async (event, ctx) => {
    // Only intercept write and edit operations
    if (event.toolName !== "write" && event.toolName !== "edit") return;

    const path: string | undefined = event.input?.path;
    if (!path || !path.endsWith(".zig")) return;

    // Only run if zig is on PATH
    if (!(await ensureZigAvailable())) return;

    // Also skip files in zig cache / build output directories — those are
    // generated or vendored code, not ours to format.
    if (path.includes("zig-cache") || path.includes("zig-out")) return;

    const { code, stderr } = await pi.exec(
      "zig",
      ["fmt", path],
    );

    if (code !== 0) {
      // zig fmt failed — usually means a syntax error. Surface it
      // to the LLM so it can fix the file in the same turn.
      const errorText = stderr.trim() || `zig fmt failed on ${path} (exit code ${code})`;

      const existingContent = event.content ?? [];

      return {
        content: [
          ...existingContent,
          {
            type: "text",
            text: `\n\n⚠️  \`zig fmt\` failed on \`${path}\`:\n\`\`\`\n${errorText}\n\`\`\``,
          },
        ],
      };
    }

    // zig fmt succeeded — file was properly formatted (or already was).
    formatCount += 1;
    if (ctx.hasUI) {
      ctx.ui.notify(`✓ zig fmt: ${path}`, "info");
    }
  });

  // Startup notification — confirms extension is loaded and zig is available
  pi.on("session_start", async (_event, ctx) => {
    const ok = await ensureZigAvailable();
    if (ctx.hasUI) {
      if (ok) {
        ctx.ui.notify("zig-fmt-check loaded (zig fmt on .zig writes)", "info");
      } else {
        ctx.ui.notify("zig-fmt-check: zig not on PATH — disabled", "warning");
      }
    }
  });

  // Slash command to check status
  pi.registerCommand("zig-fmt-status", {
    description: "Show zig-fmt-check extension status",
    handler: async (_args, ctx) => {
      const ok = await ensureZigAvailable();
      const msg = ok
        ? `zig-fmt-check: ACTIVE — ${formatCount} file(s) formatted this session`
        : `zig-fmt-check: INACTIVE — zig not on PATH`;
      ctx.ui.notify(msg, ok ? "info" : "warning");
    },
  });
}
