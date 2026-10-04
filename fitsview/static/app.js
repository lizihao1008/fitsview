"use strict";

const $ = (sel, root = document) => root.querySelector(sel);
const PAGE = 100;

const S = {
  files: [],          // opened files: {path, name, size, hdus}
  current: null,      // active file
  hdu: null,          // selected HDU summary object
  tab: "header",
  dir: null,
  tableInfo: {},      // "path#hdu" -> promise of column info
  page: 0,
  plot: {},           // per-HDU plot settings
  image: { stretch: "zscale", scale: "linear", cmap: "gray", slice: 0 },
};

// ------------------------------------------------------------ helpers

async function api(url, params = {}) {
  const r = await fetch(`${url}?${new URLSearchParams(params)}`);
  const j = await r.json();
  if (!r.ok) throw new Error(j.error || r.statusText);
  return j;
}

function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k === "class") el.className = v;
    else if (k === "html") el.innerHTML = v;
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) {
    if (c == null || c === false) continue;
    el.append(c instanceof Node ? c : document.createTextNode(String(c)));
  }
  return el;
}

function toast(msg, isErr = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast" + (isErr ? " err" : "");
  t.hidden = false;
  clearTimeout(toast._t);
  toast._t = setTimeout(() => (t.hidden = true), isErr ? 6000 : 2500);
}

function fmtSize(n) {
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
  return `${n.toFixed(i ? 1 : 0)} ${u[i]}`;
}

function fmtNum(v) {
  if (typeof v !== "number") return String(v);
  if (Number.isInteger(v) && Math.abs(v) < 1e15) return String(v);
  const a = Math.abs(v);
  if (a !== 0 && (a < 1e-3 || a >= 1e7)) return v.toExponential(5);
  return String(parseFloat(v.toPrecision(8)));
}

function fmtCell(v) {
  if (v === null || v === undefined) return h("span", { class: "nul" }, "—");
  if (typeof v === "boolean") return v ? "T" : "F";
  if (Array.isArray(v)) return "[" + v.map(fmtNum).join(", ") + "]";
  return fmtNum(v);
}

const KIND_LABEL = {
  empty: "header only", image: "image", cube: "cube", spectrum: "1-D spectrum",
  spectra: "spectra (rows)", table: "table", "spectrum-table": "spectrum table",
  events: "event list", groups: "random groups",
};
const isTable = (k) => ["table", "spectrum-table", "events"].includes(k);
const isImage = (k) => ["image", "cube", "spectrum", "spectra"].includes(k);
const canDs9 = (k) => ["image", "cube", "spectra", "events"].includes(k);
const canPlot = (k) => isTable(k) || ["spectrum", "spectra", "image"].includes(k);

function cssVar(name) {
  return getComputedStyle(document.documentElement).getPropertyValue(name).trim();
}

// ------------------------------------------------------------ file browser

async function browse(dir) {
  try {
    const params = { all: $("#show-all").checked ? 1 : 0 };
    if (dir) params.dir = dir;
    const res = await api("/api/ls", params);
    S.dir = res;
    $("#dir-path").textContent = res.dir;
    $("#dir-path").title = res.dir;
    const list = $("#dir-list");
    list.replaceChildren(
      ...res.dirs.map((d) => h("li", { onclick: () => browse(`${res.dir}/${d}`) },
        h("span", { class: "ico" }, "▸"), h("span", { class: "nm" }, d))),
      ...res.files.map((f) => {
        const full = `${res.dir}/${f.name}`;
        return h("li", { class: S.current?.path === full ? "active" : "", "data-path": full, onclick: () => openFile(full) },
          h("span", { class: "ico" }, "◇"), h("span", { class: "nm", title: f.name }, f.name),
          h("span", { class: "sz" }, fmtSize(f.size)));
      }),
    );
    if (!res.dirs.length && !res.files.length) list.append(h("li", { class: "muted" }, "(no FITS files here)"));
  } catch (e) {
    toast(e.message, true);
  }
}

function markActiveInBrowser() {
  document.querySelectorAll("#dir-list li[data-path]").forEach((li) =>
    li.classList.toggle("active", li.dataset.path === S.current?.path));
}

// ------------------------------------------------------------ files & HDUs

