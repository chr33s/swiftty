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

  /**
   * Pick the source pane's program icon by name from Swiftty's built-in
   * set ("git", "claude", "python", "terminal", ...); an empty string or
   * an unknown name returns it to automatic detection.
   */
  setPaneIcon(name: string): void;

  /** Display a native macOS system notification */
  notify(title: string, message: string): void;

  /** Register an item in the terminal status bar */
  registerStatusItem(id: string, options: StatusItemOptions): void;

  /** Force a re-render of an existing status bar item */
  refreshStatusItem(id: string): void;
}

export interface PaneController {
  readonly id: string;

  /** Write raw text or ANSI sequences directly to this pane's PTY */
  write(text: string): void;

  /** Split this pane horizontally or vertically */
  split(direction: "horizontal" | "vertical"): PaneController;

  /**
   * Lift this pane into a floating layer. Bounds are fractions of the tab,
   * origin at the top left. Omitted bounds use a centered layer.
   */
  float(bounds?: {x: number; y: number; w: number; h: number}): void;

  /**
   * Put this pane back into the tiled tree beside `beside`. With no pane
   * beside it, an empty tiled tree becomes this pane.
   */
  dock(beside?: string, direction?: "horizontal" | "vertical"): void;

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

/** OSC 9;4 progress. `removed` clears it; `percent` is 0–100 when given. */
export interface ProgressReport {
  state: "removed" | "set" | "error" | "indeterminate" | "paused";
  percent?: number;
}

export interface WorkspaceEvent { workspaceId: string; }
export interface NamedWorkspaceEvent extends WorkspaceEvent { name: string; }
export interface LayoutEvent extends WorkspaceEvent {
  /** Decimal UInt64 layout revision. */
  revision: string;
}
export interface TabEvent extends WorkspaceEvent { tabId: string; }
export interface NamedTabEvent extends TabEvent { name: string; }
export interface PaneEvent extends TabEvent { paneId: string; }
export type AttachmentRole = "controller" | "observer";
export interface AttachmentEvent extends WorkspaceEvent {
  clientId: string;
  role: AttachmentRole;
}
export interface ProcessInfo {
  pid: number;
  name: string;
  /** Only the foreground process reports its working directory. */
  cwd?: string;
}
export interface ForegroundProcessChange {
  /** Decimal UInt64; increases with each change in this pane. */
  generation: string;
  /** Null when the pane has no readable foreground process group. */
  foreground: ProcessInfo | null;
  /** The foreground process's parents, up to the pane's own program. */
  ancestors: ProcessInfo[];
}
export interface ClientState extends ClientConnection {
  /** The client's current attachment; null when it holds none. */
  workspaceId: string | null;
  role: AttachmentRole | null;
}
export interface RoamingConnectionChange {
  sessionId: string;
  workspaceId: string;
  /** `detached` is a lost connection; `attached` is one restored. */
  state: "reserved" | "attached" | "detached" | "exited" | "terminated";
}
export interface ClientConnection {
  clientId: string;
  frontend: "terminal" | "native" | "control";
  build: string;
  /** Bridged from the roaming transport rather than local XPC. */
  remote: boolean;
}

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

  // Pane events: currentPane is the source pane.

  /** The pane's title changed (OSC 0/2), as sanitized for display. */
  onTitleChanged(callback: (title: string) => void): void;

  /** The pane rang the bell (BEL). */
  onBell(callback: () => void): void;

  /** The program asked for a desktop notification (OSC 9 / OSC 777;notify). */
  onNotification(callback: (title: string, body: string) => void): void;

  /** The program reported progress (OSC 9;4). */
  onProgressChanged(callback: (progress: ProgressReport) => void): void;

  /**
   * The pane's program exited. `exitCode` is 128 + signal when a signal
   * ended it, and -1 when the status was not collected.
   */
  onProcessExited(callback: (exitCode: number) => void): void;

  /** The pane's foreground process changed (checked at most every 250 ms). */
  onForegroundProcessChanged(callback: (change: ForegroundProcessChange) => void): void;

  /** The frontend completed a program's clipboard write (kitty OSC 5522). */
  onClipboardWritten(callback: (text: string) => void): void;

  // Workspace events. Existing workspaces are reported as created once,
  // after config.js loads. A paneCreated callback has currentPane bound to it.

  onWorkspaceCreated(callback: (event: NamedWorkspaceEvent) => void): void;
  onWorkspaceClosed(callback: (event: WorkspaceEvent) => void): void;
  onWorkspaceRenamed(callback: (event: NamedWorkspaceEvent) => void): void;
  /** Any layout change: tabs, splits, zoom, focus or exit. */
  onLayoutChanged(callback: (event: LayoutEvent) => void): void;
  onTabCreated(callback: (event: NamedTabEvent) => void): void;
  onTabClosed(callback: (event: TabEvent) => void): void;
  onTabRenamed(callback: (event: NamedTabEvent) => void): void;
  onActiveTabChanged(callback: (event: TabEvent) => void): void;
  onPaneCreated(callback: (event: PaneEvent) => void): void;
  onPaneClosed(callback: (event: PaneEvent) => void): void;
  /** A client took the lease (controller) or began observing a workspace. */
  onClientAttached(callback: (event: AttachmentEvent & { frontend: string }) => void): void;
  onClientDetached(callback: (event: AttachmentEvent) => void): void;
  /** A roaming device's connection to its session was lost or restored. */
  onClientConnectionChanged(callback: (change: RoamingConnectionChange) => void): void;

  // Service events.

  /** A client completed its handshake with the service. */
  onClientConnected(callback: (client: ClientConnection) => void): void;
  onClientDisconnected(callback: (client: { clientId: string }) => void): void;
  /** A connected client's attachment (workspace or role) changed. */
  onClientChanged(callback: (client: ClientState) => void): void;
  /** Whether the service accepts new workspaces, tabs and panes. */
  onAdmissionChanged(callback: (change: { accepting: boolean; reason: "update" | "migration" | null }) => void): void;
  /** The settings file's contents changed on disk (polled every 2 s). */
  onConfigurationChanged(callback: (change: { generation: string; hash: string; path: string }) => void): void;
  /** Swiftty Macs advertising Connect a Device on the local network. */
  onHostsChanged(callback: (change: { hosts: { name: string }[]; hash: string }) => void): void;
  /** Tailscale's tunnel came up, went down, or changed address. */
  onTailscaleStatusChanged(callback: (status: { running: boolean; addresses: string[] }) => void): void;

  /** Bind a keyboard shortcut to an automation routine */
  bindKey(shortcut: string, callback: () => void): void;
}

/** JSON values parsed as data, never evaluated as JavaScript. */
export type JSONValue = null | boolean | number | string | JSONValue[] | { [key: string]: JSONValue };

export interface JSONCReader {
  /** Parse comments and trailing commas. SyntaxError includes original line/byte column. */
  parse(text: string): JSONValue;
  /**
   * Read a UTF-8 JSONC file (up to 1 MiB). Relative paths resolve beside config.js;
   * absolute paths and ~ are supported. Reads are synchronous: load settings at startup.
   * Uses JavaScript number precision, just like JSON.parse. No terminal schema is applied.
   */
  read(path: string): JSONValue;
}

export interface SwifttyContext {
  /** Shared JSONC parser for automation settings. */
  readonly jsonc: JSONCReader;
  /** Headless stream manipulation (Data Plane) */
  readonly filter: StreamFilter;
  /** AppKit UI manipulation (Control Plane) */
  readonly ui: UIController;
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
