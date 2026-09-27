/**
 * locationmap-overlay.js — actor-pin overlay for the RSDWTools embedded map.
 *
 * Mirrors the RSDWArchive LocationMap.html behavior: a collapsible panel
 * top-right of the map with a category tree (parent + subcategory checkboxes,
 * counts, search filter, icon-size slider). Pulls data from
 *   ./locationdata/LocationMapData.json
 * which the C# host populates via Services/LocationMapDataService.cs.
 *
 * IPC with the host (via map.js's chrome.webview bridge):
 *   Host -> JS:
 *     { type:"locationDataPresence", cached:true|false, fetchedAt:"<ISO>"|null }
 *     { type:"locationDataReady" }
 *     { type:"locationDataStatus", message, error, done, pct }
 *   JS -> Host (via the postToHost passed into mount()):
 *     { type:"refreshLocationData" }
 *
 * Mounted only on the full-screen map surface (NOT minimap/modify) so the
 * HUD-style surfaces stay clutter-free.
 */
(function () {
  "use strict";

  const DATA_URL = "./locationdata/LocationMapData.json";
  const ICON_SIZE_DEFAULT = 20;
  const ICON_SIZE_MIN = 8;
  const ICON_SIZE_MAX = 64;
  const ICON_SIZE_KEY = "rsdwtools.locationmap.iconSize";
  const PANEL_OPEN_KEY = "rsdwtools.locationmap.open";

  // Cap the number of points materialised at once. Even with virtualization
  // Leaflet starts to feel sticky past ~20k markers in WebView2 on midrange
  // hardware. We render the FIRST N points of the filtered set per leaf and
  // surface the truncation in the count badge.
  const PER_LEAF_RENDER_CAP = 5000;

  // Module state. Set by mount().
  let api = { map: null, gameXYToLatLng: null, postToHost: null, mode: "embedded", compact: false };
  // Last user-facing state. Mirrors the panel inputs so headless
  // (minimap) instances can still drive search/iconSize when the host
  // syncs state across instances.
  let currentSearch = "";
  let currentIconSize = 20;
  // Set true while we're applying remote state so we don't echo it
  // back to the host and trigger a sync loop.
  let applyingRemote = false;
  let panelEl = null;
  let listEl = null;
  let countEl = null;
  let searchEl = null;
  let iconSizeSliderEl = null;
  let iconSizeValueEl = null;
  let statusEl = null;
  let refreshBtn = null;
  let lastFetchedEl = null;

  /** @type {Array} */ let parents = [];
  /** @type {Array} */ let leaves = [];
  let dataLoaded = false;
  /** @type {Set<string>|null} */ let pendingEnabled = null;

  /* ---------- Public API exposed on window.LocationMapOverlay ---------- */
  window.LocationMapOverlay = {
    findNearestPoint(worldX, worldY) {
      // Search across every leaf bucket regardless of enabled state so a
      // right-click "Teleport" can snap to known actor locations even when
      // the user hasn't toggled that category visible. Returns the closest
      // point + the leaf metadata, or null if no data is loaded yet.
      if (!dataLoaded) return null;
      let best = null;
      let bestDist2 = Infinity;
      for (const leaf of leaves) {
        const pts = leaf.points;
        for (let i = 0; i < pts.length; i++) {
          const p = pts[i];
          const dx = (p.x || 0) - worldX;
          const dy = (p.y || 0) - worldY;
          const d2 = dx * dx + dy * dy;
          if (d2 < bestDist2) {
            bestDist2 = d2;
            best = { point: p, leaf };
          }
        }
      }
      if (!best) return null;
      return {
        point: best.point,
        leafKey: best.leaf.key,
        leafLabel: best.leaf.label,
        distance: Math.sqrt(bestDist2)
      };
    },
    mount(options) {
      api.map = options.map;
      api.gameXYToLatLng = options.gameXYToLatLng;
      api.postToHost = options.postToHost || function () { };
      api.mode = (options.mode || "embedded").toLowerCase();
      api.headless = !!options.headless;
      currentIconSize = readIconSize();
      injectStyles();
      if (!api.headless) {
        buildPanel();
      }
      // Don't auto-load until the host tells us whether cache exists ;
      // avoids a noisy 404 fetch on first run before any download.
    },
    onHostMessage(payload) {
      if (!payload || !payload.type) return;
      switch (payload.type) {
        case "locationDataPresence":
          if (payload.cached) {
            updateLastFetched(payload.fetchedAt);
            // Only load once. Late presence pings (fired when sister
            // webviews come online) must not wipe user selections by
            // re-ingesting fresh leaf objects with enabled:false.
            if (!dataLoaded) {
              setStatus("Cached pin data found. Loading...");
              loadData(false);
            }
          } else {
            if (!dataLoaded) setStatus("No pin data cached yet. Click Refresh to download.");
            updateLastFetched(null);
          }
          break;
        case "locationDataReady":
          setStatus("Reloading pin data...");
          loadData(true);
          break;
        case "locationDataStatus":
          setStatus(payload.message || "");
          if (refreshBtn) {
            if (payload.done) {
              refreshBtn.disabled = false;
              refreshBtn.textContent = "Refresh";
            } else {
              refreshBtn.disabled = true;
              const pct = typeof payload.pct === "number" && payload.pct >= 0
                ? Math.round(payload.pct * 100) : null;
              refreshBtn.textContent = pct !== null ? `${pct}%` : "Working...";
            }
          }
          break;
        case "locationOverlayState":
          applyRemoteState(payload.state || {});
          break;
      }
    }
  };

  /* ---------- Styles ---------- */
  function injectStyles() {
    const css = `
      .lm-panel {
        position: absolute;
        top: 8px;
        right: 8px;
        z-index: 1100;
        max-height: calc(100% - 16px);
        width: 280px;
        background: rgba(20,20,20,0.92);
        border: 1px solid #4a4a4a;
        border-radius: 4px;
        color: #d3d3d3;
        font: 12px "Segoe UI", system-ui, sans-serif;
        display: flex;
        flex-direction: column;
        box-shadow: 0 4px 14px rgba(0,0,0,0.6);
      }
      .lm-panel.collapsed .lm-body { display: none; }
      .lm-header {
        display: flex;
        align-items: center;
        gap: 6px;
        padding: 6px 8px;
        cursor: pointer;
        border-bottom: 1px solid #333;
        user-select: none;
      }
      .lm-header h3 {
        margin: 0;
        font-size: 12px;
        flex: 1 1 auto;
        color: #e0e0e0;
      }
      .lm-chevron { color: #9DC8E8; font-family: monospace; }
      .lm-body { display: flex; flex-direction: column; gap: 4px; padding: 6px 8px; min-height: 0; }
      .lm-row { display: flex; align-items: center; gap: 6px; }
      .lm-row input[type=search] {
        flex: 1 1 auto;
        background: #1a1a1a;
        border: 1px solid #3a3a3a;
        color: #e0e0e0;
        padding: 3px 6px;
        border-radius: 3px;
        font: inherit;
      }
      .lm-row button {
        background: #2a4a6a;
        color: #fff;
        border: 1px solid #3a6088;
        border-radius: 3px;
        padding: 3px 8px;
        cursor: pointer;
        font: inherit;
      }
      .lm-row button:hover:not(:disabled) { background: #3a5e80; }
      .lm-row button:disabled { opacity: 0.6; cursor: default; }
      .lm-status {
        font-size: 11px;
        color: #9DC8E8;
        min-height: 14px;
        word-break: break-word;
      }
      .lm-status.error { color: #FF8080; }
      .lm-fetched {
        font-size: 10px;
        color: #888;
        font-family: monospace;
      }
      .lm-list {
        list-style: none;
        margin: 0;
        padding: 0;
        overflow-y: auto;
        max-height: 50vh;
      }
      .lm-list li {
        display: flex;
        align-items: center;
        gap: 4px;
        padding: 2px 0;
      }
      .lm-list li.lm-sub { padding-left: 18px; }
      .lm-list label {
        flex: 1 1 auto;
        cursor: pointer;
        white-space: nowrap;
        overflow: hidden;
        text-overflow: ellipsis;
      }
      .lm-list .lm-count {
        opacity: 0.7;
        font-family: monospace;
        font-size: 11px;
      }
      .lm-list img.lm-icon {
        width: 14px;
        height: 14px;
        object-fit: contain;
        flex: 0 0 auto;
      }
      .lm-expand {
        background: none;
        border: none;
        color: inherit;
        cursor: pointer;
        font: inherit;
        width: 14px;
        padding: 0;
      }
      .lm-slider-row {
        display: flex;
        align-items: center;
        gap: 6px;
        padding-top: 4px;
        border-top: 1px solid #333;
      }
      .lm-slider-row input[type=range] { flex: 1 1 auto; }
      .lm-marker-icon {
        width: var(--lm-icon-size, 20px) !important;
        height: var(--lm-icon-size, 20px) !important;
      }
    `;
    const tag = document.createElement("style");
    tag.textContent = css;
    document.head.appendChild(tag);
    document.documentElement.style.setProperty("--lm-icon-size", `${readIconSize()}px`);
  }

  /* ---------- Panel construction ---------- */
  function buildPanel() {
    panelEl = document.createElement("div");
    panelEl.className = "lm-panel";
    if (!isPanelOpen()) panelEl.classList.add("collapsed");

    panelEl.innerHTML = `
      <div class="lm-header">
        <span class="lm-chevron"></span>
        <h3>Actor pins</h3>
      </div>
      <div class="lm-body">
        <div class="lm-row">
          <input type="search" placeholder="Filter (e.g. ore stone -coal)"
                 spellcheck="false" autocomplete="off" />
        </div>
        <div class="lm-row">
          <button type="button" data-act="refresh">Refresh</button>
          <span class="lm-fetched"></span>
        </div>
        <div class="lm-status" role="status" aria-live="polite"></div>
        <ul class="lm-list" aria-label="Actor categories"></ul>
        <div class="lm-row" style="justify-content:space-between;">
          <span class="lm-count" style="opacity:0.7;font-family:monospace;font-size:11px;"></span>
        </div>
        <div class="lm-slider-row">
          <label for="lm-icon-size" style="font-size:11px;">Icon</label>
          <input id="lm-icon-size" type="range"
                 min="${ICON_SIZE_MIN}" max="${ICON_SIZE_MAX}" step="1" />
          <span class="lm-icon-size-value" style="font-family:monospace;font-size:11px;width:24px;text-align:right;"></span>
        </div>
      </div>`;

    document.body.appendChild(panelEl);

    const header = panelEl.querySelector(".lm-header");
    const chevron = panelEl.querySelector(".lm-chevron");
    listEl = panelEl.querySelector(".lm-list");
    countEl = panelEl.querySelector(".lm-count");
    searchEl = panelEl.querySelector("input[type=search]");
    iconSizeSliderEl = panelEl.querySelector("#lm-icon-size");
    iconSizeValueEl = panelEl.querySelector(".lm-icon-size-value");
    statusEl = panelEl.querySelector(".lm-status");
    refreshBtn = panelEl.querySelector('button[data-act="refresh"]');
    lastFetchedEl = panelEl.querySelector(".lm-fetched");

    refreshChevron();
    header.addEventListener("click", (ev) => {
      // Avoid toggling when the click started inside an interactive child.
      if (ev.target.closest("button,input,a,label")) return;
      panelEl.classList.toggle("collapsed");
      try { localStorage.setItem(panelOpenKey(), panelEl.classList.contains("collapsed") ? "0" : "1"); } catch (_) { /* sandbox */ }
      refreshChevron();
    });
    searchEl.addEventListener("input", () => {
      currentSearch = searchEl.value || "";
      refreshAll();
      broadcastState();
    });
    refreshBtn.addEventListener("click", () => {
      api.postToHost({ type: "refreshLocationData" });
      setStatus("Requesting refresh from RSDWArchive...");
    });

    const initialIcon = readIconSize();
    iconSizeSliderEl.value = String(initialIcon);
    iconSizeValueEl.textContent = `${initialIcon}px`;
    iconSizeSliderEl.addEventListener("input", () => {
      const px = parseInt(iconSizeSliderEl.value, 10) || ICON_SIZE_DEFAULT;
      currentIconSize = px;
      document.documentElement.style.setProperty("--lm-icon-size", `${px}px`);
      iconSizeValueEl.textContent = `${px}px`;
      try { localStorage.setItem(ICON_SIZE_KEY, String(px)); } catch (_) { /* sandbox */ }
      broadcastState();
    });
  }

  function refreshChevron() {
    const chev = panelEl.querySelector(".lm-chevron");
    if (chev) chev.textContent = panelEl.classList.contains("collapsed") ? "\u25B8" : "\u25BE";
  }

  function panelOpenKey() {
    return PANEL_OPEN_KEY + ":" + (api.mode || "embedded");
  }

  function isPanelOpen() {
    try {
      const v = localStorage.getItem(panelOpenKey());
      if (v === "1") return true;
      if (v === "0") return false;
    } catch (_) { /* sandbox */ }
    // No stored preference: collapsed by default in compact (minimap) mode.
    return !api.compact;
  }

  function readIconSize() {
    try {
      const v = parseInt(localStorage.getItem(ICON_SIZE_KEY) || "", 10);
      if (Number.isFinite(v) && v >= ICON_SIZE_MIN && v <= ICON_SIZE_MAX) return v;
    } catch (_) { /* sandbox */ }
    return ICON_SIZE_DEFAULT;
  }

  function setStatus(text, isError) {
    if (!statusEl) return;
    statusEl.textContent = text || "";
    statusEl.classList.toggle("error", !!isError);
  }

  function updateLastFetched(iso) {
    if (!lastFetchedEl) return;
    if (!iso) { lastFetchedEl.textContent = ""; return; }
    try {
      const d = new Date(iso);
      lastFetchedEl.textContent = `Updated ${d.toLocaleString()}`;
    } catch (_) { lastFetchedEl.textContent = iso; }
  }

  /* ---------- Data load ---------- */
  async function loadData(force) {
    try {
      // cache:no-store so a fresh refresh isn't masked by the WebView2's
      // internal HTTP cache.
      const r = await fetch(DATA_URL, { cache: force ? "reload" : "default" });
      if (!r.ok) {
        setStatus(`Pin data load failed (HTTP ${r.status}). Try Refresh.`, true);
        return;
      }
      const json = await r.json();
      ingest(json);
      dataLoaded = true;
      if (!api.headless) buildList();
      // If a remote state arrived before data loaded, apply pending enabled
      // set now. Otherwise honour what the user toggled in this instance.
      if (pendingEnabled) {
        for (const leaf of leaves) leaf.enabled = pendingEnabled.has(leaf.key);
        if (!api.headless) {
          for (const leaf of leaves) if (leaf._cb) leaf._cb.checked = leaf.enabled;
        }
        pendingEnabled = null;
      }
      refreshAll();
      setStatus(`Loaded ${parents.length} categories, ${leaves.length} buckets. Tick boxes to show pins.`);
    } catch (e) {
      setStatus(`Pin data load error: ${e && e.message ? e.message : e}`, true);
    }
  }

  /* ---------- Ingest (mirrors locationmap.js website logic) ---------- */
  function ingest(payload) {
    parents = [];
    leaves = [];
    const cats = (payload && payload.categories) || {};
    for (const catKey of Object.keys(cats)) {
      const c = cats[catKey] || {};
      const parent = {
        key: catKey,
        label: c.label || catKey,
        icon: c.icon || null,
        leaves: [],
        hasSubcategories: !!c.subcategories,
        expanded: false
      };
      if (c.subcategories) {
        for (const subKey of Object.keys(c.subcategories)) {
          const s = c.subcategories[subKey] || {};
          const points = Array.isArray(s.points) ? s.points : [];
          const leaf = makeLeaf(`${catKey}/${subKey}`, s.label || subKey, s.icon || null, points);
          parent.leaves.push(leaf);
          leaves.push(leaf);
        }
      } else {
        const points = Array.isArray(c.points) ? c.points : [];
        const leaf = makeLeaf(catKey, c.label || catKey, c.icon || null, points);
        parent.leaves.push(leaf);
        leaves.push(leaf);
      }
      parents.push(parent);
    }
    parents.sort((a, b) => sumPoints(b) - sumPoints(a));
  }

  function makeLeaf(key, label, icon, points) {
    return {
      key, label, icon, points,
      icon_: makeLeafletIcon(icon),
      leafletLayer: null,
      enabled: false
    };
  }

  function sumPoints(parent) {
    let n = 0;
    for (const leaf of parent.leaves) n += leaf.points.length;
    return n;
  }

  // Resolve an icon path from the JSON (e.g. "icons/Foo.png") to a URL the
  // page can load. The JSON lives at ./locationdata/LocationMapData.json so
  // its sibling "icons/" folder is at ./locationdata/icons/. Absolute http(s)
  // URLs and already-prefixed paths are passed through unchanged.
  function resolveIconUrl(p) {
    if (!p) return null;
    if (/^https?:\/\//i.test(p)) return p;
    if (p.startsWith("./locationdata/") || p.startsWith("locationdata/")) return p;
    return "./locationdata/" + p.replace(/^\.\//, "");
  }

  function makeLeafletIcon(iconUrl) {
    if (!iconUrl) return null;
    return window.L.icon({
      iconUrl: resolveIconUrl(iconUrl),
      iconSize: [20, 20],
      iconAnchor: [10, 10],
      popupAnchor: [0, -8],
      className: "lm-marker-icon"
    });
  }

  /* ---------- DOM list ---------- */
  function buildList() {
    listEl.innerHTML = "";
    for (const parent of parents) {
      const li = document.createElement("li");
      li.className = "lm-parent";

      const expandBtn = document.createElement("button");
      expandBtn.type = "button";
      expandBtn.className = "lm-expand";
      expandBtn.setAttribute("aria-label", "Toggle subcategories");
      expandBtn.textContent = parent.hasSubcategories ? "\u25B8" : "\u00A0";
      expandBtn.disabled = !parent.hasSubcategories;
      li.appendChild(expandBtn);

      const cb = document.createElement("input");
      cb.type = "checkbox";
      cb.id = `lm-cat-${cssKey(parent.key)}`;
      li.appendChild(cb);

      if (parent.icon) {
        const img = document.createElement("img");
        img.src = resolveIconUrl(parent.icon);
        img.alt = "";
        img.className = "lm-icon";
        img.onerror = () => { img.style.visibility = "hidden"; };
        li.appendChild(img);
      }

      const lbl = document.createElement("label");
      lbl.htmlFor = cb.id;
      lbl.textContent = parent.label;
      li.appendChild(lbl);

      const cnt = document.createElement("span");
      cnt.className = "lm-count";
      li.appendChild(cnt);

      parent._li = li;
      parent._cb = cb;
      parent._countEl = cnt;
      parent._expandBtn = expandBtn;
      listEl.appendChild(li);

      cb.addEventListener("change", () => {
        const desired = cb.checked;
        for (const leaf of parent.leaves) {
          leaf.enabled = desired;
          if (leaf._cb) leaf._cb.checked = desired;
        }
        refreshAll();
        broadcastState();
      });

      if (parent.hasSubcategories) {
        // Render subcategory rows but keep them hidden until expanded.
        for (const leaf of parent.leaves) {
          const sli = document.createElement("li");
          sli.className = "lm-sub";
          sli.style.display = "none";

          const spacer = document.createElement("span");
          spacer.style.cssText = "display:inline-block;width:14px;";
          sli.appendChild(spacer);

          const scb = document.createElement("input");
          scb.type = "checkbox";
          scb.id = `lm-leaf-${cssKey(leaf.key)}`;
          sli.appendChild(scb);

          if (leaf.icon) {
            const img = document.createElement("img");
            img.src = resolveIconUrl(leaf.icon);
            img.alt = "";
            img.className = "lm-icon";
            img.onerror = () => { img.style.visibility = "hidden"; };
            sli.appendChild(img);
          }

          const slbl = document.createElement("label");
          slbl.htmlFor = scb.id;
          slbl.textContent = leaf.label;
          sli.appendChild(slbl);

          const scnt = document.createElement("span");
          scnt.className = "lm-count";
          sli.appendChild(scnt);

          leaf._li = sli;
          leaf._cb = scb;
          leaf._countEl = scnt;
          listEl.appendChild(sli);

          scb.addEventListener("change", () => {
            leaf.enabled = scb.checked;
            refreshAll();
            broadcastState();
          });
        }
        expandBtn.addEventListener("click", () => {
          parent.expanded = !parent.expanded;
          expandBtn.textContent = parent.expanded ? "\u25BE" : "\u25B8";
          for (const leaf of parent.leaves) {
            if (leaf._li) leaf._li.style.display = parent.expanded ? "flex" : "none";
          }
        });
      } else {
        // Single-bucket category: parent's checkbox IS the leaf checkbox.
        const leaf = parent.leaves[0];
        leaf._cb = cb;
        leaf._countEl = cnt;
      }
    }
  }

  function cssKey(key) {
    return String(key).replace(/[^a-z0-9_-]/gi, "_");
  }

  /* ---------- Filter + render ---------- */
  function tokenize(query) {
    const out = { include: [], exclude: [] };
    if (!query) return out;
    const tokens = query.toLowerCase().split(/\s+/).filter(Boolean);
    for (const t of tokens) {
      if (t.startsWith("-") && t.length > 1) out.exclude.push(t.slice(1));
      else out.include.push(t);
    }
    return out;
  }

  function filterPoints(points, tokens) {
    if (!tokens.include.length && !tokens.exclude.length) return points;
    return points.filter(p => {
      const lc = (p.name || "").toLowerCase();
      for (const ex of tokens.exclude) if (lc.includes(ex)) return false;
      for (const inc of tokens.include) if (!lc.includes(inc)) return false;
      return true;
    });
  }

  function refreshLeafRender(leaf, tokens) {
    const filtered = filterPoints(leaf.points, tokens);
    const capped = filtered.length > PER_LEAF_RENDER_CAP
      ? filtered.slice(0, PER_LEAF_RENDER_CAP) : filtered;
    if (leaf._countEl) {
      let label;
      if (filtered.length === leaf.points.length) {
        label = String(leaf.points.length);
      } else {
        label = `${filtered.length} / ${leaf.points.length}`;
      }
      if (capped.length !== filtered.length) label += ` (cap ${PER_LEAF_RENDER_CAP})`;
      leaf._countEl.textContent = label;
    }
    if (leaf.leafletLayer) {
      api.map.removeLayer(leaf.leafletLayer);
      leaf.leafletLayer = null;
    }
    if (!leaf.enabled || !capped.length) return filtered.length;
    leaf.leafletLayer = buildLeafLayer(leaf, capped);
    leaf.leafletLayer.addTo(api.map);
    return filtered.length;
  }

  function buildLeafLayer(leaf, points) {
    const layer = window.L.layerGroup();
    const icon = leaf.icon_;
    for (const p of points) {
      const m = window.L.marker(api.gameXYToLatLng(p.x, p.y), icon ? { icon } : undefined);
      m.bindPopup(buildPopup(leaf, p));
      // Wire the Teleport button after the popup DOM is attached. The
      // button itself is rendered with a data-* signature in buildPopup.
      m.on("popupopen", (ev) => {
        const root = ev.popup.getElement && ev.popup.getElement();
        if (!root) return;
        const btn = root.querySelector("button[data-lm-teleport]");
        if (!btn) return;
        btn.addEventListener("click", (e) => {
          e.stopPropagation();
          api.postToHost({
            type: "teleport",
            x: p.x, y: p.y, z: p.z,
            name: p.name || leaf.label,
            source: "pin"
          });
        }, { once: true });
      });
      layer.addLayer(m);
    }
    return layer;
  }

  function buildPopup(leaf, p) {
    const lines = [
      `<div style="font-weight:bold;border-bottom:1px solid #333;margin-bottom:4px;">${escapeHtml(leaf.label)}</div>`,
      `<div>${escapeHtml(p.name || "(unnamed)")}</div>`,
      `<div style="font-family:monospace;font-size:11px;opacity:0.8;">x:${(p.x ?? 0).toFixed(1)} y:${(p.y ?? 0).toFixed(1)} z:${(p.z ?? 0).toFixed(1)}</div>`
    ];
    if (p.uaid) lines.push(`<div style="font-family:monospace;font-size:10px;opacity:0.7;">UAID ${escapeHtml(p.uaid)}</div>`);
    lines.push(`<div style="margin-top:6px;"><button type="button" data-lm-teleport="1" style="background:#2a4a6a;color:#fff;border:1px solid #3a6088;border-radius:3px;padding:3px 10px;cursor:pointer;font:inherit;">Teleport</button></div>`);
    return lines.join("");
  }

  function escapeHtml(s) {
    return String(s == null ? "" : s).replace(/[&<>"']/g, ch => ({
      "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;"
    }[ch]));
  }

  function refreshParentRow(parent, leafShown) {
    if (!parent._countEl) return;
    let totalAll = 0;
    let totalShown = 0;
    let anyEnabled = false;
    let allEnabled = true;
    for (const leaf of parent.leaves) {
      totalAll += leaf.points.length;
      totalShown += leafShown.get(leaf.key) || 0;
      if (leaf.enabled) anyEnabled = true;
      else allEnabled = false;
    }
    parent._countEl.textContent = totalShown === totalAll
      ? String(totalAll)
      : `${totalShown} / ${totalAll}`;
    if (parent._cb && parent.hasSubcategories) {
      parent._cb.checked = anyEnabled;
      parent._cb.indeterminate = anyEnabled && !allEnabled;
    }
  }

  function refreshAll() {
    if (!dataLoaded) return;
    const tokens = tokenize(currentSearch);
    const leafShown = new Map();
    let grandShown = 0;
    let grandTotal = 0;
    for (const leaf of leaves) {
      const shown = refreshLeafRender(leaf, tokens);
      leafShown.set(leaf.key, leaf.enabled ? Math.min(shown, PER_LEAF_RENDER_CAP) : 0);
      grandTotal += leaf.points.length;
      if (leaf.enabled) grandShown += Math.min(shown, PER_LEAF_RENDER_CAP);
    }
    for (const parent of parents) refreshParentRow(parent, leafShown);
    if (countEl) {
      countEl.textContent = `${grandShown.toLocaleString()} of ${grandTotal.toLocaleString()} pins shown`;
    }
  }

  /* ---------- Cross-instance state sync ---------- */
  // Posted to the host whenever the user changes selections / search /
  // icon size on this instance. The host caches it and re-broadcasts to
  // every map webview so the embedded tab, full pop-out, and minimap
  // all show the same pins.
  function broadcastState() {
    if (applyingRemote) return;
    if (!api.postToHost) return;
    const enabled = [];
    for (const leaf of leaves) if (leaf.enabled) enabled.push(leaf.key);
    api.postToHost({
      type: "locationOverlayState",
      state: {
        leaves: enabled,
        search: currentSearch || "",
        iconSize: currentIconSize
      }
    });
  }

  function applyRemoteState(state) {
    if (!state || typeof state !== "object") return;
    applyingRemote = true;
    try {
      // Search.
      if (typeof state.search === "string") {
        currentSearch = state.search;
        if (searchEl) searchEl.value = currentSearch;
      }
      // Icon size.
      if (typeof state.iconSize === "number"
          && state.iconSize >= ICON_SIZE_MIN
          && state.iconSize <= ICON_SIZE_MAX) {
        currentIconSize = state.iconSize;
        document.documentElement.style.setProperty("--lm-icon-size", `${currentIconSize}px`);
        if (iconSizeSliderEl) iconSizeSliderEl.value = String(currentIconSize);
        if (iconSizeValueEl) iconSizeValueEl.textContent = `${currentIconSize}px`;
      }
      // Selections. Apply only if data is loaded ; otherwise stash for
      // post-load (refreshAll runs after ingest in loadData).
      if (Array.isArray(state.leaves)) {
        const enabledSet = new Set(state.leaves);
        if (dataLoaded) {
          for (const leaf of leaves) {
            const want = enabledSet.has(leaf.key);
            leaf.enabled = want;
            if (leaf._cb) leaf._cb.checked = want;
          }
          refreshAll();
        } else {
          // Remember and apply once data finishes loading.
          pendingEnabled = enabledSet;
        }
      }
    } finally {
      applyingRemote = false;
    }
  }
})();