async function openFile(path) {
  path = path.trim();
  if (!path) return;
  try {
    const existing = S.files.find((f) => f.path === path);
    const info = await api("/api/open", { path });
    for (const k of Object.keys(S.tableInfo)) if (k.startsWith(`${info.path}#`)) delete S.tableInfo[k];
    if (existing) Object.assign(existing, info); else S.files.push(info);
    activateFile(info.path);
  } catch (e) {
    toast(e.message, true);
  }
}

function activateFile(path) {
  S.current = S.files.find((f) => f.path === path) || null;
  renderFileTabs();
  markActiveInBrowser();
  $("#welcome").hidden = !!S.current;
  $("#file-view").hidden = !S.current;
  if (!S.current) return;
  $("#path-input").value = S.current.path;
  $("#file-meta").replaceChildren(
    h("span", { class: "fname" }, S.current.name),
    h("span", { class: "muted" }, `${S.current.hdus.length} HDU${S.current.hdus.length > 1 ? "s" : ""} · ${fmtSize(S.current.size)}`),
    h("span", { class: "fpath" }, S.current.path),
  );
  renderHduTable();
  // default selection: first HDU with data, else primary
  const first = S.current.hdus.find((x) => x.kind !== "empty") || S.current.hdus[0];
  selectHdu(first.index);
}

function closeFile(path) {
  S.files = S.files.filter((f) => f.path !== path);
  if (S.current?.path === path) activateFile(S.files.at(-1)?.path);
  else renderFileTabs();
}

function renderFileTabs() {
  $("#file-tabs").replaceChildren(...S.files.map((f) =>
    h("div", { class: "ftab" + (f === S.current ? " active" : ""), title: f.path, onclick: () => activateFile(f.path) },
      f.name,
      h("button", { class: "x", title: "Close", onclick: (ev) => { ev.stopPropagation(); closeFile(f.path); } }, "×"))));
}

function renderHduTable() {
  $("#hdu-body").replaceChildren(...S.current.hdus.map((x) => {
    const actions = h("td", { class: "actions" });
    if (canDs9(x.kind)) {
      actions.append(h("button", { class: "btn small", title: "Open this HDU in SAOImage DS9",
        onclick: (ev) => { ev.stopPropagation(); sendToDs9(x.index); } }, "DS9 ↗"));
    }
    return h("tr", { "data-index": x.index, onclick: () => selectHdu(x.index) },
      h("td", { class: "mono" }, x.index),
      h("td", {}, h("b", {}, x.name || "—"), x.ver > 1 ? h("span", { class: "muted" }, ` v${x.ver}`) : null,
        x.object ? h("div", { class: "muted small" }, x.object) : null),
      h("td", { class: "mono c-opt" }, x.hdutype),
      h("td", {}, h("span", { class: `badge k-${x.kind}` }, KIND_LABEL[x.kind] || x.kind)),
      h("td", { class: "mono" }, x.dims, x.bitpix ? h("div", { class: "muted small" }, `BITPIX ${x.bitpix}`) : null),
      h("td", { class: "mono muted c-opt" }, x.ncards),
      actions);
  }));
}

function selectHdu(index, tab) {
  S.hdu = S.current.hdus[index];
  S.page = 0;
  S.image.slice = 0;
  document.querySelectorAll("#hdu-body tr").forEach((tr) =>
    tr.classList.toggle("sel", +tr.dataset.index === index));
  const k = S.hdu.kind;
  $("#detail-title").replaceChildren(
    `HDU ${index} · ${S.hdu.name || "—"} `,
    h("span", { class: "muted" }, `${S.hdu.hdutype} · ${S.hdu.dims}`));
  const tabs = $("#tabs");
  tabs.querySelector('[data-tab="data"]').disabled = k === "empty" || k === "groups";
  tabs.querySelector('[data-tab="plot"]').disabled = !canPlot(k);
  if (!tab || tabs.querySelector(`[data-tab="${tab}"]`).disabled) {
    tab = { empty: "header", groups: "header", spectrum: "plot", "spectrum-table": "plot", spectra: "plot" }[k] || "data";
  }
  setTab(tab);
}

function setTab(tab) {
  S.tab = tab;
  document.querySelectorAll("#tabs button").forEach((b) => b.classList.toggle("active", b.dataset.tab === tab));
  // fresh container per render: a slow response for a previously selected
  // HDU/tab then writes into a detached node instead of the visible pane
  const pane = h("div", {}, h("div", { class: "empty-note" }, "Loading…"));
  $("#pane").replaceChildren(pane);
  const run = { header: showHeader, data: showData, plot: showPlot }[tab];
  run(pane).catch((e) => pane.replaceChildren(h("div", { class: "error" }, e.message)));
}

