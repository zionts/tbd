import {
  StrictMode,
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
} from "react";
import { createRoot } from "react-dom/client";
import {
  BlitWorkspace,
  DEFAULT_FONT,
  DEFAULT_FONT_SIZE,
} from "@blit-sh/core";
import type { BlitSession, BlitTerminalSurface } from "@blit-sh/core";
import {
  BlitTerminal,
  BlitWorkspaceProvider,
  useBlitSessions,
  useBlitWorkspaceConnection,
} from "@blit-sh/react";

import {
  buildPalette,
  resolveConfig,
  rgbCss,
  type BlitRuntimeConfig,
  type BlitThemeInput,
} from "./config";
import { ansiToHtml } from "./ansi";
import { installBridge, postToSwift } from "./bridge";

// The blit browser WASM renderer. esbuild inlines blit_browser_bg.wasm as raw
// bytes (see build.mjs: `.wasm` -> binary loader) so the whole app ships as a
// single bundle.js with no sidecar fetches — required for WKWebView.loadFileURL.
import initBrowserWasm, * as blitBrowser from "@blit-sh/browser";
// @ts-expect-error - esbuild resolves this to a Uint8Array via the binary loader.
import wasmBytes from "@blit-sh/browser/blit_browser_bg.wasm";

type BlitWasmModule = typeof import("@blit-sh/browser");

const CONNECTION_ID = "tbd-gateway";

/**
 * Initialise the WASM renderer from inlined bytes, then hand back the module
 * namespace (which carries the `Terminal` class the core TerminalStore needs).
 */
async function loadWasm(): Promise<BlitWasmModule> {
  await initBrowserWasm({ module_or_path: wasmBytes as Uint8Array });
  return blitBrowser as unknown as BlitWasmModule;
}

/** Path-ish characters used to grow the word under a Cmd-click. */
const PATH_CHARS = /[A-Za-z0-9_\-./~:@]/;

function TerminalApp({ config }: { config: BlitRuntimeConfig }) {
  // Theme is live state so the native host can re-apply it without a reload
  // (Phase 8, feature 6). Seed from the injected config.
  const [theme, setTheme] = useState<BlitThemeInput | undefined>(config.theme);
  const palette = useMemo(() => buildPalette(theme), [theme]);
  const fontFamily = theme?.font ?? DEFAULT_FONT;
  const fontSize = theme?.fontSize ?? DEFAULT_FONT_SIZE;

  // Background-event suppression: when inactive we render the terminal
  // read-only so it never steals first responder / key events (feature 8).
  const [active, setActive] = useState(true);

  // One workspace for the lifetime of this page; the WASM module promise is
  // created once and shared with the connection.
  const workspace = useMemo(() => new BlitWorkspace({ wasm: loadWasm() }), []);
  useEffect(() => () => workspace.dispose(), [workspace]);

  // Swift→JS bridge: live theme + active-state updates.
  useEffect(() => {
    const uninstall = installBridge({
      onTheme: (t) => setTheme(t),
      onActive: (a) => setActive(a),
    });
    postToSwift({ type: "ready" });
    return uninstall;
  }, []);

  // Push the page-chrome colours whenever the theme changes so the area around
  // the canvas tracks live theme updates too.
  useEffect(() => {
    applyContainerTheme(theme);
  }, [theme]);

  // Connect to the local gateway over the injected ws URL + passphrase.
  useBlitWorkspaceConnection(workspace, CONNECTION_ID, {
    type: "websocket",
    url: config.wsUrl,
    passphrase: config.passphrase,
  });

  return (
    <BlitWorkspaceProvider
      workspace={workspace}
      palette={palette}
      fontFamily={fontFamily}
      fontSize={fontSize}
    >
      <TerminalById
        config={config}
        palette={palette}
        fontFamily={fontFamily}
        fontSize={fontSize}
        active={active}
      />
    </BlitWorkspaceProvider>
  );
}

