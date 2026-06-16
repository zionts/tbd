import type { TerminalPalette } from "@blit-sh/core";

/**
 * Runtime configuration injected by the native macOS app (Phase 6) before the
 * bundle's script runs:
 *
 *   window.__BLIT__ = {
 *     wsUrl: "ws://127.0.0.1:<gatewayPort>",
 *     passphrase: "<gateway passphrase>",
 *     terminalId: 3,                 // integer blit terminal id (ptyId)
 *     theme: { bg, fg, ansi, font, fontSize, cursor }   // optional
 *   }
 *
 * For manual browser testing the same values may be supplied as URL query
 * params: ?wsUrl=...&passphrase=...&terminalId=3 (theme is JSON in ?theme=).
 */
export interface BlitThemeInput {
  /** Background color, "#rrggbb" or [r,g,b]. */
  bg?: string | [number, number, number];
  /** Foreground color, "#rrggbb" or [r,g,b]. */
  fg?: string | [number, number, number];
  /** 16 ANSI colors, each "#rrggbb" or [r,g,b]. */
  ansi?: Array<string | [number, number, number]>;
  /** CSS font family. */
  font?: string;
  /** Font size in CSS px. */
  fontSize?: number;
  /** Cursor color, "#rrggbb" or [r,g,b]. */
  cursor?: string | [number, number, number];
  /** true = dark background (affects palette `dark` flag). */
  dark?: boolean;
}

export interface BlitRuntimeConfig {
  wsUrl: string;
  passphrase: string;
  terminalId: number;
  theme?: BlitThemeInput;
  /**
   * ANSI scrollback captured while the terminal was suspended. Rendered as a
   * static screen until the live blit session connects (Phase 8, feature 1).
   */
  snapshot?: string;
  /** true when this terminal is currently suspended (no live PTY behind it). */
  isSuspended?: boolean;
}

declare global {
  interface Window {
    __BLIT__?: Partial<BlitRuntimeConfig>;
    /**
     * Swift→JS bridge surface, populated by `src/bridge.ts` once the React app
     * mounts. The native host calls these via `evaluateJavaScript`.
     */
    __TBD_BRIDGE__?: {
      /** Re-apply theme/font without a reload. Arg is a BlitThemeInput JSON. */
      applyTheme(themeJson: string): void;
      /** Mark this WebView active/inactive (background event suppression). */
      setActive(active: boolean): void;
    };
  }
}

function clamp255(n: number): number {
  if (Number.isNaN(n)) return 0;
  return Math.max(0, Math.min(255, Math.round(n)));
}

/** Parse "#rrggbb" / "#rgb" / [r,g,b] into an [r,g,b] tuple. Returns null on failure. */
export function toRgb(
  value: string | [number, number, number] | undefined,
): [number, number, number] | null {
  if (value == null) return null;
  if (Array.isArray(value)) {
    if (value.length !== 3) return null;
    return [clamp255(value[0]), clamp255(value[1]), clamp255(value[2])];
  }
  let hex = value.trim();
  if (hex.startsWith("#")) hex = hex.slice(1);
  if (hex.length === 3) {
    hex = hex
      .split("")
      .map((c) => c + c)
      .join("");
  }
  if (hex.length !== 6) return null;
  const r = parseInt(hex.slice(0, 2), 16);
  const g = parseInt(hex.slice(2, 4), 16);
  const b = parseInt(hex.slice(4, 6), 16);
  if ([r, g, b].some((n) => Number.isNaN(n))) return null;
  return [r, g, b];
}

/**
 * Resolve runtime config from window.__BLIT__, falling back to URL query
 * params. Throws if required fields (wsUrl, passphrase, terminalId) are absent.
 */
export function resolveConfig(): BlitRuntimeConfig {
  const injected = (typeof window !== "undefined" && window.__BLIT__) || {};
  const params =
    typeof window !== "undefined"
      ? new URLSearchParams(window.location.search)
      : new URLSearchParams();

  const wsUrl = injected.wsUrl ?? params.get("wsUrl") ?? undefined;
  const passphrase = injected.passphrase ?? params.get("passphrase") ?? undefined;
  const terminalIdRaw =
    injected.terminalId ?? params.get("terminalId") ?? undefined;

  let theme = injected.theme;
  if (!theme) {
    const themeParam = params.get("theme");
    if (themeParam) {
      try {
        theme = JSON.parse(themeParam) as BlitThemeInput;
      } catch {
        theme = undefined;
      }
    }
  }

  if (!wsUrl) throw new Error("blit config: missing wsUrl");
  if (!passphrase) throw new Error("blit config: missing passphrase");
  if (terminalIdRaw == null || terminalIdRaw === "") {
    throw new Error("blit config: missing terminalId");
  }
  const terminalId =
    typeof terminalIdRaw === "number"
      ? terminalIdRaw
      : parseInt(String(terminalIdRaw), 10);
  if (Number.isNaN(terminalId)) {
    throw new Error(`blit config: invalid terminalId "${terminalIdRaw}"`);
  }

  const snapshot = injected.snapshot ?? params.get("snapshot") ?? undefined;
  const isSuspended =
    injected.isSuspended ?? params.get("isSuspended") === "1" ?? false;

  return { wsUrl, passphrase, terminalId, theme, snapshot, isSuspended };
}

const DEFAULT_ANSI: Array<[number, number, number]> = [
  [0, 0, 0], // 0 black
  [205, 49, 49], // 1 red
  [13, 188, 121], // 2 green
  [229, 229, 16], // 3 yellow
  [36, 114, 200], // 4 blue
  [188, 63, 188], // 5 magenta
  [17, 168, 205], // 6 cyan
  [229, 229, 229], // 7 white
  [102, 102, 102], // 8 bright black
  [241, 76, 76], // 9 bright red
  [35, 209, 139], // 10 bright green
  [245, 245, 67], // 11 bright yellow
  [59, 142, 234], // 12 bright blue
  [214, 112, 214], // 13 bright magenta
  [41, 184, 219], // 14 bright cyan
  [255, 255, 255], // 15 bright white
];

/**
 * Build a blit TerminalPalette from the injected theme. Falls back to a
 * reasonable dark default for any field the native app omits.
 */
export function buildPalette(theme: BlitThemeInput | undefined): TerminalPalette {
  const fg = toRgb(theme?.fg) ?? [229, 229, 229];
  const bg = toRgb(theme?.bg) ?? [0, 0, 0];
  let ansi: Array<[number, number, number]> = DEFAULT_ANSI;
  if (theme?.ansi && theme.ansi.length > 0) {
    ansi = theme.ansi.map((c, i) => toRgb(c) ?? DEFAULT_ANSI[i] ?? [0, 0, 0]);
    // Ensure 16 entries.
    while (ansi.length < 16) ansi.push(DEFAULT_ANSI[ansi.length] ?? [0, 0, 0]);
  }
  return {
    id: "tbd-injected",
    name: "TBD",
    dark: theme?.dark ?? true,
    fg,
    bg,
    ansi,
  };
}

/** CSS color string from an [r,g,b] tuple. */
export function rgbCss(rgb: [number, number, number]): string {
  return `rgb(${rgb[0]}, ${rgb[1]}, ${rgb[2]})`;
}
