// Builds the six feature figures on the landing page with the Anatomy kit
// (https://github.com/wheresryan22/anatomy, MIT, vendored in ./kit) and writes
// them, their styles and their live script into ../index.html between markers.
//
//   node www/figures/build.mjs
import { readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import * as k from "./kit/iso-kit.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const PAGE = join(HERE, "..", "index.html");
const W = 400;
const H = 210;

const S = (paths, style) => k.solidSvg(paths, style);
const L = (d, style) => k.lineSvg(d, style);
const D = (points, style) => k.dotsSvg(points, style);
const fit = (points, options = {}) => k.fitProjection(points, W, H, { pad: 14, ...options });
const byDepth = (items, P, at = (item) => item) =>
  [...items].sort((a, b) => k.depthOf(at(a), P) - k.depthOf(at(b), P));
const closed = (points, P) => k.pathOf(points.map((point) => k.iso(point, P))) + "Z";
const json = (value) => JSON.stringify(value);

// A machined base plate on four feet, with a groove, corner screws and,
// optionally, a ruler strip along the front edge.
function base(plate, P, { h = 8, foot = 4, ruler = null, label = null } = {}) {
  const out = [`<path class="iso-halo" d="${k.haloOf(plate, -h - foot, h, P)}"/>`];
  for (const [x, y] of byDepth(k.corners(plate, 16), P, ([x, y]) => [x, y, 0])) {
    out.push(S(k.cylinder(x, y, 6, -h - foot, 1.4, P, 24), { tone: "lo" }));
    out.push(S(k.cylinder(x, y, 4.6, -h - foot + 1.4, foot - 1.4, P, 24), { tone: "mid" }));
  }
  out.push(S(k.slabOf(plate, -h, h, P, 8, 1.4), { tone: "mid" }));
  out.push(L(k.planOutline(k.insetPlan(plate, 4.5), 0, P), { tone: "faint" }));
  const screws = k.corners(plate, 9);
  out.push(L(screws.map(([x, y]) => k.ring(x, y, 2, 0, P, 14)).join(""), { tone: "lo" }));
  out.push(D(screws.map(([x, y]) => k.iso([x, y, 0], P)), { size: 0.5 }));
  if (ruler) {
    out.push(S(k.slabOf(ruler, 0, 0.6, P, 3), { tone: "lo", crease: "none" }));
    const ticks = k.topTicks(ruler.x + 3, ruler.x + ruler.w - 3, 4, 5, ruler.y + 0.6, 0.6, [1.8, 3.4], P);
    out.push(L(ticks.minor, { tone: "lo" }), L(ticks.major, { tone: "mid" }));
  }
  if (label) out.push(labelPlate(label, P));
  return out.join("");
}

// A small engraved plate: three rule lines stand for printed text.
function labelPlate(plan, P, z = 0) {
  const out = [S(k.slabOf(plan, z, 0.6, P, 3), { tone: "lo", crease: "none" })];
  const top = z + 0.6;
  const rows = [0.3, 0.55, 0.8].map((t, index) => {
    const y = plan.y + plan.d * t;
    const to = plan.x + plan.w * (index === 0 ? 0.78 : index === 1 ? 0.62 : 0.7);
    return k.lineOnTop([plan.x + 3, y], [to, y], top, P);
  });
  out.push(L(rows.join(""), { tone: "lo", free: true }));
  out.push(D([k.iso([plan.x + 1.4, plan.y + plan.d / 2, top], P), k.iso([plan.x + plan.w - 1.4, plan.y + plan.d / 2, top], P)], { size: 0.4 }));
  return out.join("");
}

function frame(name, fig, label, body) {
  return {
    name,
    html:
      k.figureSvg({ width: W, height: H, label, body }) +
      `<div class="fig-meta"><span>Fig ${fig}</span><span data-readout></span></div>`,
  };
}

// ---------------------------------------------------------------------------
// Fig 1 — two sleds on a timing bench. Each lane's sled covers the same
// distance in a time proportional to the measured median for one input.
function speed() {
  const PLATE = { x: -126, y: -50, w: 252, d: 100, r: 6 };
  const LANES = [-18, 18];
  const X0 = -90;
  const X1 = 70;
  const GATE = 100;
  const P = fit([...k.boxCorners(PLATE, -12, 0), [GATE, -42, 44], [GATE, 42, 44]], { azimuth: 62 });
  const at = (point) => k.iso(point, P);

  const lane = (y) => {
    const out = [];
    out.push(S(k.slabOf({ x: -114, y: y - 11, w: 214, d: 22, r: 2 }, 0, 1.2, P, 3), { tone: "lo", crease: "none" }));
    for (const dy of [-7.2, 4.8])
      out.push(S(k.slabOf({ x: -112, y: y + dy, w: 210, d: 2.4, r: 0.8 }, 1.2, 2.2, P, 2, 0.3), { tone: "mid" }));
    out.push(S(k.slabOf({ x: -118, y: y - 10, w: 5, d: 20, r: 1 }, 1.2, 7, P, 3, 0.4), { tone: "mid" }));
    out.push(D([at([-115.5, y - 6, 8.2]), at([-115.5, y + 6, 8.2])], { size: 0.4 }));
    out.push(L(k.lineOnTop([X1 + 21, y - 9], [X1 + 21, y + 9], 1.2, P), { tone: "mid" }));
    out.push(D([at([X1 + 21, y - 9.6, 1.2]), at([X1 + 21, y + 9.6, 1.2])], { size: 0.5 }));
    return out.join("");
  };
  const sled = (y, lit, index) => {
    const out = [`<path class="iso-halo" d="${k.haloOf({ x: -17, y: y - 8, w: 34, d: 16, r: 2 }, 3.4, 0.1, P)}" style="filter:blur(3px)"/>`];
    out.push(S(k.slabOf({ x: -18, y: y - 9, w: 36, d: 18, r: 2.4 }, 3.4, 5, P, 4, 0.6), { tone: "mid" }));
    out.push(D([-14, -4, 6, 14].map((x) => at([x, y + 6.8, 8.4])), { size: 0.4, tone: "lo" }));
    [0, 1, 2, 3].forEach((i) => {
      const plan = { x: -15 + i * 8.2, y: y - 5.5, w: 7, d: 11, r: 0.9 };
      out.push(S(k.slabOf(plan, 8.4, 4 + i * 1.8, P, 2, 0.3), { tone: "hi", crease: "lo", lit }));
    });
    out.push(S(k.slabOf({ x: 17.6, y: y - 2.5, w: 2.6, d: 5, r: 0.8 }, 4.6, 2.6, P, 2), { tone: "mid", crease: "none" }));
    return `<g data-part="sled-${index}" transform="${k.translateAlong(P, [X0, 0, 0])}">${out.join("")}</g>`;
  };
  const post = (y) =>
    S(k.cylinder(GATE, y, 4.4, 0, 1.6, P, 20), { tone: "lo" }) +
    S(k.cylinder(GATE, y, 2.2, 1.6, 36.4, P, 18), { tone: "mid", crease: "none" }) +
    L(k.sideArc(GATE, y, 2.2, 12, P, 10), { tone: "faint" });
  const gate = () => {
    const out = [S(k.slabOf({ x: GATE - 2.6, y: -43, w: 5.2, d: 86, r: 1.2 }, 38, 4, P, 3, 0.4), { tone: "mid" })];
    out.push(D([at([GATE, -39, 42]), at([GATE, 39, 42])], { size: 0.45 }));
    LANES.forEach((y, index) => {
      out.push(S(k.cylinder(GATE, y, 2.8, 33, 5, P, 18), { tone: "mid" }));
      out.push(`<g data-part="lamp-${index}">${S(k.cylinder(GATE, y, 1.9, 31.6, 1.4, P, 16), { tone: "hi", crease: "none" })}</g>`);
    });
    return out.join("");
  };

  const body = [
    base(PLATE, P, {
      ruler: { x: -112, y: PLATE.y + PLATE.d - 9, w: 196, d: 5.5, r: 1 },
      label: { x: -112, y: -46.5, w: 30, d: 6, r: 1 },
    }),
    post(-40),
    lane(LANES[0]),
    sled(LANES[0], false, 0),
    lane(LANES[1]),
    sled(LANES[1], true, 1),
    post(40),
    gate(),
  ];
  const live = `(svg, say) => {
  const P = ${json(P)}, X0 = ${X0}, X1 = ${X1};
  const RUNS = [["csi-heavy", 483.0, 226.6], ["ghostty-styled", 421.7, 185.2], ["osc-heavy", 1241.2, 378.4], ["scroll", 414.8, 306.9], ["compiler-log", 142.7, 111.6]];
  const sleds = [0, 1].map((i) => svg.querySelector('[data-part="sled-' + i + '"]'));
  const lamps = [0, 1].map((i) => svg.querySelector('[data-part="lamp-' + i + '"] .iso-solid'));
  const TS = 1.5, GAP = 0.6, HOLD = 1.6, BACK = 0.9;
  const ease = (u) => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
  let run = 0, time = 0;
  const place = (ghost, swift, lit) => {
    sleds[0].setAttribute("transform", translateAlong(P, [X0 + (X1 - X0) * ghost, 0, 0]));
    sleds[1].setAttribute("transform", translateAlong(P, [X0 + (X1 - X0) * swift, 0, 0]));
    lamps.forEach((lamp, i) => lamp.toggleAttribute("data-lit", lit[i]));
  };
  const text = ([name, ghostty, swiftty]) => name + " · " + swiftty.toFixed(1) + " vs " + ghostty.toFixed(1) + " ms";
  return {
    tick(dt) {
      const [name, ghostty, swiftty] = RUNS[run];
      const TG = TS * ghostty / swiftty, RACE = GAP + TG, END = RACE + HOLD + BACK;
      time += dt;
      if (time >= END) { time -= END; run = (run + 1) % RUNS.length; return this.tick(0); }
      if (time < RACE) {
        const t = time - GAP;
        place(ease(t / TG), ease(t / TS), [t >= TG, t >= TS]);
      } else if (time < RACE + HOLD) place(1, 1, [true, true]);
      else { const back = 1 - ease((time - RACE - HOLD) / BACK); place(back, back, [false, false]); }
      say(text(RUNS[run]));
    },
    still() {
      const [, ghostty, swiftty] = RUNS[0];
      place(swiftty / ghostty, 1, [false, true]);
      say(text(RUNS[0]));
    },
  };
}`;
  return {
    ...frame(
      "speed",
      1,
      "A timing bench with two lanes. Both sleds cover the same track; the lit Swiftty sled reaches the gate first, in the measured ratio of median parse times for each benchmark input.",
      body,
    ),
    live,
  };
}

// ---------------------------------------------------------------------------
// Fig 2 — a chase of type cells under a gantry. The read head sweeps one
// column at a time; the cells damaged in this frame lift as it passes.
function render() {
  const PLATE = { x: -114, y: -58, w: 228, d: 116, r: 6 };
  const COLS = 10;
  const ROWS = 4;
  const PITCH = 14.4;
  const CELL = 12;
  const GW = COLS * PITCH - (PITCH - CELL);
  const GD = ROWS * PITCH - (PITCH - CELL);
  const X = -GW / 2;
  const Y = -GD / 2;
  const CHASE = { x: X - 6, y: Y - 6, w: GW + 12, d: GD + 12, r: 3 };
  const RAIL_Y = CHASE.d / 2 + 9;
  const CELL_Z = 4;
  const CELL_H = 5;
  const P = fit([...k.boxCorners(PLATE, -12, 0), [0, -RAIL_Y, 36], [0, RAIL_Y, 36]], { azimuth: 58 });
  const at = (point) => k.iso(point, P);

  const cells = [];
  for (let row = 0; row < ROWS; row++)
    for (let col = 0; col < COLS; col++)
      cells.push({ index: row * COLS + col, row, col, x: X + col * PITCH, y: Y + row * PITCH });
  // A short shell session as glyph strokes: "$ ls -la", output columns, prompt.
  const GLYPH = ["$ ls -la ", "drwx  src", "-rw-  pkg", "$ _      "];
  const glyph = (cell) => {
    const ch = (GLYPH[cell.row] || "")[cell.col] || " ";
    const cx = cell.x + CELL / 2;
    const cy = cell.y + CELL / 2;
    const z = CELL_Z + CELL_H;
    if (ch === " ") return "";
    if (ch === "_" ) return k.lineOnTop([cx - 3, cy + 3], [cx + 3, cy + 3], z, P);
    if (ch === "-") return k.lineOnTop([cx - 3, cy], [cx + 3, cy], z, P);
    if (ch === "$") return k.onTop([[cx + 2.6, cy - 3], [cx - 2.6, cy - 1], [cx + 2.6, cy + 1], [cx - 2.6, cy + 3]], z, P);
    if ("lrd".includes(ch)) return k.lineOnTop([cx, cy - 3.4], [cx, cy + 3.4], z, P);
    return k.lineOnTop([cx - 2.6, cy - 2.4], [cx + 2.6, cy - 2.4], z, P) + k.lineOnTop([cx - 2.6, cy + 2.4], [cx + 1.4, cy + 2.4], z, P);
  };
  const cellSvg = (cell) => {
    const plan = { x: cell.x, y: cell.y, w: CELL, d: CELL, r: 1.2 };
    const art = S(k.slabOf(plan, CELL_Z, CELL_H, P, 2, 0.4), { tone: "mid", crease: "lo" }) + L(glyph(cell), { tone: "hi", free: true });
    return `<g data-cell="${cell.index}">${art}</g>`;
  };
  const rail = (y) =>
    S(k.slabOf({ x: -106, y: y - 2.5, w: 212, d: 5, r: 1 }, 0, 3, P, 2, 0.4), { tone: "mid" }) +
    S(k.slabOf({ x: -110, y: y - 4, w: 4, d: 8, r: 1 }, 0, 6, P, 2), { tone: "mid" }) +
    S(k.slabOf({ x: 106, y: y - 4, w: 4, d: 8, r: 1 }, 0, 6, P, 2), { tone: "mid" });
  const upright = (y, sign) =>
    S(k.slabOf({ x: -7, y: y - 5, w: 14, d: 10, r: 2 }, 3, 4, P, 3, 0.5), { tone: "mid" }) +
    S(k.slabOf({ x: -3, y: y - 2 - sign * 0, w: 6, d: 4, r: 1 }, 7, 22, P, 2, 0.3), { tone: "mid" }) +
    D([at([-4.5, y + 3.6, 7]), at([4.5, y + 3.6, 7])], { size: 0.4 });
  const gantryBack = `<g data-part="gantry-back">${upright(-RAIL_Y, -1)}</g>`;
  const gantryFront =
    `<g data-part="gantry-front">` +
    S(k.slabOf({ x: -3.2, y: -4.5, w: 6.4, d: 9, r: 1.2 }, 21, 8, P, 2, 0.4), { tone: "hi", crease: "lo" }) +
    S(k.slabOf({ x: -4, y: -RAIL_Y - 3, w: 8, d: 2 * RAIL_Y + 6, r: 1.5 }, 29, 5, P, 3, 0.5), { tone: "mid" }) +
    D([-RAIL_Y + 2, -10, 10, RAIL_Y - 2].map((y) => at([0, y, 34])), { size: 0.45 }) +
    upright(RAIL_Y, 1) +
    `</g>`;

  const body = [
    base(PLATE, P, { label: { x: PLATE.x + 10, y: PLATE.y + PLATE.d - 13, w: 30, d: 8, r: 1 } }),
    rail(-RAIL_Y),
    gantryBack,
    S(k.slabOf(CHASE, 0, CELL_Z, P, 4, 0.6), { tone: "mid" }),
    L(k.planOutline(k.insetPlan(CHASE, 2.6), CELL_Z, P, 3), { tone: "faint" }),
    D(k.corners(CHASE, 2.6).map(([x, y]) => at([x, y, CELL_Z])), { size: 0.45 }),
    ...byDepth(cells, P, (c) => [c.x + CELL / 2, c.y + CELL / 2, 0]).map(cellSvg),
    rail(RAIL_Y),
    gantryFront,
  ];
  const live = `(svg, say) => {
  const P = ${json(P)}, X = ${X}, PITCH = ${PITCH}, CELL = ${CELL}, COLS = ${COLS}, ROWS = ${ROWS};
  const cells = [...svg.querySelectorAll("[data-cell]")].sort((a, b) => a.dataset.cell - b.dataset.cell);
  const solids = cells.map((cell) => cell.querySelector(".iso-solid"));
  const parts = [svg.querySelector('[data-part="gantry-back"]'), svg.querySelector('[data-part="gantry-front"]')];
  const lift = cells.map(() => ({ at: 0, rate: 0 }));
  const SWEEP = 3.4, FROM = X + CELL / 2 - PITCH * 0.6, TO = X + (COLS - 1) * PITCH + CELL / 2 + PITCH * 0.6;
  const damaged = (frame, index) => ((index * 2654435761 + frame * 40503) >>> 0) % 7 === 0;
  let time = 0, frame = 1204, cursor = -1;
  const draw = (gx, count) => {
    parts.forEach((part) => part.setAttribute("transform", translateAlong(P, [gx, 0, 0])));
    cells.forEach((cell, i) => cell.setAttribute("transform", translateAlong(P, [0, 0, lift[i].at])));
    solids.forEach((solid, i) => solid.toggleAttribute("data-lit", i === cursor));
    say("frame " + frame.toLocaleString("en") + " · " + count + " cells redrawn");
  };
  const step = (dt, calm) => {
    const u = (time % (2 * SWEEP)) / SWEEP, leg = u < 1 ? u : 2 - u;
    const s = leg * leg * (3 - 2 * leg), gx = FROM + (TO - FROM) * s;
    let count = 0;
    cells.forEach((cell, i) => {
      const cx = X + (i % COLS) * PITCH + CELL / 2, near = Math.abs(cx - gx) < PITCH * 0.55;
      const hit = damaged(frame, i);
      if (hit && (u < 1 ? cx <= gx : cx >= gx)) count++;
      if (hit && near) cursor = i;
      const want = hit && near ? 5 : 0, spring = lift[i];
      if (calm) { spring.at = want; spring.rate = 0; return; }
      for (let n = 0; n < 4; n++) { spring.rate += ((want - spring.at) * 260 - spring.rate * 16) * dt / 4; spring.at += spring.rate * dt / 4; }
    });
    draw(gx, count);
  };
  return {
    tick(dt) {
      const before = Math.floor(time / SWEEP);
      time += dt;
      if (Math.floor(time / SWEEP) !== before) frame++;
      step(dt, false);
    },
    still() { time = SWEEP * 0.55; step(0, true); },
  };
}`;
  return {
    ...frame(
      "render",
      2,
      "A chase of type cells holding a short shell session, under a gantry with a read head. The head sweeps the grid one column at a time, and only the cells damaged in this frame lift as it passes.",
      body,
    ),
    live,
  };
}

// ---------------------------------------------------------------------------
// Fig 3 — the agent keeps the shell. A flywheel on the agent unit keeps
// turning while the window panel lifts out of its dock and back.
function mux() {
  const PLATE = { x: -106, y: -56, w: 212, d: 112, r: 6 };
  const BOX = { x: -80, y: -40, w: 94, d: 80, r: 6 };
  const BOX_H = 28;
  const REEL = [-48, -6];
  const REEL_R = 21;
  const DOCK = { x: -14, y: -25, w: 16, d: 50, r: 2 };
  const PANEL = { x: -9, y: -23, w: 6, d: 46, r: 1.5 };
  const PANEL_Z = BOX_H + 3;
  const PANEL_H = 46;
  const P = fit([...k.boxCorners(PLATE, -12, 0), [PANEL.x, PANEL.y, PANEL_Z + PANEL_H + 26], [PANEL.x + 36, PANEL.y + PANEL.d, PANEL_Z + PANEL_H + 26]], { azimuth: 52 });
  const at = (point) => k.iso(point, P);
  const top = BOX_H;

  const vents = [];
  for (let x = BOX.x + 14; x <= BOX.x + 50; x += 4.5)
    vents.push(closed([[x - 0.9, BOX.y + BOX.d, 7], [x + 0.9, BOX.y + BOX.d, 7], [x + 0.9, BOX.y + BOX.d, 19], [x - 0.9, BOX.y + BOX.d, 19]], P));
  const face = BOX.x + BOX.w;
  const box = [
    S(k.slabOf(BOX, 0, BOX_H, P, 8, 1), { tone: "mid", inner: L(k.sideSeam(BOX, 6, P, 8), { tone: "faint" }) }),
    L(vents.join(""), { tone: "lo" }),
    D(k.dotGrid(BOX.x + 12, BOX.y + BOX.d - 11, 16, 2, 3.2, top, P), { size: 0.55, tone: "lo" }),
    D([at([face, BOX.y + BOX.d - 10, 19]), at([face, BOX.y + BOX.d - 16, 19])], { size: 0.9, tone: "hi" }),
    `<g data-part="led">${D([at([face, BOX.y + BOX.d - 22, 19])], { size: 1.1, tone: "hi" })}</g>`,
    D(k.corners(k.insetPlan(BOX, 0), 5).map(([x, y]) => at([x, y, top])), { size: 0.45 }),
  ].join("");
  const reel = [
    S(k.cylinder(REEL[0], REEL[1], REEL_R + 3, top, 1.6, P, 48), { tone: "lo" }),
    S(k.cylinder(REEL[0], REEL[1], REEL_R, top + 1.6, 5, P, 64, 0.6), { tone: "hi", crease: "lo" }),
    L(k.knurl(REEL[0], REEL[1], REEL_R, top + 2.4, top + 6.2, 72, P, 0.3), { tone: "lo" }),
    L(k.ring(REEL[0], REEL[1], REEL_R - 3, top + 6.6, P, 56), { tone: "lo" }),
    `<path data-part="spokes" class="iso-line" data-tone="mid" d=""/>`,
    `<g data-part="marker"></g>`,
    S(k.cylinder(REEL[0], REEL[1], 4.6, top + 6.6, 2.4, P, 24), { tone: "mid" }),
    D([at([REEL[0], REEL[1], top + 9])], { size: 0.8, tone: "hi" }),
  ].join("");
  const dock = [
    S(k.slabOf(DOCK, top, 3, P, 3, 0.5), { tone: "mid" }),
    D([DOCK.y + 4, DOCK.y + DOCK.d - 4].map((y) => at([DOCK.x + DOCK.w - 3, y, top + 3])), { size: 0.45 }),
  ].join("");
  const fx = PANEL.x + PANEL.w;
  const screen = { y0: PANEL.y + 3, y1: PANEL.y + PANEL.d - 3, z0: PANEL_Z + 3, z1: PANEL_Z + PANEL_H - 3 };
  const rows = [9, 15, 21, 27].map((dz, index) => {
    const z = screen.z1 - dz;
    const to = screen.y0 + 4 + [26, 18, 30, 8][index];
    return k.segment([fx, screen.y0 + 3, z], [fx, to, z], P);
  });
  const panel = [
    S(k.slabOf(PANEL, PANEL_Z, PANEL_H, P, 3, 0.5), {
      tone: "hi",
      crease: "lo",
      inner:
        L(closed([[fx, screen.y0, screen.z0], [fx, screen.y1, screen.z0], [fx, screen.y1, screen.z1], [fx, screen.y0, screen.z1]], P), { tone: "lo" }) +
        L(k.segment([fx, screen.y0, screen.z1 - 4], [fx, screen.y1, screen.z1 - 4], P), { tone: "faint" }) +
        L(rows.join(""), { tone: "mid", free: true }) +
        D([0, 1, 2].map((i) => at([fx, screen.y0 + 2.4 + i * 2.6, screen.z1 - 2])), { size: 0.55, tone: "mid" }),
    }),
    `<g data-part="cursor">${D([at([fx, screen.y0 + 14, screen.z1 - 27])], { size: 1.2, tone: "hi" })}</g>`,
  ].join("");

  const body = [
    base(PLATE, P, { label: { x: PLATE.x + 10, y: PLATE.y + PLATE.d - 13, w: 30, d: 8, r: 1 } }),
    box,
    reel,
    dock,
    `<g data-part="panel">${panel}</g>`,
  ];
  const live = `(svg, say) => {
  const P = ${json(P)}, C = ${json(REEL)}, R = ${REEL_R}, Z = ${top + 6.6};
  const spokes = svg.querySelector('[data-part="spokes"]');
  const marker = svg.querySelector('[data-part="marker"]');
  const panel = svg.querySelector('[data-part="panel"]');
  const cursor = svg.querySelector('[data-part="cursor"]');
  const ATTACHED = 3, MOVE = 1, DETACHED = 2.2, CYCLE = ATTACHED + MOVE + DETACHED + MOVE;
  const ease = (u) => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
  let time = 0, up = 42;
  const spin = (angle) => {
    let d = "";
    for (let i = 0; i < 3; i++) {
      const a = angle + (i * Math.PI * 2) / 3;
      d += lineOnTop([C[0] + Math.cos(a) * 3, C[1] + Math.sin(a) * 3], [C[0] + Math.cos(a) * (R - 3), C[1] + Math.sin(a) * (R - 3)], Z, P);
    }
    spokes.setAttribute("d", d);
    const m = iso([C[0] + Math.cos(angle) * (R - 1.4), C[1] + Math.sin(angle) * (R - 1.4), Z], P);
    marker.innerHTML = '<g class="iso-dots" data-tone="hi"><circle cx="' + m[0].toFixed(1) + '" cy="' + m[1].toFixed(1) + '" r="1.3" class="fig-lit"/></g>';
  };
  const clock = (s) => Math.floor(s / 60) + ":" + String(Math.floor(s % 60)).padStart(2, "0");
  const draw = (out, blink) => {
    panel.setAttribute("transform", translateAlong(P, [out * 32, 0, out * 24]));
    panel.style.opacity = String(1 - out * 0.72);
    cursor.style.opacity = blink ? "1" : "0";
    say((out > 0.5 ? "detached" : "attached") + " · shell up " + clock(up));
  };
  return {
    tick(dt) {
      time += dt; up += dt;
      const t = time % CYCLE;
      const out = t < ATTACHED ? 0 : t < ATTACHED + MOVE ? ease((t - ATTACHED) / MOVE) : t < ATTACHED + MOVE + DETACHED ? 1 : 1 - ease((t - ATTACHED - MOVE - DETACHED) / MOVE);
      spin(up * 1.6);
      draw(out, Math.floor(up * 1.6) % 2 === 0);
    },
    still() { spin(0.6); draw(0, true); },
  };
}`;
  return {
    ...frame(
      "mux",
      3,
      "An agent unit on a base plate. Its flywheel, the shell, keeps turning while the window panel lifts out of its dock and returns; the uptime keeps counting either way.",
      body,
    ),
    live,
  };
}

// ---------------------------------------------------------------------------
// Fig 4 — a phone on a rail between two masts. Complete screens keep
// arriving from the Mac while the path moves from one mast to the other.
function roam() {
  const PLATE = { x: -126, y: -50, w: 252, d: 100, r: 6 };
  const MAC = { x: -112, y: -40, w: 44, d: 30, r: 3 };
  const MAC_H = 18;
  const MASTS = [[-30, -30], [68, -30]];
  const MAST_TOP = 56;
  const RAIL = { x: -62, y: 13, w: 154, d: 10, r: 2 };
  const STOPS = [-30, 68];
  const P = fit([...k.boxCorners(PLATE, -12, 0), [MASTS[0][0], MASTS[0][1], MAST_TOP + 2], [MASTS[1][0], MASTS[1][1], MAST_TOP + 2]], { azimuth: 60 });
  const at = (point) => k.iso(point, P);

  const mast = ([x, y], index) =>
    [
      S(k.cylinder(x, y, 7.5, 0, 2.4, P, 28, 0.4), { tone: "mid" }),
      D([0, 1, 2, 3].map((i) => at([x + Math.cos(i * 1.571 + 0.785) * 5.4, y + Math.sin(i * 1.571 + 0.785) * 5.4, 2.4])), { size: 0.4 }),
      S(k.cylinder(x, y, 1.8, 2.4, 44, P, 16), { tone: "mid", crease: "none" }),
      S(k.cylinder(x, y, 3, 20, 2.4, P, 18), { tone: "mid" }),
      S(k.cylinder(x, y, 3.6, 46.4, 7, P, 20, 0.3), { tone: "hi", crease: "lo" }),
      L([48.6, 50.8].map((z) => k.sideArc(x, y, 3.6, z, P, 12)).join(""), { tone: "lo" }),
      `<g data-part="mast-${index}">${S(k.cylinder(x, y, 2.2, 53.4, 2.2, P, 16), { tone: "hi", crease: "none" })}</g>`,
    ].join("");
  const cable = (route) => {
    const points = route.map((point) => at(point));
    return k.wireSvg(points[0], points[points.length - 1], { via: points.slice(1, -1), tone: "lo", size: 0.9 });
  };
  const phone = [
    `<path class="iso-halo" d="${k.haloOf({ x: -9, y: 6, w: 18, d: 26, r: 3 }, 3, 0.1, P)}" style="filter:blur(3px)"/>`,
    S(k.slabOf({ x: -12, y: RAIL.y - 1, w: 24, d: RAIL.d + 2, r: 2 }, 3, 3, P, 3, 0.4), { tone: "mid" }),
    S(k.slabOf({ x: -10, y: 4, w: 20, d: 30, r: 3.5 }, 6, 2.4, P, 4, 0.5), { tone: "hi", crease: "lo", lit: true }),
    L(k.planOutline({ x: -8, y: 6.5, w: 16, d: 25, r: 2 }, 8.4, P, 3), { tone: "lo" }),
    L([12, 16, 20].map((y, i) => k.lineOnTop([-5.5, y], [[3, -1, 4.5][i], y], 8.4, P)).join(""), { tone: "mid", free: true }),
    D([at([0, 33, 8.4])], { size: 0.45 }),
  ].join("");
  const PHONE_AT = [0, 19, 8.4];

  const body = [
    base(PLATE, P, { ruler: { x: -112, y: PLATE.y + PLATE.d - 9, w: 200, d: 5.5, r: 1 } }),
    cable([[MAC.x + 10, MAC.y, 0.4], [MAC.x + 10, -45, 0.4], [MASTS[1][0], -45, 0.4], [MASTS[1][0], -37.5, 0.4]]),
    S(k.slabOf(MAC, 0, MAC_H, P, 4, 0.6), { tone: "mid", inner: L(k.sideSeam(MAC, 4, P, 4), { tone: "faint" }) }),
    D(k.dotGrid(MAC.x + 6, MAC.y + 6, 9, 5, 3.6, MAC_H, P), { size: 0.5, tone: "lo" }),
    D([at([MAC.x + MAC.w, MAC.y + 8, 12])], { size: 0.9, tone: "hi" }),
    cable([[MAC.x + MAC.w, -30, 4], [MASTS[0][0] - 7.5, -30, 0.4]]),
    mast(MASTS[0], 0),
    mast(MASTS[1], 1),
    S(k.slabOf(RAIL, 0, 3, P, 3, 0.5), { tone: "mid" }),
    L(k.lineOnTop([RAIL.x, RAIL.y + RAIL.d / 2], [RAIL.x + RAIL.w, RAIL.y + RAIL.d / 2], 3, P), { tone: "faint" }),
    ...[RAIL.x - 5, RAIL.x + RAIL.w].map((x) => S(k.slabOf({ x, y: RAIL.y - 1, w: 5, d: RAIL.d + 2, r: 1.2 }, 0, 7, P, 3, 0.4), { tone: "mid" })),
    `<g data-part="phone" transform="${k.translateAlong(P, [STOPS[0], 0, 0])}">${phone}</g>`,
    `<g class="iso-wire" data-tone="mid"><path data-part="air" class="iso-line" data-tone="mid" data-dotted="" d=""/></g>`,
    `<g data-part="packets"></g>`,
  ];
  const live = `(svg, say) => {
  const P = ${json(P)}, MASTS = ${json(MASTS)}, TOP = ${MAST_TOP}, STOPS = ${json(STOPS)}, PHONE = ${json(PHONE_AT)};
  const MAC = ${json([MAC.x + MAC.w, -30, 4])};
  const phone = svg.querySelector('[data-part="phone"]');
  const air = svg.querySelector('[data-part="air"]');
  const packets = svg.querySelector('[data-part="packets"]');
  const lamps = [0, 1].map((i) => svg.querySelector('[data-part="mast-' + i + '"] .iso-solid'));
  const HOLD = 2.6, MOVE = 1.8, CYCLE = 2 * (HOLD + MOVE), EVERY = 0.55, FLIGHT = 0.9;
  const ease = (u) => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
  let time = 0, sent = 0, snapshot = 1842;
  const chain = (px, mast) => {
    const [mx, my] = MASTS[mast];
    const pts = mast === 0
      ? [MAC, [mx - 7.5, my, 0.4], [mx, my, 2.4], [mx, my, TOP]]
      : [[${MAC.x + 10}, ${MAC.y}, 0.4], [${MAC.x + 10}, -45, 0.4], [mx, -45, 0.4], [mx, -37.5, 0.4], [mx, my, 2.4], [mx, my, TOP]];
    return [...pts, [px + PHONE[0], PHONE[1], PHONE[2]]].map((p) => iso(p, P));
  };
  const along = (pts, u) => {
    const lens = pts.slice(1).map((p, i) => Math.hypot(p[0] - pts[i][0], p[1] - pts[i][1]));
    let d = u * lens.reduce((a, b) => a + b, 0);
    for (let i = 0; i < lens.length; i++) { if (d <= lens[i]) { const f = d / lens[i]; return [pts[i][0] + (pts[i + 1][0] - pts[i][0]) * f, pts[i][1] + (pts[i + 1][1] - pts[i][1]) * f]; } d -= lens[i]; }
    return pts[pts.length - 1];
  };
  const draw = (px, moving) => {
    const mast = px < (STOPS[0] + STOPS[1]) / 2 ? 0 : 1;
    phone.setAttribute("transform", translateAlong(P, [px, 0, 0]));
    lamps.forEach((lamp, i) => lamp.toggleAttribute("data-lit", i === mast));
    const pts = chain(px, mast), a = pts[pts.length - 2], b = pts[pts.length - 1];
    air.setAttribute("d", "M" + a[0].toFixed(1) + " " + a[1].toFixed(1) + "L" + b[0].toFixed(1) + " " + b[1].toFixed(1));
    let dots = "";
    for (let n = Math.max(0, Math.floor((time - FLIGHT) / EVERY)); n * EVERY <= time; n++) {
      const u = (time - n * EVERY) / FLIGHT;
      if (u < 0 || u > 1) continue;
      const [x, y] = along(pts, u);
      dots += '<circle class="fig-lit" cx="' + x.toFixed(1) + '" cy="' + y.toFixed(1) + '" r="1.2"/>';
    }
    packets.innerHTML = dots;
    const arrived = Math.max(0, Math.floor((time - FLIGHT) / EVERY) + 1);
    if (arrived > sent) { snapshot += arrived - sent; sent = arrived; }
    say((moving ? "switching path" : mast === 0 ? "wi-fi" : "cellular") + " · snapshot " + snapshot.toLocaleString("en"));
  };
  return {
    tick(dt) {
      time += dt;
      const t = time % CYCLE;
      let px, moving = false;
      if (t < HOLD) px = STOPS[0];
      else if (t < HOLD + MOVE) { px = STOPS[0] + (STOPS[1] - STOPS[0]) * ease((t - HOLD) / MOVE); moving = true; }
      else if (t < 2 * HOLD + MOVE) px = STOPS[1];
      else { px = STOPS[1] + (STOPS[0] - STOPS[1]) * ease((t - 2 * HOLD - MOVE) / MOVE); moving = true; }
      draw(px, moving);
    },
    still() { time = 0.45; draw(STOPS[0], false); },
  };
}`;
  return {
    ...frame(
      "roam",
      4,
      "A phone on a rail between a Wi-Fi mast and a cellular mast, both cabled to a Mac. As the phone moves, the active mast changes and complete screen snapshots keep arriving without a gap.",
      body,
    ),
    live,
  };
}

// ---------------------------------------------------------------------------
// Fig 5 — a mailbox on a post. A request arrives, the flag rises ("Needs
// you"), and it lowers again once the request is resolved.
function inbox() {
  const PLATE = { x: -74, y: -46, w: 148, d: 92, r: 6 };
  const BOX = { x: -46, y: -16, w: 88, d: 32, r: 4 };
  const BOX_Z = 40;
  const BOX_H = 26;
  const PIVOT = [22, BOX.y + BOX.d + 0.2, BOX_Z + 11];
  const ARM = 27;
  const P = fit([...k.boxCorners(PLATE, -12, 0), [BOX.x, BOX.y, BOX_Z + BOX_H], [PIVOT[0], PIVOT[1], PIVOT[2] + ARM + 2], [82, 0, 56]], { azimuth: 52 });
  const at = (point) => k.iso(point, P);
  const door = BOX.x + BOX.w;
  const side = BOX.y + BOX.d;

  const post = [
    S(k.cylinder(0, 0, 11, 0, 3, P, 36, 0.5), { tone: "mid" }),
    D([0, 1, 2, 3].map((i) => at([Math.cos(i * 1.571 + 0.785) * 8, Math.sin(i * 1.571 + 0.785) * 8, 3])), { size: 0.5 }),
    S(k.slabOf({ x: -5, y: -5, w: 10, d: 10, r: 1.5 }, 3, 34, P, 2, 0.4), { tone: "mid" }),
    S(k.slabOf({ x: -30, y: -12, w: 60, d: 24, r: 2 }, 37, 3, P, 3, 0.5), { tone: "mid" }),
  ].join("");
  const plate = { y0: BOX.y + 5, y1: BOX.y + BOX.d - 5, z0: BOX_Z + 4, z1: BOX_Z + BOX_H - 4 };
  const ruleRows = [0.32, 0.5, 0.68].map((t, i) => {
    const z = BOX_Z + 10 - 0 + t * 0;
    return k.segment([BOX.x + 8, side, BOX_Z + 8 + i * 3], [BOX.x + [30, 24, 27][i], side, BOX_Z + 8 + i * 3], P);
  });
  const box = S(k.slabOf(BOX, BOX_Z, BOX_H, P, 6, 0.8), {
    tone: "mid",
    inner:
      L(k.sideSeam(BOX, BOX_Z + 4, P, 6), { tone: "faint" }) +
      L(closed([[door, plate.y0, plate.z0], [door, plate.y1, plate.z0], [door, plate.y1, plate.z1], [door, plate.y0, plate.z1]], P), { tone: "lo" }) +
      L(closed([[door, -7, BOX_Z + 14.4], [door, 7, BOX_Z + 14.4], [door, 7, BOX_Z + 15.8], [door, -7, BOX_Z + 15.8]], P), { tone: "hi" }) +
      L(closed([[BOX.x + 6, side, BOX_Z + 5], [BOX.x + 34, side, BOX_Z + 5], [BOX.x + 34, side, BOX_Z + 17], [BOX.x + 6, side, BOX_Z + 17]], P), { tone: "lo" }) +
      L(ruleRows.join(""), { tone: "lo", free: true }) +
      D([plate.y0 + 3, plate.y1 - 3].map((y) => at([door, y, plate.z0 + 1.6])), { size: 0.5, tone: "mid" }),
  });
  const handle = S(k.slabOf({ x: door, y: -2.5, w: 3, d: 5, r: 1 }, BOX_Z + 7, 2.6, P, 2), { tone: "mid" });

  const body = [
    base(PLATE, P, { ruler: { x: -60, y: PLATE.y + PLATE.d - 9, w: 120, d: 5.5, r: 1 } }),
    post,
    box,
    handle,
    `<g data-part="letter"></g>`,
    `<path data-part="flag" class="fig-flag" d=""/>`,
    D([at(PIVOT)], { size: 0.9, tone: "hi" }),
  ];
  const live = `(svg, say) => {
  const P = ${json(P)}, PIVOT = ${json(PIVOT)}, ARM = ${ARM}, DOOR = ${door}, SLOT = ${BOX_Z + 15};
  const flag = svg.querySelector('[data-part="flag"]');
  const letter = svg.querySelector('[data-part="letter"]');
  const ARRIVE = 1.2, WAIT = 2.6, CLEAR = 1.8, CYCLE = ARRIVE + WAIT + CLEAR;
  const ease = (u) => (u <= 0 ? 0 : u >= 1 ? 1 : u * u * (3 - 2 * u));
  const arm = { at: 0, rate: 0 };
  let time = 0;
  const flagAt = (angle) => {
    const ux = -Math.cos(angle), uz = Math.sin(angle), vx = -uz, vz = -ux;
    const pt = (u, v) => iso([PIVOT[0] + ux * u + vx * v, PIVOT[1] + 0.4, PIVOT[2] + uz * u + vz * v], P);
    const poly = (list) => "M" + list.map((p) => p[0].toFixed(1) + " " + p[1].toFixed(1)).join("L") + "Z";
    return poly([pt(-2, -1.6), pt(ARM - 10, -1.6), pt(ARM - 10, -9), pt(ARM, -9), pt(ARM, 1.6), pt(-2, 1.6)]);
  };
  const letterAt = (x, alpha) => {
    if (alpha <= 0) return "";
    const z = SLOT + 0.2, c = (pts) => "M" + pts.map((p) => iso(p, P)).map((p) => p[0].toFixed(1) + " " + p[1].toFixed(1)).join("L") + "Z";
    const face = c([[x, -6, z], [x + 20, -6, z], [x + 20, 6, z], [x, 6, z]]);
    return '<g opacity="' + alpha.toFixed(2) + '"><path class="fig-letter" d="' + face + '"/><path class="iso-line" data-tone="lo" d="' + c([[x + 3, -3, z], [x + 10, 0, z], [x + 3, 3, z]]).slice(0, -1) + '"/></g>';
  };
  const draw = (angle, lx, alpha, waiting) => {
    flag.setAttribute("d", flagAt(angle));
    flag.toggleAttribute("data-up", angle > 0.6);
    letter.innerHTML = letterAt(lx, alpha);
    say(waiting ? "needs you · 1 request" : "resolved · 0 waiting");
  };
  return {
    tick(dt) {
      time += dt;
      const t = time % CYCLE;
      const want = t >= ARRIVE * 0.8 && t < ARRIVE + WAIT ? Math.PI / 2 : 0;
      for (let n = 0; n < 4; n++) { arm.rate += ((want - arm.at) * 90 - arm.rate * 9) * dt / 4; arm.at += arm.rate * dt / 4; }
      const u = Math.min(1, t / ARRIVE), lx = DOOR + 40 - 42 * ease(u);
      const alpha = t < ARRIVE ? Math.min(1, (lx - DOOR) / 8) : 0;
      draw(arm.at, lx, alpha, t >= ARRIVE * 0.8 && t < ARRIVE + WAIT);
    },
    still() { arm.at = Math.PI / 2; draw(arm.at, 0, 0, true); },
  };
}`;
  return {
    ...frame(
      "inbox",
      5,
      "A mailbox on a post with a hinged flag. A request slides into the slot and the lit flag rises to say a program needs you; when the request is resolved the flag comes down.",
      body,
    ),
    live,
  };
}

// ---------------------------------------------------------------------------
// Fig 6 — an event wheel. Pegs on a turntable trip three followers, one per
// lifecycle hook; each follower lifts and lights its lamp when tripped.
function hooks() {
  const PLATE = { x: -78, y: -66, w: 156, d: 132, r: 6 };
  const DISC_R = 40;
  const DISC_Z = 3;
  const DISC_H = 6;
  const TOPZ = DISC_Z + DISC_H;
  const PEG_R = 31;
  const PEGS = [0, 2.44, 4.36];
  const STATIONS = [0, 2.0, 4.1].map((a) => ({ a, x: Math.cos(a) * 52, y: Math.sin(a) * 52 }));
  const P = fit([...k.boxCorners(PLATE, -12, 0), [0, 0, 24]], { azimuth: 40, headroom: 6 });
  const at = (point) => k.iso(point, P);

  const ringAt = (cx, cy, angle, w, d) => {
    const c = Math.cos(angle), s = Math.sin(angle);
    return [[-w / 2, -d / 2], [w / 2, -d / 2], [w / 2, d / 2], [-w / 2, d / 2]].map(([u, v]) => [cx + u * c - v * s, cy + u * s + v * c]);
  };
  const stationBlock = (st, index) =>
    [
      S(k.extrude(ringAt(st.x, st.y, st.a, 14, 14), 0, 13, P, { bevel: 0.5 }), { tone: "mid" }),
      S(k.cylinder(st.x, st.y, 2.2, 13, 4, P, 16), { tone: "mid", crease: "none" }),
      `<g data-part="lamp-${index}">${S(k.cylinder(st.x + Math.cos(st.a + 1.571) * 4, st.y + Math.sin(st.a + 1.571) * 4, 2, 13, 2, P, 18), { tone: "hi", crease: "none" })}</g>`,
    ].join("");
  const stationArm = (st, index) => {
    const mid = (PEG_R - 2 + 55) / 2;
    const len = 55 - (PEG_R - 2);
    const cx = Math.cos(st.a) * mid;
    const cy = Math.sin(st.a) * mid;
    const tip = [Math.cos(st.a) * (PEG_R - 1), Math.sin(st.a) * (PEG_R - 1)];
    return `<g data-part="arm-${index}">${S(k.extrude(ringAt(cx, cy, st.a, len, 4), 17, 2.6, P, { bevel: 0.3 }), { tone: "hi", crease: "lo" })}${S(k.cylinder(tip[0], tip[1], 1.4, 14.2, 2.8, P, 12), { tone: "mid", crease: "none" })}</g>`;
  };
  const depth = (st) => k.depthOf([st.x, st.y, 0], P);
  const order = STATIONS.map((st, index) => ({ st, index })).sort((a, b) => depth(a.st) - depth(b.st));
  const behind = order.filter(({ st }) => depth(st) < k.depthOf([0, 0, 0], P));
  const front = order.filter(({ st }) => depth(st) >= k.depthOf([0, 0, 0], P));

  const body = [
    base(PLATE, P, { label: { x: PLATE.x + 10, y: PLATE.y + PLATE.d - 13, w: 30, d: 8, r: 1 } }),
    ...behind.map(({ st, index }) => stationBlock(st, index)),
    S(k.cylinder(0, 0, 16, 0, DISC_Z, P, 40), { tone: "lo" }),
    S(k.cylinder(0, 0, DISC_R, DISC_Z, DISC_H, P, 72, 0.6), { tone: "mid", crease: "lo" }),
    L(k.ring(0, 0, DISC_R - 2.4, TOPZ, P, 64), { tone: "faint" }),
    `<g data-part="wheel"></g>`,
    ...front.map(({ st, index }) => stationBlock(st, index)),
    ...order.map(({ st, index }) => stationArm(st, index)),
  ];
  const live = `(svg, say) => {
  const P = ${json(P)}, R = ${DISC_R}, TOP = ${TOPZ}, PEG_R = ${PEG_R}, PEGS = ${json(PEGS)}, STATIONS = ${json(STATIONS.map((s) => s.a))};
  const NAMES = ["events.onCommandFinished", "events.onDirectoryChanged", "events.onStatusChanged"];
  const wheel = svg.querySelector('[data-part="wheel"]');
  const arms = STATIONS.map((_, i) => svg.querySelector('[data-part="arm-' + i + '"]'));
  const lamps = STATIONS.map((_, i) => svg.querySelector('[data-part="lamp-' + i + '"] .iso-solid'));
  const lift = STATIONS.map(() => ({ at: 0, rate: 0 }));
  const glow = STATIONS.map(() => 0);
  const solid = (paths, tone, lit) => {
    let s = '<g class="iso-solid"' + (lit ? " data-lit" : "") + '><path class="iso-fill" d="' + paths.fill + '"/>';
    paths.shades.forEach((d, i) => { if (d) s += '<path class="iso-shade" data-shade="' + i + '" d="' + d + '"/>'; });
    return s + '<path class="iso-top" d="' + paths.top + '"/><path class="iso-line iso-edge" data-tone="' + tone + '" d="' + paths.outline + '"/></g>';
  };
  let angle = 0, last = 0, calls = 0;
  const near = (a, b) => { const d = Math.atan2(Math.sin(a - b), Math.cos(a - b)); return Math.abs(d); };
  const draw = () => {
    const ticks = radialTicks(0, 0, R - 2.4, 48, 4, TOP, [1.1, 2.4], P, angle + Math.PI / 2);
    let html = '<path class="iso-line" data-tone="lo" d="' + ticks.minor + '"/><path class="iso-line" data-tone="mid" d="' + ticks.major + '"/>';
    const pegs = PEGS.map((p) => p + angle).map((a) => [Math.cos(a) * PEG_R, Math.sin(a) * PEG_R]).sort((a, b) => depthOf([a[0], a[1], 0], P) - depthOf([b[0], b[1], 0], P));
    pegs.forEach(([x, y]) => { html += solid(cylinder(x, y, 2.4, TOP, 4.2, P, 16), "hi", false); });
    html += solid(cylinder(0, 0, 5, TOP, 3, P, 24), "mid", false);
    wheel.innerHTML = html;
    arms.forEach((arm, i) => arm.setAttribute("transform", translateAlong(P, [0, 0, lift[i].at])));
    lamps.forEach((lamp, i) => lamp.toggleAttribute("data-lit", i === last && glow[i] > 0));
    say(NAMES[last] + " · " + calls + " calls");
  };
  const step = (dt, calm) => {
    angle += dt * 1.3;
    STATIONS.forEach((s, i) => {
      const hit = PEGS.some((p) => near(p + angle, s) < 0.16);
      if (hit && lift[i].at < 0.5 && glow[i] <= 0) { last = i; calls++; }
      glow[i] = hit ? 0.9 : Math.max(0, glow[i] - dt);
      const want = hit ? 3.2 : 0, sp = lift[i];
      if (calm) { sp.at = want; return; }
      for (let n = 0; n < 4; n++) { sp.rate += ((want - sp.at) * 400 - sp.rate * 22) * dt / 4; sp.at += sp.rate * dt / 4; }
    });
    draw();
  };
  return {
    tick(dt) { step(dt, false); },
    still() { angle = STATIONS[0] - PEGS[0]; calls = 3; step(0, true); },
  };
}`;
  return {
    ...frame(
      "hooks",
      6,
      "An event wheel: pegs on a turntable trip three followers, one each for command finished, directory changed and status changed. A tripped follower lifts and lights its lamp, the way a script's hook runs.",
      body,
    ),
    live,
  };
}

// ---------------------------------------------------------------------------
const figures = [speed(), render(), mux(), roam(), inbox(), hooks()];

// Anatomy's styles, minus its page and card chrome, retoned to the site palette.
const KIT_CSS = k.ISO_CSS.replace(/\.iso\{[^}]*\}/, "")
  .replace(/\.iso\[data-theme="light"\]\{[^}]*\}/, "")
  .replace(/\.iso-(figure|plate|legend|keys|key|swatch)[^{]*\{[^}]*\}/g, "")
  .replace(/@media \(max-width:560px\)\{[^}]*\}[^}]*\}/, "");
