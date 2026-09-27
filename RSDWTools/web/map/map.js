/**
 * RSDWTools Map (Phase 1) — Leaflet world map with a live player marker.
 *
 * Hosted inside a WebView2 in the WPF Map tab. Communication with the
 * C# host uses chrome.webview messages:
 *
 *   Host -> JS  (string, JSON):
 *     { "type": "player", "x": <num>, "y": <num>, "z": <num>, "yaw": <num> }
 *     { "type": "clearPlayer" }
 *     { "type": "status", "message": "..." }
 *
 *   JS -> Host  (string, JSON):
 *     { "type": "ready" }      // sent once Leaflet has finished initializing
 *     { "type": "log", "message": "..." }
 *
 * CRS / transformation come from RSDWArchive/website/map.js so coords from
 * the Archive line up with the wiki tiles. Leaflet axis convention is
 * lat=worldY, lng=worldX. NOTE: bounds are written as [lat,lng] arrays here
 * (NOT {lon,lat} objects) ; Leaflet's LatLng constructor only understands
 * `lng`, so {lon} silently becomes NaN and fitBounds renders nothing.
 */

const TILE_URL = "https://maps.runescape.wiki/dw/tiles/{z}/{x}_{y}.png";

// [lat (worldY), lng (worldX)] pairs, SW then NE.
const WORLD_BOUNDS = [
  [-100800, 0],
  [201600, 302400]
];

// Mode comes from the query string (?mode=minimap|modify|full|embedded).
// Minimap disables panning / zoom controls and re-centers the view on
// every player update so the dot stays fixed in the middle of the
// window like a HUD. Modify behaves the same way (locked + follows
// player) but exposes a draggable / rotatable build outline so the
// user can position a build delivery directly on the map.
const MODE = (new URLSearchParams(location.search).get("mode") || "embedded").toLowerCase();
const IS_MINIMAP = MODE === "minimap";
const IS_MODIFY = MODE === "modify";
const IS_LOCKED = IS_MINIMAP || IS_MODIFY;

const statusEl = document.getElementById("status-bar");
const mapEl = document.getElementById("world-map");

let map = null;
let playerMarker = null;
// Remote player markers, keyed by player name. Recreated from scratch
// on every "players" message ; players come and go infrequently so the
// per-tick churn is negligible. Local player is intentionally excluded
// upstream (host C# filters is_local) since the dedicated playerMarker
// already covers it.
let remotePlayerMarkers = new Map();
let buildLayer = null; // L.layerGroup holding rectangle + scatter for the selected build
let previewLayer = null; // L.layerGroup for Modify Delivery live preview
let lastPlayer = null; // {x, y} cache so modify mode can snap on first sight

// Modify mode state. Holds the original (untransformed) polygons +
// centroid plus the user's current dx/dy/yaw. Recomputing transformed
// vertices on each interaction is cheap (tens of points).
const MODIFY = {
  polygons: [],
  cx: 0,
  cy: 0,
  dx: 0,
  dy: 0,
  yaw: 0,
  initialized: false,
  layer: null,
  centroidMarker: null
};

function setStatus(text) {
  if (statusEl) statusEl.textContent = text;
}

function postToHost(payload) {
  try {
    // Mirror logs to the devtools console so we can debug without the
    // host status bar.
    if (payload && payload.type === "log") {
      console.log("[map.js]", payload.message);
    }
    if (window.chrome && window.chrome.webview && typeof window.chrome.webview.postMessage === "function") {
      window.chrome.webview.postMessage(JSON.stringify(payload));
    }
  } catch (_) {
    /* host may not be present (browser-test mode) */
  }
}

// Surface JS errors back to the WPF status bar so we don't have to crack
// open DevTools to figure out why the page is blank. Generic "Script
// error." messages with no file/line come from cross-origin scripts
// (CDN tile loaders) ; filter those so they don't drown out real errors.
window.addEventListener("error", (ev) => {
  if (!ev || !ev.message || ev.message === "Script error." && !ev.filename) return;
  const stack = (ev.error && ev.error.stack) ? String(ev.error.stack).split("\n").slice(0, 4).join(" | ") : "(no stack)";
  setStatus(`JS error: ${ev.message}`);
  postToHost({ type: "log", message: `error: ${ev.message} @ ${ev.filename}:${ev.lineno} stack=${stack}` });
});

