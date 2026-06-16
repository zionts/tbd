import { StrictMode, useEffect, useMemo, useState } from "react";
import { createRoot } from "react-dom/client";
import {
  BlitWorkspace,
  DEFAULT_FONT,
  DEFAULT_FONT_SIZE,
} from "@blit-sh/core";
import type { BlitSession } from "@blit-sh/core";
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
} from "./config";

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

function TerminalApp({ config }: { config: BlitRuntimeConfig }) {
  const palette = useMemo(() => buildPalette(config.theme), [config.theme]);
  const fontFamily = config.theme?.font ?? DEFAULT_FONT;
  const fontSize = config.theme?.fontSize ?? DEFAULT_FONT_SIZE;

  // One workspace for the lifetime of this page; the WASM module promise is
  // created once and shared with the connection.
  const workspace = useMemo(
    () => new BlitWorkspace({ wasm: loadWasm() }),
    [],
  );
  useEffect(() => () => workspace.dispose(), [workspace]);

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
        terminalId={config.terminalId}
        palette={palette}
        fontFamily={fontFamily}
        fontSize={fontSize}
      />
    </BlitWorkspaceProvider>
  );
}

function TerminalById({
  terminalId,
  palette,
  fontFamily,
  fontSize,
}: {
  terminalId: number;
  palette: ReturnType<typeof buildPalette>;
  fontFamily: string;
  fontSize: number;
}) {
  // Sessions arrive once the gateway sends its terminal list. We render the one
  // whose blit ptyId matches the injected integer terminal id.
  const sessions = useBlitSessions();
  const session: BlitSession | undefined = sessions.find(
    (s) => s.ptyId === terminalId,
  );

  if (!session) {
    return (
      <div className="tbd-status">Connecting to terminal {terminalId}…</div>
    );
  }

  return (
    <BlitTerminal
      sessionId={session.id}
      palette={palette}
      fontFamily={fontFamily}
      fontSize={fontSize}
      style={{ width: "100%", height: "100%" }}
    />
  );
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

function applyContainerTheme() {
  // Apply background/foreground to the page chrome so the area around the
  // WebGL canvas matches the terminal even before the canvas paints. The blit
  // palette itself is applied through BlitTerminal's `palette` prop above.
  let theme;
  try {
    theme = resolveConfig().theme;
  } catch {
    theme = undefined;
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