const CSS = `
      .iso {
        --anatomy-paper: var(--surface); --anatomy-face: #fffdfa; --anatomy-top: #fffefb;
        --anatomy-shade-0: #e2d6c9; --anatomy-shade-1: #e9dfd4; --anatomy-shade-2: #f0e8df; --anatomy-shade-3: #f6f0e9;
        --anatomy-lit-top: #fff3d4; --anatomy-lit-shade: #f6dfa6;
        --anatomy-hi: #2a211e; --anatomy-mid: #8e7f73; --anatomy-lo: #bfb1a4; --anatomy-faint: #ddd2c6; --anatomy-lit: #8a5a00;
        --anatomy-halo: #8a7660; --anatomy-halo-opacity: 0.3; --anatomy-dot: #3a2f2a;
        --anatomy-red: #d9443c; --anatomy-green: #1f7a32; --anatomy-blue: #3e63dd;
        --anatomy-weight: 0.6px; --anatomy-mono: var(--mono);
        --fig-lit-fill: #febc2e;
      }
      [data-theme="dark"] .iso {
        --anatomy-face: #261e1b; --anatomy-top: #2b221f;
        --anatomy-shade-0: #150f0e; --anatomy-shade-1: #191311; --anatomy-shade-2: #1e1715; --anatomy-shade-3: #231b19;
        --anatomy-lit-top: #3d2e12; --anatomy-lit-shade: #2e230e;
        --anatomy-hi: #e6ddd4; --anatomy-mid: #8a7a6f; --anatomy-lo: #54463e; --anatomy-faint: #382d29; --anatomy-lit: #febc2e;
        --anatomy-halo: #050302; --anatomy-halo-opacity: 0.85; --anatomy-dot: #efe8e1;
        --fig-lit-fill: #febc2e;
      }
      ${KIT_CSS}
      .iso .fig-lit { fill: var(--fig-lit-fill); stroke: none; }
      .iso .iso-dots .fig-lit { opacity: 1; }
      .iso .fig-flag { fill: var(--anatomy-shade-2); stroke: var(--anatomy-mid); stroke-width: var(--anatomy-weight); stroke-linejoin: round; vector-effect: non-scaling-stroke; transition: fill 0.3s; }
      .iso .fig-flag[data-up] { fill: var(--fig-lit-fill); stroke: var(--anatomy-lit); }
      .iso .fig-letter { fill: var(--anatomy-face); stroke: var(--anatomy-hi); stroke-width: var(--anatomy-weight); stroke-linejoin: round; vector-effect: non-scaling-stroke; }
      .feature-figure .feature-icon {
        width: calc(100% + 16px);
        height: auto;
        margin: -12px -8px 16px;
      }
      .feature-figure .feature-icon .iso-svg { width: 100%; height: auto; aspect-ratio: ${W} / ${H}; }
      .fig-meta {
        display: flex;
        justify-content: space-between;
        gap: 12px;
        margin: 4px 8px 0;
        color: var(--subtle);
        font: 10px/1.4 var(--mono);
        letter-spacing: 0.04em;
        font-variant-numeric: tabular-nums;
        white-space: nowrap;
      }
      @media (max-width: 760px) {
        .feature.feature-figure { display: flex; }
        .feature-figure .feature-icon { grid-row: auto; width: calc(100% + 12px); height: auto; margin: -6px -6px 12px; }
      }`;