function createDragonwildsMap(container) {
  const bounds = WORLD_BOUNDS;
  const mult = 6144 / 302400 / 16;
  const dragonwildsCRS = window.L.extend({}, window.L.CRS.Simple, {
    projection: window.L.Projection.LonLat,
    transformation: new window.L.Transformation(mult, 0, mult, mult * 100800)
  });

  // Minimap and modify are locked HUDs: no drag, no panning. Minimap
  // is a fixed-zoom HUD ; modify exposes +/- buttons so the user can
  // zoom in tighter for precise placement (scroll-wheel is reserved
  // for yaw rotation, so we cannot use it for zoom). Modify still
  // disables scrollWheelZoom for that reason.
  const m = window.L.map(container, {
    crs: dragonwildsCRS,
    maxBounds: bounds,
    zoom: IS_MODIFY ? 4 : (IS_LOCKED ? 3 : 1),
    minZoom: IS_LOCKED ? 3 : 0,
    maxZoom: IS_MODIFY ? 7 : 4,
    zoomSnap: 0.5,
    attributionControl: false,
    zoomControl: IS_MODIFY || !IS_LOCKED,
    dragging: !IS_LOCKED,
    scrollWheelZoom: !IS_LOCKED,
    doubleClickZoom: !IS_LOCKED,
    boxZoom: !IS_LOCKED,
    keyboard: !IS_LOCKED,
    touchZoom: !IS_LOCKED,
    tap: false
  });

  const tileLayer = window.L.tileLayer(TILE_URL, {
    referrerPolicy: "no-referrer",
    bounds: bounds,
    minZoom: 0,
    maxZoom: IS_MODIFY ? 7 : 4,
    maxNativeZoom: 4,
    noWrap: true
  });
  let _tileErrCount = 0;
  tileLayer.on("tileerror", (e) => {
    _tileErrCount++;
    const src = (e && e.tile && e.tile.src) || "?";
    setStatus(`tileerror #${_tileErrCount}: ${src}`);
    postToHost({ type: "log", message: `tileerror: ${src}` });
  });
  tileLayer.on("tileload", () => {
    if (_tileErrCount === 0) setStatus("Map tiles loading...");
  });
  tileLayer.addTo(m);

  // Locked surfaces (minimap, modify) skip fitBounds, so the map has
  // no center until the first player update arrives. Leaflet's SVG
  // renderer crashes (`_clipPoints` reads undefined `_pxBounds.min`)
  // if any polygon is added before a view is set. Pin to world center
  // up-front ; setPlayer re-centers as soon as we know where to look.
  if (IS_LOCKED) {
    const cy = (bounds[0][0] + bounds[1][0]) / 2;
    const cx = (bounds[0][1] + bounds[1][1]) / 2;
    m.setView(window.L.latLng(cy, cx), IS_LOCKED ? 3 : 1);
  }

  return m;
}

function fitWorld() {
  if (!map) return;
  map.invalidateSize();
  // Locked surfaces (minimap / modify) don't fitBounds ; they stay at
  // their locked zoom until the first player update centers them.
  // Otherwise we'd briefly see the whole world before snapping to player.
  if (IS_LOCKED) return;
  map.fitBounds(WORLD_BOUNDS);
}

function setPlayer(x, y, _z, yaw) {
  if (!map) return;
  if (!Number.isFinite(x) || !Number.isFinite(y)) return;
  try {
    _setPlayerImpl(x, y, _z, yaw);
  } catch (e) {
    postToHost({ type: "log", message: `setPlayer threw: ${e && e.message} | ${(e && e.stack || "").split("\n").slice(0, 3).join(" | ")}` });
  }
}

