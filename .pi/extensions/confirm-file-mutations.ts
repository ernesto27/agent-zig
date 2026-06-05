/**
 * Confirm File Mutations Extension
 *
 * Prompts before built-in write/edit tool calls that modify files.
 * Includes an "Accept all" option for the current session.
 * In non-interactive modes, mutations are blocked by default.
 */

import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

export default function (pi: ExtensionAPI) {
  let acceptAll = false;

  pi.on("tool_call", async (event, ctx) => {
    if (event.toolName !== "write" && event.toolName !== "edit") {
      return undefined;
    }

    const path = String(event.input?.path ?? "<unknown>");

    if (acceptAll) {
      return undefined;
    }

    if (!ctx.hasUI) {
      return {
        block: true,
        reason: `File mutation blocked (no UI available for confirmation): ${event.toolName} ${path}`,
      };
    }

    const message =
      event.toolName === "write"
        ? `Allow write to file?\n\nPath: ${path}`
        : `Allow edit to file?\n\nPath: ${path}\nEdit blocks: ${Array.isArray(event.input?.edits) ? event.input.edits.length : 1}`;

    const choice = await ctx.ui.select("Confirm file modification", [
      "Allow once",
      "Accept all",
      "Deny",
    ]);

    if (choice === "Accept all") {
      acceptAll = true;
      ctx.ui.notify("confirm-file-mutations: accept-all enabled for this session", "info");
      return undefined;
    }

    if (choice !== "Allow once") {
      return {
        block: true,
        reason: `Blocked by user: ${event.toolName} ${path}`,
      };
    }

    return undefined;
  });

  pi.on("session_start", async (_event, ctx) => {
    acceptAll = false;
    if (ctx.hasUI) {
      ctx.ui.notify("confirm-file-mutations loaded (prompts before write/edit)", "info");
    }
  });

  pi.registerCommand("confirm-file-mutations-reset", {
    description: "Re-enable confirmations for file write/edit operations",
    handler: async (_args, ctx) => {
      acceptAll = false;
      if (ctx.hasUI) {
        ctx.ui.notify("confirm-file-mutations: confirmations re-enabled", "info");
      }
    },
  });
}
