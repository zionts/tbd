// Minimal ANSI→HTML renderer for the suspended-terminal snapshot (Phase 8,
// feature 1). blit's WASM Terminal only ingests LZ4-compressed deltas
// (`feed_compressed`), so it cannot render a raw captured ANSI string. Rather
// than pull in a heavyweight emulator (xterm.js) and break the self-contained
// single-file bundle, we render the static snapshot with a small SGR parser:
// it handles the colour/bold/dim/inverse attributes that show up in a captured
// shell/Claude screen and ignores cursor-movement / mode sequences (a static
// snapshot needs no cursor). Output is one <span>-styled line per input line.

import type { TerminalPalette } from "@blit-sh/core";
import { rgbCss } from "./config";

interface SgrState {
  fg: [number, number, number] | null;
  bg: [number, number, number] | null;
  bold: boolean;
  dim: boolean;
  inverse: boolean;
  underline: boolean;
}

function freshState(): SgrState {
  return {
    fg: null,
    bg: null,
    bold: false,
    dim: false,
    inverse: false,
    underline: false,
  };
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}

/** Resolve an ANSI 256/16 colour index to an [r,g,b] tuple via the palette. */
function paletteColor(
  index: number,
  palette: TerminalPalette,
): [number, number, number] {
  if (index < 16) return palette.ansi[index] ?? [0, 0, 0];
  if (index < 232) {
    // 6x6x6 colour cube.
    const i = index - 16;
    const r = Math.floor(i / 36);
    const g = Math.floor((i % 36) / 6);
    const b = i % 6;
    const v = (n: number) => (n === 0 ? 0 : 55 + n * 40);
    return [v(r), v(g), v(b)];
  }
  // Greyscale ramp.
  const level = 8 + (index - 232) * 10;
  return [level, level, level];
}

/** Apply a single SGR parameter list to `state` (mutating). */
function applySgr(params: number[], state: SgrState, palette: TerminalPalette) {
  let i = 0;
  if (params.length === 0) params = [0];
  while (i < params.length) {
    const p = params[i];
    switch (p) {
      case 0:
        Object.assign(state, freshState());
        break;
      case 1:
        state.bold = true;
        break;
      case 2:
        state.dim = true;
        break;
      case 4:
        state.underline = true;
        break;
      case 7:
        state.inverse = true;
        break;
      case 22:
        state.bold = false;
        state.dim = false;
        break;
      case 24:
        state.underline = false;
        break;
      case 27:
        state.inverse = false;
        break;
      case 39:
        state.fg = null;
        break;
      case 49:
        state.bg = null;
        break;
      case 38:
      case 48: {
        const isFg = p === 38;
        const mode = params[i + 1];
        if (mode === 5) {
          const idx = params[i + 2] ?? 0;
          const c = paletteColor(idx, palette);
          if (isFg) state.fg = c;
          else state.bg = c;
          i += 2;
        } else if (mode === 2) {
          const c: [number, number, number] = [
            params[i + 2] ?? 0,
            params[i + 3] ?? 0,
            params[i + 4] ?? 0,
          ];
          if (isFg) state.fg = c;
          else state.bg = c;
          i += 4;
        }
        break;
      }
      default:
        if (p >= 30 && p <= 37) state.fg = paletteColor(p - 30, palette);
        else if (p >= 40 && p <= 47) state.bg = paletteColor(p - 40, palette);
        else if (p >= 90 && p <= 97) state.fg = paletteColor(p - 90 + 8, palette);
        else if (p >= 100 && p <= 107)
          state.bg = paletteColor(p - 100 + 8, palette);
        break;
    }
    i++;
  }
}

function spanStyle(state: SgrState, palette: TerminalPalette): string {
  let fg = state.fg ?? palette.fg;
  let bg = state.bg ?? null;
  if (state.inverse) {
    const realFg = fg;
    fg = bg ?? palette.bg;
    bg = realFg;
  }
  const parts: string[] = [`color:${rgbCss(fg)}`];
  if (bg) parts.push(`background-color:${rgbCss(bg)}`);
  if (state.bold) parts.push("font-weight:bold");
  if (state.dim) parts.push("opacity:0.6");
  if (state.underline) parts.push("text-decoration:underline");
  return parts.join(";");
}

/**
 * Render an ANSI snapshot string to a block of styled HTML. Carriage returns
 * are normalised, escape sequences other than SGR (`CSI … m`) are stripped, and
 * each terminal line becomes a `<div>` of styled `<span>`s. State carries
 * across lines so a colour set on one row persists like a real terminal.
 */
export function ansiToHtml(input: string, palette: TerminalPalette): string {
  // eslint-disable-next-line no-control-regex
  const csiRe = /\[([0-9;]*)([A-Za-z])/g;
  // Drop OSC sequences (titles etc.) entirely: ESC ] … BEL or ESC \.
  // eslint-disable-next-line no-control-regex
  const oscRe = /\][^]*(?:|\\)/g;

  const cleaned = input.replace(oscRe, "");
  const lines = cleaned.split(/\r?\n/);
  const state = freshState();
  const out: string[] = [];

  for (const line of lines) {
    let html = "";
    let lastIndex = 0;
    let open = false;
    const pushText = (text: string) => {
      if (!text) return;
      if (open) html += "</span>";
      html += `<span style="${spanStyle(state, palette)}">${escapeHtml(text)}</span>`;
      open = true;
    };
    csiRe.lastIndex = 0;
    let m: RegExpExecArray | null;
    // eslint-disable-next-line no-cond-assign
    while ((m = csiRe.exec(line)) !== null) {
      pushText(line.slice(lastIndex, m.index));
      lastIndex = csiRe.lastIndex;
      if (m[2] === "m") {
        const params = m[1]
          .split(";")
          .filter((x) => x !== "")
          .map((x) => parseInt(x, 10));
        applySgr(params, state, palette);
      }
      // Non-SGR CSI (cursor moves etc.) are dropped — irrelevant for a static
      // snapshot.
    }
    pushText(line.slice(lastIndex));
    out.push(`<div class="tbd-snap-line">${html || "&nbsp;"}</div>`);
  }
  return out.join("");
}
