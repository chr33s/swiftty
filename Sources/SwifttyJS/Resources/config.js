/// <reference path="./swiftty.d.ts" />

// 1. Data Plane: Redact sensitive tokens in stdout before grid parsing
swiftty.filter.onStdout((chunk) => {
  if (chunk.includes("token=") || chunk.includes("ghp_")) {
    return chunk.replace(/ghp_[A-Za-z0-9]+/g, "[REDACTED_GH_TOKEN]");
  }
});

// 2. Control Plane: Status bar integration
swiftty.ui.registerStatusItem("clock", {
  align: "right",
  refreshInterval: 1.0,
  render: () => {
    const time = new Date().toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
    return `🕒 ${time}`;
  }
});

// 3. Shell Lifecycle: Notify on long-running task completion
swiftty.events.onCommandFinished((cmd, code) => {
  if (code !== 0) {
    swiftty.ui.setBadge("⚠️");
    swiftty.ui.notify("Command Failed", `${cmd} exited with status ${code}`);
  } else {
    swiftty.ui.setBadge("");
  }
});

// 4. Hotkeys: Split pane shortcut
swiftty.events.bindKey("cmd+shift+d", () => {
  const pane = swiftty.currentPane.split("horizontal");
  pane.write("top\n");
});

// OSC 7501 status events are also available. For example:
// swiftty.events.onStatusChanged((change) => {
//   if (change.type === "report" && change.record.state === "blocked") {
//     swiftty.ui.notify(change.record.title || "Program needs attention",
//       change.record.message || "Waiting for input");
//   }
// });
