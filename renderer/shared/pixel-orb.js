// Halo's pixel orb: a little black hole — dark core with twinkling specks, a
// purple + cyan pixel rim that beats, pink sparks shooting out and dust drifting
// in. Used by the app icon script, the pill and the panel (the Touch Bar has a
// Swift port of the same rules in native/touchbar/HaloTouchBar.swift).
//
// orbCells() returns the lit cells of one frame on a square pixel grid; draw
// them with drawOrb() or any other way.

export const COLORS = {
  core: "#08031c",
  star1: "#2a1a8a",
  star2: "#4d2da6",
  star3: "#7a3fc8",
  rim: "#a64bf0",
  cyan: "#55e3f2",
  spark: "#ffd3ef",
  magenta: "#e041e6",
  dust: "#3b1f4d",
};

/** How often the orb animates in each state (ms per frame). */
export const FRAME_MS = { idle: 220, listening: 110, thinking: 90, speaking: 100, waiting: 300, followup: 160 };

const DIRS = [
  [1, 0], [-1, 0], [0, 1], [0, -1],
  [1, 1], [-1, 1], [1, -1], [-1, -1],
];

/**
 * @param {{ phase?: number, state?: string, level?: number, grid?: number, scale?: number, rand?: () => number }} o
 *   phase: beat 0..3 (small, medium, large, medium); speaking uses `level` instead
 *   scale: orb size relative to the 24-cell design (smaller grids scale it down)
 * @returns {[number, number, string][]} [x, y, color] cells
 */
export function orbCells({ phase = 0, state = "idle", level = 0, grid = 24, scale = 1, rand = Math.random } = {}) {
  const cells = new Map();
  const put = (x, y, color) => {
    x = Math.round(x);
    y = Math.round(y);
    if (x >= 0 && y >= 0 && x < grid && y < grid) cells.set(`${x},${y}`, [x, y, color]);
  };
  const c = (grid - 1) / 2;

  // Beat size: small / medium / large / medium. Speaking follows her voice.
  let size = [0, 1, 2, 1][phase % 4];
  if (state === "speaking") size = level > 0.55 ? 2 : level > 0.2 ? 1 : 0;
  if (state === "listening") size = Math.max(size, 1);
  const outer = [8, 8.5, 9.6][size] * scale; // purple rim's outer edge
  const rimW = [1, 1, 2][size];
  const cyanFull = size > 0 || state === "listening";

  for (let y = 0; y < grid; y++) {
    for (let x = 0; x < grid; x++) {
      const dx = x - c;
      const dy = y - c;
      const d = Math.hypot(dx, dy);
      if (d >= outer) continue;
      if (d >= outer - rimW) {
        // Thin rim: purple with cyan glints on the 8 compass points.
        const glint = !cyanFull && (Math.abs(dx) < 1.2 || Math.abs(dy) < 1.2 || Math.abs(Math.abs(dx) - Math.abs(dy)) < 1);
        put(x, y, glint ? COLORS.cyan : COLORS.rim);
      } else if (cyanFull && d >= outer - rimW - 1) {
        put(x, y, COLORS.cyan);
      } else {
        put(x, y, COLORS.core);
      }
    }
  }

  // Specks inside the void.
  const inner = outer - rimW - (cyanFull ? 1 : 0) - 1.5;
  const specks = 4 + Math.floor(rand() * 3);
  for (let i = 0; i < specks; i++) {
    const a = rand() * Math.PI * 2;
    const r = Math.sqrt(rand()) * inner;
    const color = [COLORS.star1, COLORS.star2, COLORS.star3][Math.floor(rand() * 3)];
    const x = c + Math.cos(a) * r;
    const y = c + Math.sin(a) * r;
    put(x, y, color);
    if (rand() < 0.3) put(x + 1, y + 1, color); // some specks are 2×2
  }

  const edge = outer + 0.5;
  const max = grid / 2 - 0.5;

  // Pink streak shooting straight out (cardinal) — her energy.
  const streak = () => {
    const [ux, uy] = DIRS[Math.floor(rand() * 4)];
    const start = edge + 1 + rand() * 2;
    const len = 2 + Math.floor(rand() * 3);
    for (let i = 0; i < len && start + i <= max; i++) put(c + ux * (start + i), c + uy * (start + i), COLORS.spark);
  };
  // Burst of diagonal sparks.
  const burst = () => {
    for (const [ux, uy] of DIRS.slice(4)) {
      for (let i = 0; i < 3; i++) {
        const r = edge * 0.72 + 1 + i;
        if (r <= max) put(c + ux * r, c + uy * r, i === 0 ? COLORS.spark : COLORS.spark);
      }
    }
  };
  // Single magenta specks floating around.
  const mote = () => {
    const a = rand() * Math.PI * 2;
    const r = edge + 1 + rand() * (max - edge - 1);
    put(c + Math.cos(a) * r, c + Math.sin(a) * r, COLORS.magenta);
  };
  // Dark dust drifting in (closer to the rim while she listens).
  const dust = (close) => {
    const a = rand() * Math.PI * 2;
    const r = close ? edge + rand() * 1.5 : edge + 1 + rand() * 3;
    const x = c + Math.cos(a) * r;
    const y = c + Math.sin(a) * r;
    put(x, y, COLORS.dust);
    put(x + 1, y, COLORS.dust);
    if (rand() < 0.5) put(x, y + 1, COLORS.dust);
  };

  switch (state) {
    case "listening":
      for (let i = 0; i < 3; i++) dust(true);
      if (rand() < 0.5) mote();
      break;
    case "thinking":
      streak();
      mote();
      if (rand() < 0.35) burst();
      break;
    case "speaking":
      if (level > 0.5) burst();
      if (level > 0.15 || rand() < 0.4) streak();
      mote();
      break;
    case "waiting":
      if (rand() < 0.3) mote();
      break;
    default: // idle, followup
      if (rand() < 0.35) streak();
      if (rand() < 0.6) mote();
      if (rand() < 0.5) dust(false);
  }
  return [...cells.values()];
}