function _setPlayerImpl(x, y, _z, yaw) {
  // Cache the latest player position even if we can't draw yet ; once
  // the WebView2 finishes laying out, the resize observer re-snaps.
  lastPlayer = { x, y };
  const size = map.getSize();
  if (size.x === 0 || size.y === 0) {
    map.invalidateSize();
    return;
  }
  const latlng = window.L.latLng(y, x);

  if (!playerMarker) {
    const icon = window.L.divIcon({
      className: "",
      html: '<div class="player-marker"></div>',
      iconSize: [14, 14],
      iconAnchor: [7, 7]
    });
    playerMarker = window.L.marker(latlng, { icon, interactive: false, keyboard: false }).addTo(map);
  } else {
    playerMarker.setLatLng(latlng);
  }

  // Locked HUDs (minimap, modify) keep the player pinned to the center
  // and never let the user pan/zoom away ; the world scrolls under them.
  if (IS_LOCKED) {
    map.setView(latlng, map.getZoom(), { animate: false });
  }

  // First player sighting in modify mode snaps the build preview to
  // the player so it's immediately visible and ready to drag.
  if (IS_MODIFY && !MODIFY.initialized && MODIFY.polygons.length > 0) {
    MODIFY.dx = x - MODIFY.cx;
    MODIFY.dy = y - MODIFY.cy;
    MODIFY.initialized = true;
    redrawModify();
    postModifyState();
  }

  const yawTxt = Number.isFinite(yaw) ? `, yaw ${Math.round(yaw)}` : "";
  setStatus(`Player @ X=${Math.round(x)} Y=${Math.round(y)}${yawTxt}`);
}

function clearPlayer() {
  if (playerMarker && map) {
    map.removeLayer(playerMarker);
  }
  playerMarker = null;
  setStatus("Tracking paused.");
}

// Render the set of remote players as labeled red dots. Diff against
// the existing marker map so we avoid pointless add/remove churn when
// the roster is stable across ticks (the common case).
function setRemotePlayers(players) {
  if (!map) return;
  if (!Array.isArray(players)) return;
  const seen = new Set();
  for (const p of players) {
    if (!p || typeof p.name !== "string") continue;
    if (!Number.isFinite(p.x) || !Number.isFinite(p.y)) continue;
    seen.add(p.name);
    const latlng = window.L.latLng(p.y, p.x);
    let m = remotePlayerMarkers.get(p.name);
    if (!m) {
      // Red dot for remote players ; the local player is the existing
      // blue dot (.player-marker). Tooltip shows the player name and a
      // (host) suffix for the session host so the user can tell at a
      // glance who is authoritative.
      const label = p.host ? `${p.name} (host)` : p.name;
      const icon = window.L.divIcon({
        className: "",
        html: '<div class="remote-player-marker"></div>',
        iconSize: [12, 12],
        iconAnchor: [6, 6]
      });
      m = window.L.marker(latlng, { icon, interactive: true, keyboard: false }).addTo(map);
      m.bindTooltip(label, { permanent: true, direction: "top", offset: [0, -8], className: "remote-player-label" });
      remotePlayerMarkers.set(p.name, m);
    } else {
      m.setLatLng(latlng);
      const label = p.host ? `${p.name} (host)` : p.name;
      const tt = m.getTooltip();
      if (tt && tt.getContent() !== label) tt.setContent(label);
    }
  }
  // Drop markers for players no longer in the roster (left the session
  // or died and we've stopped emitting them).
  for (const [name, m] of remotePlayerMarkers) {
    if (!seen.has(name)) {
      try { map.removeLayer(m); } catch (_) {}
      remotePlayerMarkers.delete(name);
    }
  }
}

function clearRemotePlayers() {
  for (const [, m] of remotePlayerMarkers) {
    try { map.removeLayer(m); } catch (_) {}
  }
  remotePlayerMarkers.clear();
}

// Phase 2: visualize the currently-selected build from Build Service.
// Payload shape:
//   { type: "build", name, count, cx, cy,
//     polygons: [ [[x,y], ...], [[x,y], ...] ]   // CCW rings, world cm
//   }
// Each ring is one closed boundary. Multiple rings handle disconnected
// sub-structures and concave shapes (L/U/hollow). Minimap surface
// skips this overlay ; it's a passive HUD.
function setBuild(payload) {
  if (!map) return;
  // Modify mode shows its own cyan draggable outline ; the global
  // build broadcast would otherwise clutter that surface with the
  // immobile orange copy.
  if (IS_MINIMAP || IS_MODIFY) return;
  clearBuild();

  const polygons = Array.isArray(payload.polygons) ? payload.polygons : null;
  if (!polygons || polygons.length === 0) return;

  const layers = [];
  for (const ring of polygons) {
    if (!Array.isArray(ring) || ring.length < 3) continue;
    // Leaflet polygon expects [lat, lng] = [worldY, worldX].
    const latlngs = [];
    for (const pt of ring) {
      if (!Array.isArray(pt) || pt.length < 2) continue;
      const x = pt[0], y = pt[1];
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
      latlngs.push([y, x]);
    }
    if (latlngs.length < 3) continue;
    layers.push(window.L.polygon(latlngs, {
      color: "#FFB454",
      weight: 2,
      fillColor: "#FFB454",
      fillOpacity: 0.18,
      interactive: false
    }));
  }
  if (layers.length === 0) return;

  buildLayer = window.L.layerGroup(layers).addTo(map);

  // Centroid label so the user knows what's selected without hovering.
  const cx = Number.isFinite(payload.cx) ? payload.cx : null;
  const cy = Number.isFinite(payload.cy) ? payload.cy : null;
  if (cx !== null && cy !== null) {
    const label = window.L.marker(window.L.latLng(cy, cx), {
      icon: window.L.divIcon({
        className: "",
        html: `<div class="build-label">${escapeHtml(payload.name || "")}<\/div>`,
        iconSize: [120, 18],
        iconAnchor: [60, 9]
      }),
      interactive: false,
      keyboard: false
    });
    label.addTo(buildLayer);
  }
}

