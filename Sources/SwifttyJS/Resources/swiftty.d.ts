/**
 * Swiftty Terminal Embedded Automation Engine API
 */

export interface Color {
  red: number;    // 0.0 - 1.0
  green: number;  // 0.0 - 1.0
  blue: number;   // 0.0 - 1.0
  alpha?: number; // 0.0 - 1.0 (defaults to 1.0)
}

export interface StatusItemRenderResult {
  text: string;
  color?: string | Color;
  backgroundColor?: string | Color;
}

export interface StatusItemOptions {
  /** Screen alignment: "left" or "right" */
  align: "left" | "right";
  /** Optional polling interval in seconds. If omitted, only renders on manual refresh. */
  refreshInterval?: number;
  /** Function returning content to render in the status line */
  render: () => StatusItemRenderResult | string;
}

export interface StreamFilter {
  /**
   * Registers a filter on stdout byte chunks received from the PTY.
   * Return a modified string to alter the terminal buffer, or null/undefined to pass unchanged.
   */
  onStdout(callback: (chunk: string) => string | null | void): void;

  /**
   * Registers a filter on stdin byte chunks sent from the keyboard/input to the PTY.
   */
  onStdin(callback: (chunk: string) => string | null | void): void;
}

export interface UIController {
  /** Set dock badge text or emoji (empty string clears badge) */
  setBadge(badge: string): void;

  /** Set the active tab title icon or text */
  setTabIcon(icon: string): void;

  /** Display a native macOS system notification */
  notify(title: string, message: string): void;

  /** Register an item in the terminal status bar */
  registerStatusItem(id: string, options: StatusItemOptions): void;

  /** Force a re-render of an existing status bar item */
  refreshStatusItem(id: string): void;
}

export interface PaneController {
  /** Unique pane identifier */
  readonly id: string;

  /** Write raw text or ANSI sequences directly to this pane's PTY */
  write(text: string): void;

  /** Split this pane horizontally or vertically */
  split(direction: "horizontal" | "vertical"): PaneController;

  /** Close the pane */
  close(): void;
}

/** Validated OSC 7501 record. Empty id denotes the pane's root record. */
export interface ProgramStatus {
  id: string;
  state: "idle" | "working" | "done" | "blocked" | "error";
  kind?: "permission" | "question" | "auth";
  progress?: number;
  app?: string;
  /** Plain program-supplied text; never interpret as code or markup. */
  title?: string;
  message?: string;
  /** Decimal UInt64, represented as a string without numeric precision loss. */
  revision: string;
}

export interface StatusChangeSource {
  paneId: string;
  /** Changes on terminal reset; record ids are scoped to this epoch. */
  terminalEpoch: string;
}

export type ProgramStatusChange = StatusChangeSource & (
  | { type: "report"; record: ProgramStatus }
  | { type: "removed"; ids: string[] }
  | { type: "reset" }
  | { type: "sync"; records: ProgramStatus[] }
);

export interface LifecycleHooks {
  /**
   * Validated OSC 7501 status changes, including clear, eviction and reset.
   * Callbacks run with currentPane bound to the source pane. A sync event
   * replaces the entire cached status set after journal overflow.
   */
  onStatusChanged(callback: (change: ProgramStatusChange) => void): void;

  /** Triggered when OSC 133 command completion marker is encountered */
  onCommandFinished(callback: (command: string, exitCode: number) => void): void;

  /** Triggered when the current working directory changes via OSC 7 */
  onDirectoryChanged(callback: (newPath: string) => void): void;

  /** Bind a keyboard shortcut to an automation routine */
  bindKey(shortcut: string, callback: () => void): void;
}

export interface SwifttyContext {
  /** Headless stream manipulation (Data Plane) */
  readonly filter: StreamFilter;
  /** AppKit UI manipulation (Control Plane) */
  readonly ui: UIController;
  /** Current active terminal pane */
  readonly currentPane: PaneController;
  /** Shell lifecycle and hotkey hooks */
  readonly events: LifecycleHooks;
  /** Read environment variables passed from the terminal process */
  env(key: string, defaultValue?: string): string;
}

/** Root Swiftty API instance exposed into the global JavaScript environment */
declare global {
  const swiftty: SwifttyContext;
}