/** Draw a frame on a canvas, crisp (no smoothing), centered and scaled to fit. */
export function drawOrb(canvas, frame) {
  const ctx = canvas.getContext("2d");
  const grid = frame.grid ?? 24;
  const px = Math.floor(Math.min(canvas.width, canvas.height) / grid) || 1;
  const off = Math.floor((canvas.width - px * grid) / 2);
  ctx.imageSmoothingEnabled = false;
  ctx.clearRect(0, 0, canvas.width, canvas.height);
  for (const [x, y, color] of orbCells(frame)) {
    ctx.fillStyle = color;
    ctx.fillRect(off + x * px, off + y * px, px, px);
  }
}

/**
 * Animate a canvas: getState() → { state, level }. Returns a stop function.
 * The canvas is sized to its CSS box × devicePixelRatio for crisp pixels.
 * Small orbs use a coarser grid so the pixels stay chunky (default 16 cells).
 */
export function animateOrb(canvas, getState, { grid = 16, scale = 0.72 } = {}) {
  const dpr = window.devicePixelRatio || 1;
  const fit = () => {
    const r = canvas.getBoundingClientRect();
    canvas.width = Math.round(r.width * dpr);
    canvas.height = Math.round(r.height * dpr);
  };
  fit();
  let phase = 0;
  let last = 0;
  let raf = 0;
  const loop = (t) => {
    const { state = "idle", level = 0 } = getState();
    if (t - last >= (FRAME_MS[state] ?? 200)) {
      last = t;
      phase = (phase + 1) % 4;
      drawOrb(canvas, { phase, state, level, grid, scale });
    }
    raf = requestAnimationFrame(loop);
  };
  raf = requestAnimationFrame(loop);
  return () => cancelAnimationFrame(raf);
}