function clearBuild() {
  if (buildLayer && map) {
    map.removeLayer(buildLayer);
  }
  buildLayer = null;
}

// Phase 2 / Slice A: live preview of Modify Delivery transforms.
// Same polygon shape as `build` but rendered in cyan to distinguish
// from the source outline. Cleared when the dialog closes.
function setBuildPreview(payload) {
  if (!map) return;
  if (IS_MINIMAP) return;
  clearBuildPreview();

  const polygons = Array.isArray(payload.polygons) ? payload.polygons : null;
  if (!polygons || polygons.length === 0) return;

  const layers = [];
  for (const ring of polygons) {
    if (!Array.isArray(ring) || ring.length < 3) continue;
    const latlngs = [];
    for (const pt of ring) {
      if (!Array.isArray(pt) || pt.length < 2) continue;
      const x = pt[0], y = pt[1];
      if (!Number.isFinite(x) || !Number.isFinite(y)) continue;
      latlngs.push([y, x]);
    }
    if (latlngs.length < 3) continue;
    layers.push(window.L.polygon(latlngs, {
      color: "#3DDBD9",
      weight: 2,
      dashArray: "4 3",
      fillColor: "#3DDBD9",
      fillOpacity: 0.15,
      interactive: false
    }));
  }
  if (layers.length === 0) return;
  previewLayer = window.L.layerGroup(layers).addTo(map);
}

function clearBuildPreview() {
  if (previewLayer && map) {
    map.removeLayer(previewLayer);
  }
  previewLayer = null;
}

// ---------------------------------------------------------------
// Modify Delivery (interactive map placement)
// ---------------------------------------------------------------
//
// In modify mode the host posts {type:"modifyInit", polygons, cx, cy}
// once the dialog has snapshot data ready. We render a draggable +
// rotatable cyan outline over the (locked, follows-player) map. Each
// drag/rotate posts {type:"modifyState", dx, dy, yaw} back so the host
// always has the latest transform without polling.
//
// All math operates on the original polygon vertices ; the displayed
// shape is recomputed from scratch each frame as:
//   p' = R(yaw) * (p - centroid) + centroid + (dx, dy)

function setModifyInit(payload) {
  if (!IS_MODIFY || !map) return;
  const polygons = Array.isArray(payload.polygons) ? payload.polygons : null;
  if (!polygons || polygons.length === 0) return;

  // Deep-copy the polygons so later transforms can't mutate the source.
  MODIFY.polygons = polygons.map(ring => ring.map(([x, y]) => [x, y]));
  MODIFY.cx = Number.isFinite(payload.cx) ? payload.cx : 0;
  MODIFY.cy = Number.isFinite(payload.cy) ? payload.cy : 0;
  MODIFY.yaw = 0;

  if (lastPlayer) {
    MODIFY.dx = lastPlayer.x - MODIFY.cx;
    MODIFY.dy = lastPlayer.y - MODIFY.cy;
    MODIFY.initialized = true;
  } else {
    // No player yet ; show at the source location until we get one.
    MODIFY.dx = 0;
    MODIFY.dy = 0;
    MODIFY.initialized = false;
  }
  redrawModify();
  postModifyState();
}

