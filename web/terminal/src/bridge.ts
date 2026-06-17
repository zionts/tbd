// JS↔Swift bridge for the blit WebView terminal (Phase 8).
//
// Protocol
// ========
// Swift→JS (via WKWebView.evaluateJavaScript):
//   window.__TBD_BRIDGE__.applyTheme(themeJson)   // live theme/font re-apply
//   window.__TBD_BRIDGE__.setActive(active)       // bg event suppression
//   window.__TBD_BRIDGE__.focus()                 // focus blit's input element
//   (initial config still arrives via window.__BLIT__ at document start.)
//
// JS→Swift (via window.webkit.messageHandlers.tbd.postMessage):
//   { type: "ready" }
//   { type: "openPath", text }                    // Cmd-click file path
//   { type: "sessionExited", terminalId, exitStatus }
//   { type: "notification", title, body, kind }   // OSC-777 / bell / title
//   { type: "focus" }                             // terminal gained focus

import type { BlitThemeInput } from "./config";

export type TbdOutboundMessage =
  | { type: "ready" }
  | { type: "openPath"; text: string }
  | { type: "sessionExited"; terminalId: number; exitStatus: number | null }
  | {
      type: "notification";
      title: string;
      body: string;
      kind: "osc777" | "bell" | "title";
    }
  | { type: "focus" };

interface TbdWebkitMessageHandler {
  postMessage(message: unknown): void;
}

interface TbdWebkit {
  messageHandlers?: { tbd?: TbdWebkitMessageHandler };
}

/** Post a message to the native host. No-op when not embedded in WKWebView. */
export function postToSwift(message: TbdOutboundMessage): void {
  const webkit = (window as unknown as { webkit?: TbdWebkit }).webkit;
  const handler = webkit?.messageHandlers?.tbd;
  if (handler) {
    try {
      handler.postMessage(message);
    } catch {
      // Native side absent / detached — ignore.
    }
  }
}

/**
 * Register the Swift→JS bridge surface. `onTheme` re-applies the palette/font
 * live; `onActive` toggles background event suppression. Returns a cleanup fn.
 */
export function installBridge(handlers: {
  onTheme(theme: BlitThemeInput): void;
  onActive(active: boolean): void;
  onFocus(): void;
}): () => void {
  window.__TBD_BRIDGE__ = {
    applyTheme(themeJson: string) {
      try {
        const theme = JSON.parse(themeJson) as BlitThemeInput;
        handlers.onTheme(theme);
      } catch {
        // Malformed payload — ignore rather than crash the renderer.
      }
    },
    setActive(active: boolean) {
      handlers.onActive(active);
    },
    focus() {
      handlers.onFocus();
    },
  };
  return () => {
    if (window.__TBD_BRIDGE__) delete window.__TBD_BRIDGE__;
  };
}