const SCRIPT = `
      (() => {
        "use strict";
${k.ISO_CSS ? readFileSync(join(HERE, "kit", "iso-kit.mjs"), "utf8").replace(/^export /gm, "").replace(/const ISO_CSS = \`[\s\S]*?\`;\n?/, "").replace(/<\/script/gi, "<\\/script") : ""}
        const FIGS = {
${figures.map((f) => `          ${f.name}: ${f.live},`).join("\n")}
        };
        const still = matchMedia("(prefers-reduced-motion: reduce)");
        document.querySelectorAll("[data-figure]").forEach((stage) => {
          const make = FIGS[stage.dataset.figure];
          const svg = stage.querySelector("svg");
          const readout = stage.querySelector("[data-readout]");
          if (!make || !svg) return;
          const say = (text) => { if (readout && readout.textContent !== text) readout.textContent = text; };
          const fig = make(svg, say);
          let frame = 0, last = 0, visible = false;
          const tick = (now) => {
            const dt = last ? Math.min((now - last) / 1000, 1 / 30) : 1 / 60;
            last = now;
            fig.tick(dt);
            frame = visible && !still.matches ? requestAnimationFrame(tick) : 0;
          };
          const run = () => {
            if (still.matches) { if (frame) cancelAnimationFrame(frame); frame = 0; fig.still(); return; }
            if (!frame && visible) { last = 0; frame = requestAnimationFrame(tick); }
          };
          fig.still();
          new IntersectionObserver((entries) => { visible = entries[entries.length - 1].isIntersecting; run(); }, { rootMargin: "120px 0px" }).observe(stage);
          if (still.addEventListener) still.addEventListener("change", run);
        });
      })();`;

let page = readFileSync(PAGE, "utf8");
const swap = (open, close, content) => {
  const from = page.indexOf(open);
  const to = page.indexOf(close);
  if (from < 0 || to < from) throw new Error(`missing marker ${open}`);
  page = page.slice(0, from + open.length) + content + page.slice(to);
};
for (const figure of figures) swap(`<!-- figure:${figure.name} -->`, `<!-- /figure:${figure.name} -->`, figure.html);
swap("/* figures:css */", "/* /figures:css */", CSS + "\n      ");
swap("/* figures:js */", "/* /figures:js */", SCRIPT + "\n      ");
writeFileSync(PAGE, page);
console.log(`wrote ${figures.length} figures into ${PAGE} (${(page.length / 1024).toFixed(0)} KiB)`);