function TerminalById({
  config,
  palette,
  fontFamily,
  fontSize,
  active,
}: {
  config: BlitRuntimeConfig;
  palette: ReturnType<typeof buildPalette>;
  fontFamily: string;
  fontSize: number;
  active: boolean;
}) {
  const terminalId = config.terminalId;
  // Sessions arrive once the gateway sends its terminal list. We render the one
  // whose blit ptyId matches the injected integer terminal id.
  const sessions = useBlitSessions();
  const session: BlitSession | undefined = sessions.find(
    (s) => s.ptyId === terminalId && s.state !== "closed",
  );

  const surfaceRef = useRef<BlitTerminalSurface | null>(null);

  // --- Feature 3: dead-window detection -----------------------------------
  // When the blit session reports `exited`, tell Swift so it can recreate the
  // window. Fire exactly once per exit.
  const exitedNotified = useRef(false);
  useEffect(() => {
    if (session && session.state === "exited" && !exitedNotified.current) {
      exitedNotified.current = true;
      postToSwift({
        type: "sessionExited",
        terminalId,
        exitStatus: session.exitStatus,
      });
    }
    if (session && session.state === "active") {
      exitedNotified.current = false;
    }
  }, [session, terminalId]);

  // --- Feature 7: title-change notifications ------------------------------
  // Surface terminal title changes (incl. OSC-set titles) as native
  // notifications. We skip the first observed title (initial paint) and only
  // fire on subsequent changes.
  const lastTitle = useRef<string | null>(null);
  const sawFirstTitle = useRef(false);
  useEffect(() => {
    const title = session?.title ?? null;
    if (title == null) return;
    if (!sawFirstTitle.current) {
      sawFirstTitle.current = true;
      lastTitle.current = title;
      return;
    }
    if (title !== lastTitle.current) {
      lastTitle.current = title;
      postToSwift({
        type: "notification",
        title,
        body: "",
        kind: "title",
      });
    }
  }, [session?.title]);

  // --- Feature 2: Cmd-click file paths ------------------------------------
  const handleSurface = useCallback(
    (surface: BlitTerminalSurface | null) => {
      surfaceRef.current = surface;
    },
    [],
  );

  const containerRef = useRef<HTMLDivElement | null>(null);
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;

    const onMouseDownCapture = (e: MouseEvent) => {
      // Cmd-click only. Let blit handle plain clicks (selection) and its own
      // URL open path (it intercepts metaKey clicks on http(s) URLs itself).
      if (!e.metaKey || e.button !== 0) return;
      const surface = surfaceRef.current;
      const term = surface?.currentTerminal;
      if (!surface || !term) return;

      // Map the click to a grid cell using the same arithmetic blit uses.
      const canvas = el.querySelector("canvas");
      if (!canvas) return;
      const rect = canvas.getBoundingClientRect();
      const cellW = rect.width / term.cols;
      const cellH = rect.height / term.rows;
      if (cellW <= 0 || cellH <= 0) return;
      const col = Math.min(
        Math.max(Math.floor((e.clientX - rect.left) / cellW), 0),
        term.cols - 1,
      );
      const row = Math.min(
        Math.max(Math.floor((e.clientY - rect.top) / cellH), 0),
        term.rows - 1,
      );

      // Read the whole visible row and grow the word under the cursor.
      let lineText: string;
      try {
        lineText = term.get_text(row, 0, row, term.cols - 1) ?? "";
      } catch {
        return;
      }
      const path = extractPathAt(lineText, col);
      if (!path) return;

      // If it looks like an http(s) URL, leave it to blit's own handler.
      if (/^https?:\/\//.test(path)) return;

      // Claim the event so blit doesn't also start a selection.
      e.preventDefault();
      e.stopPropagation();
      postToSwift({ type: "openPath", text: path });
    };

    // Capture phase so we run before blit's own listeners on the canvas.
    el.addEventListener("mousedown", onMouseDownCapture, true);
    return () =>
      el.removeEventListener("mousedown", onMouseDownCapture, true);
  }, []);

  // --- Feature 4 (focus): report focus to the native host -----------------
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const onFocusIn = () => postToSwift({ type: "focus" });
    el.addEventListener("focusin", onFocusIn);
    return () => el.removeEventListener("focusin", onFocusIn);
  }, []);

  // --- Feature 1: suspended snapshot --------------------------------------
  // Render the captured ANSI snapshot until a LIVE (active) session exists.
  const hasLiveSession = !!session && session.state === "active";
  const showSnapshot =
    !!config.snapshot && (config.isSuspended || !hasLiveSession);

  if (showSnapshot && config.snapshot) {
    return (
      <SnapshotView snapshot={config.snapshot} palette={palette} />
    );
  }

  if (!session) {
    return (
      <div className="tbd-status">Connecting to terminal {terminalId}…</div>
    );
  }

  return (
    <div
      ref={containerRef}
      style={{ width: "100%", height: "100%" }}
    >
      <BlitTerminal
        sessionId={session.id}
        palette={palette}
        fontFamily={fontFamily}
        fontSize={fontSize}
        readOnly={!active}
        surfaceRef={handleSurface}
        style={{ width: "100%", height: "100%" }}
      />
    </div>
  );
}