async function sendToDs9(index) {
  try {
    const r = await fetch("/api/ds9", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ path: S.current.path, hdu: index }),
    });
    const j = await r.json();
    if (!r.ok) throw new Error(j.error);
    toast(`HDU ${index}: ${j.message}`);
  } catch (e) {
    toast(e.message, true);
  }
}

// ------------------------------------------------------------ header tab

async function showHeader(pane) {
  const { cards, text } = await api("/api/header", { path: S.current.path, hdu: S.hdu.index });
  let raw = false;
  const filter = h("input", { type: "text", placeholder: "Filter keywords / values…", style: "width:260px" });
  const body = h("div", { class: "scroll" });
  const count = h("span", { class: "muted small" });

  const draw = () => {
    if (raw) { body.replaceChildren(h("pre", { class: "raw" }, text)); count.textContent = ""; return; }
    const q = filter.value.trim().toLowerCase();
    const rows = cards.filter((c) => !q || `${c.key} ${c.value} ${c.comment}`.toLowerCase().includes(q));
    count.textContent = `${rows.length} / ${cards.length} cards`;
    body.replaceChildren(h("table", { class: "cards" }, rows.map((c) =>
      h("tr", { class: ["HISTORY", "COMMENT", ""].includes(c.key) ? "hist" : "" },
        h("td", { class: "key" }, c.key),
        h("td", { class: "val" }, typeof c.value === "string" && !["HISTORY", "COMMENT", ""].includes(c.key) ? `'${c.value}'` : String(c.value)),
        h("td", { class: "com" }, c.comment)))));
  };
  filter.addEventListener("input", draw);
  const rawBtn = h("button", { class: "btn small", onclick: () => { raw = !raw; rawBtn.textContent = raw ? "Table view" : "Raw 80-col"; draw(); } }, "Raw 80-col");
  const copyBtn = h("button", { class: "btn small", onclick: () => navigator.clipboard.writeText(text).then(() => toast("Header copied")) }, "Copy");
  pane.replaceChildren(h("div", { class: "toolbar" }, filter, count, h("span", { class: "spacer" }), rawBtn, copyBtn), body);
  draw();
  filter.focus();
}

// ------------------------------------------------------------ data tab

async function showData(pane) {
  if (isTable(S.hdu.kind)) return showTable(pane);
  if (isImage(S.hdu.kind)) return showImage(pane);
  pane.replaceChildren(h("div", { class: "empty-note" }, "No data in this HDU."));
}

async function loadTableInfo() {
  const key = `${S.current.path}#${S.hdu.index}`;
  if (!S.tableInfo[key]) {
    S.tableInfo[key] = api("/api/table/info", { path: S.current.path, hdu: S.hdu.index })
      .catch((e) => { delete S.tableInfo[key]; throw e; });
  }
  return S.tableInfo[key];
}