function modifyResetToPlayer() {
  if (!IS_MODIFY) return;
  MODIFY.yaw = 0;
  if (lastPlayer) {
    MODIFY.dx = lastPlayer.x - MODIFY.cx;
    MODIFY.dy = lastPlayer.y - MODIFY.cy;
    MODIFY.initialized = true;
  } else {
    MODIFY.dx = 0;
    MODIFY.dy = 0;
  }
  redrawModify();
  postModifyState();
}

// Snap the preview back to its source coordinates (dx=0, dy=0, yaw=0)
// so the user can see where the build sits in the .json. The map view
// stays where it is ; if the original location is off-screen the user
// uses Center to Player to bring the preview back into view.
function modifyResetToOriginal() {
  if (!IS_MODIFY) return;
  MODIFY.dx = 0;
  MODIFY.dy = 0;
  MODIFY.yaw = 0;
  MODIFY.initialized = true;
  redrawModify();
  postModifyState();
}

function transformedPolygons() {
  const cosA = Math.cos(MODIFY.yaw * Math.PI / 180);
  const sinA = Math.sin(MODIFY.yaw * Math.PI / 180);
  const cx = MODIFY.cx, cy = MODIFY.cy, dx = MODIFY.dx, dy = MODIFY.dy;
  return MODIFY.polygons.map(ring =>
    ring.map(([x, y]) => {
      const rx = x - cx, ry = y - cy;
      const nx = cx + rx * cosA - ry * sinA + dx;
      const ny = cy + rx * sinA + ry * cosA + dy;
      return [nx, ny];
    })
  );
}

function redrawModify() {
  try {
    _redrawModifyImpl();
  } catch (e) {
    postToHost({ type: "log", message: `redrawModify threw: ${e && e.message} | ${(e && e.stack || "").split("\n").slice(0, 3).join(" | ")}` });
  }
}

function _redrawModifyImpl() {
  if (!IS_MODIFY || !map) return;
  const size = map.getSize();
  if (size.x === 0 || size.y === 0) {
    map.invalidateSize();
    return;
  }
  if (MODIFY.layer) {
    map.removeLayer(MODIFY.layer);
    MODIFY.layer = null;
  }
  if (MODIFY.centroidMarker) {
    map.removeLayer(MODIFY.centroidMarker);
    MODIFY.centroidMarker = null;
  }
  if (MODIFY.polygons.length === 0) return;

  const polys = transformedPolygons();
  const layers = polys.map(ring => {
    const latlngs = ring.map(([x, y]) => [y, x]);
    const poly = window.L.polygon(latlngs, {
      color: "#3DDBD9",
      weight: 2,
      fillColor: "#3DDBD9",
      fillOpacity: 0.25,
      bubblingMouseEvents: false
    });
    poly.on("mousedown", onModifyMouseDown);
    return poly;
  });
  MODIFY.layer = window.L.layerGroup(layers).addTo(map);

  // Centroid pip so the user sees the rotation pivot.
  const centroidLatLng = window.L.latLng(MODIFY.cy + MODIFY.dy, MODIFY.cx + MODIFY.dx);
  MODIFY.centroidMarker = window.L.circleMarker(centroidLatLng, {
    radius: 4,
    color: "#3DDBD9",
    weight: 2,
    fillColor: "#FFFFFF",
    fillOpacity: 1,
    interactive: false
  }).addTo(map);
}

function onModifyMouseDown(ev) {
  if (!IS_MODIFY || !map) return;
  if (ev.originalEvent) {
    ev.originalEvent.preventDefault();
    ev.originalEvent.stopPropagation();
  }
  const startLatLng = ev.latlng;
  const startDx = MODIFY.dx;
  const startDy = MODIFY.dy;

  function onMove(e) {
    const dlng = e.latlng.lng - startLatLng.lng; // X
    const dlat = e.latlng.lat - startLatLng.lat; // Y
    MODIFY.dx = startDx + dlng;
    MODIFY.dy = startDy + dlat;
    redrawModify();
  }
  function onUp() {
    map.off("mousemove", onMove);
    map.off("mouseup", onUp);
    document.removeEventListener("mouseup", onUp, true);
    postModifyState();
  }
  map.on("mousemove", onMove);
  map.on("mouseup", onUp);
  // Mouse-up can land outside the map container if the user drags fast.
  document.addEventListener("mouseup", onUp, true);
}