/** Static ANSI snapshot, rendered as styled HTML (suspended terminals). */
function SnapshotView({
  snapshot,
  palette,
}: {
  snapshot: string;
  palette: ReturnType<typeof buildPalette>;
}) {
  const html = useMemo(() => ansiToHtml(snapshot, palette), [snapshot, palette]);
  return (
    <div
      className="tbd-snapshot"
      style={{
        background: rgbCss(palette.bg),
        color: rgbCss(palette.fg),
      }}
      // The snapshot is server-captured terminal output; ansiToHtml escapes all
      // text content and only emits our own <span style> wrappers.
      dangerouslySetInnerHTML={{ __html: html }}
    />
  );
}

/**
 * Grow the path-like word around `col` in `lineText`, then strip trailing
 * punctuation and `:line:col` suffixes. Mirrors the old SwiftTerm
 * `extractFilePath` boundary logic; the existence check happens in Swift.
 */
function extractPathAt(lineText: string, col: number): string | null {
  if (col >= lineText.length) col = lineText.length - 1;
  if (col < 0) return null;
  const chars = Array.from(lineText);
  if (col >= chars.length) return null;
  if (!PATH_CHARS.test(chars[col] ?? "")) return null;

  let start = col;
  let end = col;
  while (start > 0 && PATH_CHARS.test(chars[start - 1])) start--;
  while (end < chars.length - 1 && PATH_CHARS.test(chars[end + 1])) end++;

  let candidate = chars.slice(start, end + 1).join("");
  // Strip trailing :line:col suffix (file.swift:10:5).
  candidate = candidate.replace(/:\d+(:\d+)?$/, "");
  // Strip trailing sentence punctuation absorbed by the '.' word char.
  candidate = candidate.replace(/[.,;:]+$/, "");
  return candidate.length > 0 ? candidate : null;
}

function Fatal({ message }: { message: string }) {
  return <div className="tbd-status tbd-error">{message}</div>;
}

function Root() {
  const [config, setConfig] = useState<BlitRuntimeConfig | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    try {
      setConfig(resolveConfig());
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    }
  }, []);

  if (error) return <Fatal message={error} />;
  if (!config) return <div className="tbd-status">Loading…</div>;
  return <TerminalApp config={config} />;
}

function applyContainerTheme(themeInput?: BlitThemeInput) {
  // Apply background/foreground to the page chrome so the area around the
  // WebGL canvas matches the terminal even before the canvas paints. The blit
  // palette itself is applied through BlitTerminal's `palette` prop above.
  let theme = themeInput;
  if (theme === undefined) {
    try {
      theme = resolveConfig().theme;
    } catch {
      theme = undefined;
    }
  }
  const palette = buildPalette(theme);
  const root = document.documentElement;
  root.style.setProperty("--tbd-bg", rgbCss(palette.bg));
  root.style.setProperty("--tbd-fg", rgbCss(palette.fg));
  if (theme?.cursor) {
    const cursor = buildPalette({ fg: theme.cursor }).fg;
    root.style.setProperty("--tbd-cursor", rgbCss(cursor));
  }
}

applyContainerTheme();

const container = document.getElementById("root");
if (container) {
  createRoot(container).render(
    <StrictMode>
      <Root />
    </StrictMode>,
  );
}