async function showTable(pane) {
  const info = await loadTableInfo();
  let view = "rows";
  const content = h("div");
  const pager = h("div", { class: "pager" });
  const viewBtn = h("button", { class: "btn small" }, "Column info");
  viewBtn.onclick = () => { view = view === "rows" ? "cols" : "rows"; viewBtn.textContent = view === "rows" ? "Column info" : "Rows"; draw(); };
  pane.replaceChildren(h("div", { class: "toolbar" }, pager, h("span", { class: "spacer" }),
    h("span", { class: "muted small" }, `${info.columns.length} columns · ${info.nrows.toLocaleString()} rows`), viewBtn), content);

  const pages = Math.max(1, Math.ceil(info.nrows / PAGE));
  const go = (p) => { S.page = Math.max(0, Math.min(pages - 1, p)); draw(); };
  const jump = h("input", { type: "number", min: 0, max: info.nrows - 1, placeholder: "row #" });
  jump.addEventListener("change", () => go(Math.floor(+jump.value / PAGE)));
  const label = h("span", { class: "muted small" });
  pager.append(
    h("button", { class: "btn small", onclick: () => go(0) }, "⇤"),
    h("button", { class: "btn small", onclick: () => go(S.page - 1) }, "‹"),
    label,
    h("button", { class: "btn small", onclick: () => go(S.page + 1) }, "›"),
    h("button", { class: "btn small", onclick: () => go(pages - 1) }, "⇥"),
    jump);

  async function draw() {
    pager.style.visibility = view === "rows" ? "visible" : "hidden";
    if (view === "cols") {
      content.replaceChildren(h("div", { class: "grid-wrap" }, h("table", { class: "colinfo" },
        h("thead", {}, h("tr", {}, ["#", "Name", "Format", "Unit", "Dim / shape", "TNULL", "TDISP"].map((t) => h("th", {}, t)))),
        h("tbody", {}, info.columns.map((c, i) => h("tr", {},
          h("td", {}, i + 1), h("td", {}, c.name), h("td", {}, c.format), h("td", {}, c.unit),
          h("td", {}, c.vla ? "variable" : c.shape.length ? c.shape.join("×") : (c.dim || "scalar")),
          h("td", {}, c.null ?? ""), h("td", {}, c.disp)))))));
      return;
    }
    const start = S.page * PAGE;
    label.textContent = `rows ${start}–${Math.min(start + PAGE, info.nrows) - 1} of ${info.nrows.toLocaleString()}`;
    const res = await api("/api/table/rows", { path: S.current.path, hdu: S.hdu.index, start, count: PAGE });
    const head = h("tr", {}, h("th", {}, "row"), info.columns.map((c) =>
      h("th", c.numeric && !c.vector
        ? { class: "plotcol", title: `Plot ${c.name} vs row`, onclick: () => plotFrom({ y: c.name }) }
        : {}, c.name, h("span", { class: "unit" }, c.unit || " "))));
    const rows = res.rows.map((r, i) => h("tr", {}, h("td", { class: "rn" }, res.start + i), r.map((v, j) => {
      const col = info.columns[j];
      if (v && typeof v === "object" && v.array) {
        const txt = `[${v.shape.join("×")}] ${v.head.map(fmtNum).join(", ")}, …`;
        return h("td", { class: "str" }, col.numeric
          ? h("span", { class: "arr", title: "Plot this array", onclick: () => plotFrom({ y: col.name, row: res.start + i }) }, txt)
          : txt);
      }
      if (Array.isArray(v) && col.numeric && col.vector && v.length > 1) {
        return h("td", { class: "str" }, h("span", { class: "arr", onclick: () => plotFrom({ y: col.name, row: res.start + i }) }, fmtCell(v)));
      }
      return h("td", { class: typeof v === "string" ? "str" : "" }, fmtCell(v));
    })));
    content.replaceChildren(h("div", { class: "grid-wrap" }, h("table", { class: "grid" }, h("thead", {}, head), h("tbody", {}, rows))));
  }
  draw();
}

async function showImage(pane) {
  const p = { path: S.current.path, hdu: S.hdu.index };
  const stats = await api("/api/image/stats", { ...p, slice: S.image.slice });
  const img = h("img", { alt: "quick-look" });
  const loading = h("div", { class: "loading" }, "rendering…");
  const box = h("div", { class: "image-box", title: "Click to toggle 1:1 / fit" }, loading, img);
  box.onclick = () => box.classList.toggle("full");

  const refresh = () => {
    const url = `/api/image/png?${new URLSearchParams({ ...p, ...S.image, max: 2048 })}`;
    if (img.getAttribute("src") === url) return; // same image: no load event would fire
    loading.hidden = false;
    img.src = url;
  };
  img.onload = () => (loading.hidden = true);
  img.onerror = () => (loading.textContent = "failed to render");

  const sel = (key, opts) => {
    const s = h("select", { onchange: () => { S.image[key] = s.value; refresh(); } },
      opts.map(([v, t]) => h("option", { value: v, selected: S.image[key] === v }, t)));
    return s;
  };
  const tools = h("div", { class: "toolbar" },
    h("label", {}, "limits", sel("stretch", [["zscale", "zscale"], ["minmax", "min/max"], ["p99.5", "99.5%"], ["p99", "99%"], ["p95", "95%"]])),
    h("label", {}, "scale", sel("scale", [["linear", "linear"], ["sqrt", "sqrt"], ["log", "log"], ["asinh", "asinh"]])),
    h("label", {}, "colormap", sel("cmap", [["gray", "gray"], ["heat", "heat"], ["viridis", "viridis"], ["cool", "cool"]])));

  const statsTable = h("table", { class: "stats" });
  const drawStats = (s) => statsTable.replaceChildren(...[
    ["shape", s.shape.join(" × ")], ["dtype", s.dtype], ["BUNIT", s.bunit || "—"],
    ["min", s.min], ["max", s.max], ["mean", s.mean], ["median", s.median], ["std", s.std],
    ["NaN fraction", s.nan_fraction],
  ].map(([k, v]) => h("tr", {}, h("td", {}, k), h("td", {}, v === undefined ? "—" : fmtNum(v)))));
  drawStats(stats);

  if (stats.nslices > 1) {
    const out = h("span", { class: "mono small" }, `${S.image.slice} / ${stats.nslices - 1}`);
    const range = h("input", { type: "range", min: 0, max: stats.nslices - 1, value: S.image.slice });
    let t;
    range.addEventListener("input", () => {
      S.image.slice = +range.value;
      out.textContent = `${S.image.slice} / ${stats.nslices - 1}`;
      clearTimeout(t);
      t = setTimeout(async () => { refresh(); drawStats(await api("/api/image/stats", { ...p, slice: S.image.slice })); }, 120);
    });
    tools.append(h("label", { class: "slice-row" }, "slice", range, out));
  }
  tools.append(h("span", { class: "spacer" }));
  if (canDs9(S.hdu.kind)) tools.append(h("button", { class: "btn primary", onclick: () => sendToDs9(S.hdu.index) }, "Open in DS9 ↗"));

  pane.replaceChildren(tools, h("div", { class: "image-layout" }, box, h("div", {}, statsTable,
    h("p", { class: "muted small" }, "Quick-look is block-averaged for display. Use DS9 for full-resolution inspection, regions and WCS."))));
  refresh();
}