function wireModifyWheel() {
  if (!IS_MODIFY || !map) return;
  const container = map.getContainer();
  container.addEventListener("wheel", (ev) => {
    ev.preventDefault();
    ev.stopPropagation();
    const baseStep = ev.shiftKey ? 1 : 5;
    const step = ev.deltaY > 0 ? baseStep : -baseStep;
    MODIFY.yaw = (MODIFY.yaw + step) % 360;
    if (MODIFY.yaw < 0) MODIFY.yaw += 360;
    redrawModify();
    postModifyState();
  }, { passive: false });
}

function postModifyState() {
  if (!IS_MODIFY) return;
  postToHost({
    type: "modifyState",
    dx: MODIFY.dx,
    dy: MODIFY.dy,
    yaw: MODIFY.yaw
  });
}

function escapeHtml(s) {
  return String(s)
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}

function handleHostMessage(raw) {
  let payload;
  try {
    payload = JSON.parse(raw);
  } catch (e) {
    postToHost({ type: "log", message: `bad JSON from host: ${e}` });
    return;
  }
  if (!payload || typeof payload !== "object") return;
  switch (payload.type) {
    case "player":
      setPlayer(payload.x, payload.y, payload.z, payload.yaw);
      break;
    case "clearPlayer":
      clearPlayer();
      break;
    case "players":
      setRemotePlayers(payload.players);
      break;
    case "clearPlayers":
      clearRemotePlayers();
      break;
    case "build":
      setBuild(payload);
      break;
    case "clearBuild":
      clearBuild();
      break;
    case "buildPreview":
      setBuildPreview(payload);
      break;
    case "clearBuildPreview":
      clearBuildPreview();
      break;
    case "modifyInit":
      setModifyInit(payload);
      break;
    case "modifyReset":
      modifyResetToPlayer();
      break;
    case "modifyOriginal":
      modifyResetToOriginal();
      break;
    case "status":
      if (typeof payload.message === "string") setStatus(payload.message);
      break;
    case "locationDataPresence":
    case "locationDataReady":
    case "locationDataStatus":
    case "locationOverlayState":
      // Delegate to the actor-pin overlay if it has been mounted.
      // Both panel-bearing and headless (minimap) overlays subscribe ;
      // the overlay decides per type whether to load data, render, or
      // sync UI state across instances.
      if (window.LocationMapOverlay && typeof window.LocationMapOverlay.onHostMessage === "function") {
        window.LocationMapOverlay.onHostMessage(payload);
      }
      break;
    default:
      break;
  }
}

function wireHostBridge() {
  if (window.chrome && window.chrome.webview) {
    window.chrome.webview.addEventListener("message", (ev) => {
      const raw = typeof ev.data === "string" ? ev.data : JSON.stringify(ev.data);
      handleHostMessage(raw);
    });
  }
}

// Phase 2 / Slice B: right-click anywhere on the map to place the
// currently-selected build at that world point. We render a tiny
// floating menu so the action is discoverable ; clicking the item
// posts {placeBuild, x, y} to the host which then writes a translated
// .json copy and offers to deliver it. Minimap surface skips this so
// HUD-mode stays passive.
function wireContextMenu() {
  if (IS_MINIMAP || IS_MODIFY || !map) return;

  // Suppress the default Leaflet contextmenu entirely so our custom
  // floating div is the only response.
  map.on("contextmenu", (ev) => {
    if (ev.originalEvent) {
      ev.originalEvent.preventDefault();
      ev.originalEvent.stopPropagation();
    }
    showContextMenu(ev.containerPoint, ev.latlng);
  });

  // Click anywhere else dismisses the menu.
  document.addEventListener("click", hideContextMenu, true);
  window.addEventListener("resize", hideContextMenu);
  map.on("movestart zoomstart", hideContextMenu);
}