// ------------------------------------------------------------ plot tab

function plotFrom(opts) {
  S.plot[`${S.current.path}#${S.hdu.index}`] = { ...currentPlotSettings(), ...opts, fromUser: true };
  setTab("plot");
}

function currentPlotSettings() {
  return S.plot[`${S.current.path}#${S.hdu.index}`] || {};
}

async function showPlot(pane) {
  if (isTable(S.hdu.kind)) return showTablePlot(pane);
  return showImagePlot(pane);
}

async function showTablePlot(pane) {
  const info = await loadTableInfo();
  const key = `${S.current.path}#${S.hdu.index}`;
  const cols = info.columns.filter((c) => c.numeric);
  const byName = Object.fromEntries(info.columns.map((c) => [c.name, c]));
  if (!cols.length) { pane.replaceChildren(h("div", { class: "empty-note" }, "No numeric columns to plot.")); return; }

  // defaults: spectral guess, event X/Y, else first numeric column
  let st = S.plot[key];
  if (!st) {
    const g = info.guess;
    if (S.hdu.kind === "events") st = { x: "X", y: "Y", mode: "markers" };
    else if (g.y) st = { x: g.x || "__index__", y: g.y, err: g.err || "" };
    else st = { x: "__index__", y: cols[0].name };
  }
  st = { x: "__index__", err: "", row: 0, mode: "lines", logx: false, logy: false, ...st };
  // array cell clicked: pair with a vector x column of the same length if one looks spectral
  if (st.fromUser && st.y && byName[st.y]?.vector) {
    const yShape = JSON.stringify(byName[st.y].shape);
    const xVec = info.columns.find((c) => c.vector && c.name !== st.y && JSON.stringify(c.shape) === yShape && /^(wave|wavelength|lambda|loglam|freq|energy)/i.test(c.name));
    if (!byName[st.x]?.vector) st.x = xVec ? xVec.name : "__index__";
  } else if (st.fromUser && byName[st.x]?.vector) {
    st.x = "__index__";
  }
  delete st.fromUser;
  S.plot[key] = st;

  const opt = (c) => h("option", { value: c.name }, c.name + (c.unit ? ` [${c.unit}]` : "") + (c.vector ? (c.vla ? " (var)" : ` [${c.shape.join("×")}]`) : ""));
  const xs = h("select", {}, h("option", { value: "__index__" }, "(row / element index)"), cols.map(opt));
  const ys = h("select", {}, cols.map(opt));
  const es = h("select", {}, h("option", { value: "" }, "(none)"), cols.map(opt));
  const rowIn = h("input", { type: "number", min: 0, max: info.nrows - 1, style: "width:90px" });
  const mode = h("select", {}, ["lines", "markers", "lines+markers", "steps"].map((m) => h("option", { value: m }, m)));
  const logx = h("input", { type: "checkbox" });
  const logy = h("input", { type: "checkbox" });
  xs.value = st.x; ys.value = st.y; es.value = st.err; rowIn.value = st.row; mode.value = st.mode;
  logx.checked = st.logx; logy.checked = st.logy;
  const rowLabel = h("label", {}, "row", rowIn);
  const status = h("span", { class: "muted small" });
  const plotDiv = h("div", { id: "plot" });

  const update = async () => {
    Object.assign(st, { x: xs.value, y: ys.value, err: es.value, row: +rowIn.value || 0, mode: mode.value, logx: logx.checked, logy: logy.checked });
    const vectorSel = [st.x, st.y, st.err].some((n) => byName[n]?.vector);
    rowLabel.hidden = !vectorSel;
    status.textContent = "loading…";
    try {
      const params = { path: S.current.path, hdu: S.hdu.index, x: st.x, y: st.y, err: st.err };
      if (vectorSel) params.row = st.row;
      const d = await api("/api/table/plot", params);
      status.textContent = `${d.y.length.toLocaleString()} points` + (d.step > 1 ? ` (every ${d.step}th shown)` : "");
      drawPlot(plotDiv, d, st);
    } catch (e) {
      status.textContent = "";
      Plotly.purge(plotDiv);
      plotDiv.replaceChildren(h("div", { class: "error" }, e.message));
    }
  };
  [xs, ys, es, rowIn, mode, logx, logy].forEach((el) => el.addEventListener("change", update));

  pane.replaceChildren(h("div", { class: "toolbar" },
    h("label", {}, "X", xs), h("label", {}, "Y", ys), h("label", {}, "error", es), rowLabel,
    h("label", {}, "style", mode), h("label", {}, logx, "log x"), h("label", {}, logy, "log y"),
    h("span", { class: "spacer" }), status), plotDiv);
  update();
}

async function showImagePlot(pane) {
  const p = { path: S.current.path, hdu: S.hdu.index };
  const st = { row: 0, mode: "lines", logx: false, logy: false };
  const plotDiv = h("div", { id: "plot" });
  const status = h("span", { class: "muted small" });
  const toolbar = h("div", { class: "toolbar" });
  const rowIn = h("input", { type: "number", min: 0, value: 0, style: "width:90px" });
  const logy = h("input", { type: "checkbox" });
  const update = async () => {
    st.row = +rowIn.value || 0;
    st.logy = logy.checked;
    const d = await api("/api/image/profile", { ...p, row: st.row });
    rowIn.max = d.nrows - 1;
    status.textContent = `${d.y.length.toLocaleString()} pixels` + (d.step > 1 ? ` (every ${d.step}th shown)` : "");
    drawPlot(plotDiv, d, st);
  };
  rowIn.addEventListener("change", update);
  logy.addEventListener("change", update);
  const isMulti = S.hdu.kind !== "spectrum";
  toolbar.append(
    isMulti ? h("label", {}, S.hdu.kind === "spectra" ? "spectrum row" : "image row (y)", rowIn) : null,
    h("label", {}, logy, "log y"),
    h("span", { class: "spacer" }), status);
  pane.replaceChildren(toolbar, plotDiv);
  await update();
}

function axisTitle(label, unit) {
  return unit ? `${label} [${unit}]` : label;
}