let _ctxMenuEl = null;
function showContextMenu(point, latlng) {
  hideContextMenu();
  const worldX = latlng.lng;
  const worldY = latlng.lat;

  // Try to snap to the nearest known actor location regardless of which
  // categories are currently visible. Falls back to the raw click point
  // if no pin data is loaded.
  let snap = null;
  try {
    if (window.LocationMapOverlay && typeof window.LocationMapOverlay.findNearestPoint === "function") {
      snap = window.LocationMapOverlay.findNearestPoint(worldX, worldY);
    }
  } catch (_) { /* nearest is best-effort */ }

  const tx = snap ? snap.point.x : worldX;
  const ty = snap ? snap.point.y : worldY;
  const tz = snap ? snap.point.z : null;
  const labelLine = snap
    ? `Nearest: ${snap.leafLabel} - ${snap.point.name || "(unnamed)"} (${Math.round(snap.distance)}u away)`
    : "No pin data loaded ; teleport will use raw cursor X/Y.";

  const el = document.createElement("div");
  el.className = "map-ctx-menu";
  el.style.cssText = `position:absolute;left:${point.x}px;top:${point.y}px;z-index:2000;`;
  el.innerHTML = `
    <div class="map-ctx-coords">X=${Math.round(tx)} Y=${Math.round(ty)}${tz != null ? ` Z=${Math.round(tz)}` : ""}</div>
    <div class="map-ctx-coords" style="opacity:0.75;font-size:10px;max-width:240px;white-space:normal;">${labelLine}</div>
    <button type="button" class="map-ctx-item" data-action="teleport">Teleport here</button>
  `;
  el.addEventListener("click", (e) => {
    const target = e.target;
    if (target && target.dataset && target.dataset.action === "teleport") {
      e.stopPropagation();
      postToHost({
        type: "teleport",
        x: tx, y: ty, z: tz,
        name: snap ? (snap.point.name || snap.leafLabel) : null,
        source: snap ? "nearest" : "raw"
      });
      hideContextMenu();
    }
  });
  document.body.appendChild(el);
  _ctxMenuEl = el;
}

function hideContextMenu() {
  if (_ctxMenuEl && _ctxMenuEl.parentNode) {
    _ctxMenuEl.parentNode.removeChild(_ctxMenuEl);
  }
  _ctxMenuEl = null;
}

function init() {
  if (!mapEl || typeof window.L === "undefined") {
    setStatus("Leaflet failed to load (no internet?).");
    postToHost({ type: "log", message: "Leaflet missing" });
    return;
  }
  try {
    map = createDragonwildsMap(mapEl);
    setStatus("Map ready. Waiting for player position...");
    wireHostBridge();
    wireContextMenu();
    wireModifyWheel();
    // Mount the actor-pin overlay on every surface except Modify (delivery
    // placement HUD has its own controls and shouldn't be cluttered).
    // The minimap mounts headless ; selections are driven from the
    // embedded/full maps and synced across instances by the host.
    if (!IS_MODIFY && window.LocationMapOverlay && typeof window.LocationMapOverlay.mount === "function") {
      try {
        window.LocationMapOverlay.mount({
          map,
          gameXYToLatLng: (x, y) => window.L.latLng(y, x),
          postToHost,
          mode: MODE,
          headless: IS_MINIMAP
        });
      } catch (e) {
        postToHost({ type: "log", message: `overlay mount failed: ${e}` });
      }
    }
    postToHost({ type: "ready" });

    // WebView2 lays out the host control after our scripts run, so the
    // map is created with size 0 ; defer fitBounds until next frame.
    requestAnimationFrame(fitWorld);
    window.addEventListener("resize", fitWorld);
    // Modify dialog (and any future hosts) may resize the WebView2 well
    // after page load. A ResizeObserver guarantees we invalidateSize
    // every time the container actually changes size, including the
    // initial 0 -> real-size transition that breaks Leaflet's SVG
    // renderer otherwise.
    if (typeof ResizeObserver !== "undefined") {
      const ro = new ResizeObserver(() => {
        if (!map) return;
        const r = mapEl.getBoundingClientRect();
        if (r.width > 0 && r.height > 0) {
          map.invalidateSize();
          // Re-snap locked HUDs to the player on every resize so the
          // dot stays centered after the dialog finishes laying out.
          if (IS_LOCKED && lastPlayer) {
            map.setView(window.L.latLng(lastPlayer.y, lastPlayer.x), map.getZoom(), { animate: false });
          }
        }
      });
      ro.observe(mapEl);
    }
  } catch (err) {
    setStatus(`Map init failed: ${err && err.message ? err.message : err}`);
    postToHost({ type: "log", message: `init err: ${err}` });
  }
}

if (document.readyState === "loading") {
  document.addEventListener("DOMContentLoaded", init);
} else {
  init();
}