function drawPlot(div, d, st) {
  div.replaceChildren();
  const text = cssVar("--text"), muted = cssVar("--muted"), grid = cssVar("--border"), accent = cssVar("--accent");
  const n = d.y.length;
  const gl = n > 5000;
  const traces = [];
  if (d.err && st.mode !== "markers") {
    // shaded ±1σ band reads better than error bars for dense spectra
    const lo = d.y.map((y, i) => (y == null || d.err[i] == null ? null : y - d.err[i]));
    const hi = d.y.map((y, i) => (y == null || d.err[i] == null ? null : y + d.err[i]));
    traces.push({ x: d.x, y: lo, type: gl ? "scattergl" : "scatter", mode: "lines", line: { width: 0 }, hoverinfo: "skip", showlegend: false });
    traces.push({ x: d.x, y: hi, type: gl ? "scattergl" : "scatter", mode: "lines", line: { width: 0 }, fill: "tonexty",
      fillcolor: "rgba(127,127,127,0.25)", hoverinfo: "skip", name: "±1σ" });
  }
  const steps = st.mode === "steps";
  traces.push({
    x: d.x, y: d.y, type: gl ? "scattergl" : "scatter",
    mode: steps ? "lines" : st.mode,
    line: { width: 1.2, color: accent, shape: steps ? "hvh" : "linear" },
    marker: { size: n > 20000 ? 2 : 4, color: accent },
    error_y: d.err && st.mode === "markers" ? { type: "data", array: d.err, visible: true, thickness: 0.8, width: 0, color: muted } : undefined,
    name: d.ylabel,
  });
  Plotly.newPlot(div, traces, {
    margin: { l: 70, r: 20, t: 10, b: 50 },
    paper_bgcolor: "rgba(0,0,0,0)", plot_bgcolor: "rgba(0,0,0,0)",
    font: { color: text, size: 12 },
    showlegend: false,
    hovermode: "closest",
    xaxis: { title: axisTitle(d.xlabel, d.xunit), type: st.logx ? "log" : "linear", gridcolor: grid, zerolinecolor: grid, linecolor: muted, exponentformat: "power" },
    yaxis: { title: axisTitle(d.ylabel, d.yunit), type: st.logy ? "log" : "linear", gridcolor: grid, zerolinecolor: grid, linecolor: muted, exponentformat: "power" },
  }, { responsive: true, displaylogo: false, modeBarButtonsToRemove: ["lasso2d", "select2d"] });
}

// ------------------------------------------------------------ wiring

$("#open-form").addEventListener("submit", (e) => { e.preventDefault(); openFile($("#path-input").value); });
$("#dir-up").addEventListener("click", () => S.dir && browse(S.dir.parent));
$("#show-all").addEventListener("change", () => browse(S.dir?.dir));
$("#tabs").addEventListener("click", (e) => {
  const b = e.target.closest("button[data-tab]");
  if (b && !b.disabled && S.hdu) setTab(b.dataset.tab);
});

$("#theme-btn").addEventListener("click", () => {
  const root = document.documentElement;
  const dark = root.dataset.theme ? root.dataset.theme === "dark" : matchMedia("(prefers-color-scheme: dark)").matches;
  root.dataset.theme = dark ? "light" : "dark";
  try { localStorage.setItem("fitsview-theme", root.dataset.theme); } catch {}
  if (S.tab === "plot" && S.hdu) setTab("plot");
});
try { const t = localStorage.getItem("fitsview-theme"); if (t) document.documentElement.dataset.theme = t; } catch {}

// keyboard: ↑/↓ moves between HDUs
document.addEventListener("keydown", (e) => {
  if (!S.current || !S.hdu || /INPUT|SELECT|TEXTAREA/.test(document.activeElement?.tagName)) return;
  if (e.key === "ArrowDown" || e.key === "ArrowUp") {
    const next = S.hdu.index + (e.key === "ArrowDown" ? 1 : -1);
    if (next >= 0 && next < S.current.hdus.length) { e.preventDefault(); selectHdu(next); }
  }
});

// drag & drop (file is uploaded to a temp copy, since browsers hide real paths)
let dragDepth = 0;
window.addEventListener("dragenter", (e) => { e.preventDefault(); dragDepth++; $("#drop-overlay").hidden = false; });
window.addEventListener("dragleave", () => { if (--dragDepth <= 0) { dragDepth = 0; $("#drop-overlay").hidden = true; } });
window.addEventListener("dragover", (e) => e.preventDefault());
window.addEventListener("drop", async (e) => {
  e.preventDefault();
  dragDepth = 0;
  $("#drop-overlay").hidden = true;
  if (window.pywebview) return; // desktop app: Python opens the real path
  for (const file of e.dataTransfer.files) {
    const fd = new FormData();
    fd.append("file", file);
    toast(`Uploading ${file.name}…`);
    try {
      const r = await fetch("/api/upload", { method: "POST", body: fd });
      const j = await r.json();
      if (!r.ok) throw new Error(j.error);
      await openFile(j.path);
    } catch (err) {
      toast(err.message, true);
    }
  }
});

// desktop app (pywebview): native open dialog
window.addEventListener("pywebviewready", () => {
  const btn = $("#browse-btn");
  btn.hidden = false;
  btn.onclick = async () => {
    for (const p of await window.pywebview.api.open_dialog()) await openFile(p);
  };
});

(async function init() {
  const init = await api("/api/initial");
  await browse(init.start_dir);
  for (const f of init.files) await openFile(f);
  if (!init.ds9) console.warn("ds9 executable not found; set FITSVIEW_DS9");
})();
