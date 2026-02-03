import {
  BufferUtils,
  Constants,
  Packet,
  WebBleConnection
} from "/content/mc/index.js";
import BufferReader from "/content/mc/buffer_reader.js";
import {
  aes,
  ageInDays,
  centerPos,
  fadeColor,
  geo,
  geohash6,
  geohash8,
  getPathEntry,
  isValidLocation,
  isValidRssi,
  maxDistanceMiles,
  posFromHash
} from "/content/shared.js";

// --- DOM helpers ---
const $ = id => document.getElementById(id);
const statusEl = $("status");
const deviceInfoEl = $("deviceInfo");
const ignoredRepeaterId = $("ignoredRepeaterId");
const sendRadioNameCB = $("sendRadioNameCB");

const connectBtn = $("connectBtn");
const sendPingBtn = $("sendPingBtn");
const autoToggleBtn = $("autoToggleBtn");
const ignoredRepeaterBtn = $("ignoredRepeaterBtn");
const logoGlowEl = $("logoGlow");
const logoBrightEl = $("logoBright");

// Channel key is derived from the channel hashtag.
// Channel hash is derived from the channel key.
// If you change the channel name, these must be recomputed.
const wardriveChannelHash = parseInt("e0", 16);
const wardriveChannelKey = BufferUtils.hexToBytes("4076c315c1ef385fa93f066027320fe5");
const wardriveChannelName = "#wardrive";
const refreshTileAge = 1; // Tiles older than this (days) will get pinged again.

// --- Global Init ---
// Map setup
const utf8decoder = new TextDecoder(); // default 'utf-8'
const repeatEmitter = new EventTarget();
const map = L.map('map', {
  worldCopyJump: true,
  dragging: true,
  scrollWheelZoom: true,
  touchZoom: true,
  boxZoom: false,
  keyboard: false,
  tap: false,
  zoomControl: false,
  doubleClickZoom: false
}).setView(centerPos, 12);

L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', {
  maxZoom: 15,
  minZoom: 8,
  attribution: '© OpenStreetMap contributors'
}).addTo(map);

// Map layers
const pingLayer = L.layerGroup().addTo(map);
const coverageLayer = L.layerGroup().addTo(map);
const currentLocMarker = L.circleMarker([0, 0], {
  radius: 6,
  weight: 2,
  color: "white",
  fillColor: "#69DBFE",
  fillOpacity: .9,
  className: "marker-shadow",
  pane: "tooltipPane",
  interactive: false
}).addTo(map);

// Max radius circle.
L.circle(centerPos, {
  radius: maxDistanceMiles * 1609.34, // meters in mile.
  color: '#a13139',
  weight: 3,
  fill: false
}).addTo(map);

// Map controls
const mapControl = L.control({ position: 'bottomleft' });
mapControl.onAdd = m => {
  const div = L.DomUtil.create('div', 'leaflet-control');
  div.innerHTML = `
    <div class="flex items-center gap-3">
      <button class="px-2 py-1.5 rounded-lg bg-sky-600 hover:bg-sky-500 text-md font-medium shadow-sm" id="followBtn">🧭</button>
      <button class="px-2 py-1.5 rounded-lg bg-orange-100 hover:bg-orange-300 text-md font-medium shadow-sm" id="clearBtn">🗑️</button>
    </div>
  `;

  div.querySelector("#followBtn")
    .addEventListener("click", () => {
      state.following = !state.following;
      updateFollowButton();
    });

  div.querySelector("#clearBtn")
    .addEventListener("click", () => {
      if (confirm("Clear ping history?")) {
        pingLayer.clearLayers();
        state.pings = [];
        savePingHistory();
      }
    });

  // Don’t let clicks on the control bubble up and pan/zoom the map.
  L.DomEvent.disableClickPropagation(div);
  L.DomEvent.disableScrollPropagation(div);

  return div;
};
mapControl.addTo(map);

// Stop following if the user interacts with the map.
map.on("mousedown touchstart wheel dragstart", () => {
  state.following = false;
  updateFollowButton();
});

// Use to return UI thread to allow layout/paint.
const nextPaint = () => new Promise(requestAnimationFrame);

// --- Versioning ---
const pageLoaded = Date.now();

async function ensureLatestVersion() {
  try {
    const resp = await fetch("/version", { cache: "no-store" });
    const { latest } = await resp.json();

    // Was the page loaded after the latest version?
    if (latest < pageLoaded)
      return;

    alert("A new version is available. Reloading...");
    location.reload();
  } catch (e) {
    console.error("Failed to fetch version info", e);
  }
}

// --- Logging ---
function setStatus(text, color = null) {
  statusEl.textContent = text;
  log(`status: ${text}`);
  statusEl.className = "font-semibold " + (color ?? "");
}

function log(msg) {
  console.log(msg);
}

// --- State ---
const PING_HISTORY_ID_KEY = "meshcoreWardrivePingHistoryV1"
const IGNORED_ID_KEY = "meshcoreWardriveIgnoredIdV1"
const SETTINGS_ID_KEY = "meshcoreWardriveSettingsV1"

const state = {
  connection: null,
  radioName: null,
  wardriveChannel: null,
  running: false,
  autoTimerId: null,
  wakeLock: null,
  ignoredId: null, // Allows a repeater to be ignored.
  sendRadioName: false,
  pings: [],
  rxHistory: [],
  tiles: new Map(),
  following: true,
  locationTimer: null,
  lastPosUpdate: 0, // Timestamp of last location update.
  currentPos: [0, 0],
};

// --- Coverage Functions ---
function mergeCoverage(id, value) {
  const prev = state.tiles.get(id);

  if (!prev) {
    state.tiles.set(id, value);
    return;
  }

  // o is 0|1 for "observed" -- prefer observed.
  // h is 0|1 for "heard" -- prefer heard.
  // a is "age in days" -- prefer newest.
  prev.o = Math.max(value.o, prev.o);
  prev.h = Math.max(value.h, prev.h);
  prev.a = Math.min(value.a, prev.a);
}

async function refreshCoverage() {
  try {
    let url = "/get-wardrive-coverage";
    const resp = await fetch(url);
    const coverage = (await resp.json()) ?? [];
    log(`Got ${coverage.length} coverage tiles from service.`);
    coverage.forEach(([id, val]) => mergeCoverage(id, val));
  } catch (e) {
    console.error("Getting coverage failed", e);
    setStatus("Get coverage failed", "text-red-300");
  }
}

function getCoverageBoxMarker(tileId, info) {
  function getMarkerColor(info) {
    if (info.o)
      return '#398821' // Observed - Green
    if (info.h)
      return '#FEAA2C' // Repeated - Orange
    return '#E04748' // Miss - Red
  }

  const [minLat, minLon, maxLat, maxLon] = geo.decode_bbox(tileId);
  const color = getMarkerColor(info);
  const fresh = info.a <= refreshTileAge;
  const fillColor = fresh ? color : fadeColor(color, .4);

  const style = {
    color: color,
    opacity: 0.6,
    weight: 1,
    fillColor: fillColor,
    fillOpacity: 0.6,
    pane: "overlayPane",
    interactive: false
  };
  return L.rectangle([[minLat, minLon], [maxLat, maxLon]], style);
}

function addCoverageBox(tileId) {
  const info = state.tiles.get(tileId);

  // Remove the existing marker, if any.
  if (info.marker) {
    coverageLayer.removeLayer(info.marker);
  }

  info.marker = getCoverageBoxMarker(tileId, info);
  coverageLayer.addLayer(info.marker);
}

function redrawCoverage() {
  coverageLayer.clearLayers();
  state.tiles.keys().forEach(addCoverageBox);
}

// --- Ping markers ---
async function getSample(sampleId) {
  try {
    let url = `/get-samples?p=${sampleId}`;
    const resp = await fetch(url);
    const samples = (await resp.json()) ?? [];
    log(`Got ${samples.length} samples from service.`);
    return samples[0]; // May return undefined.
  } catch (e) {
    console.error("Getting sample failed", e);
    setStatus("Get sample failed", "text-red-300");
  }
}

function loadPingHistory() {
  try {
    state.pings = [];
    const data = localStorage.getItem(PING_HISTORY_ID_KEY);
    state.pings = JSON.parse(data || '[]');
  } catch (e) {
    console.warn("Failed to load ping history", e);
  }
}

function savePingHistory() {
  try {
    localStorage.setItem(PING_HISTORY_ID_KEY, JSON.stringify(state.pings));
  } catch (e) {
    console.warn("Failed to save ping history", e);
  }
}

function addPingHistory(ping) {
  // Don't add new pings of the same type at the same location.
  const existing = state.pings.find(
    p => p.hash == ping.hash && p.rxLog === ping.rxLog);
  if (existing)
    return;

  addPingMarker(ping);
  state.pings.push(ping);
  savePingHistory();
}

function addPingMarker(ping) {
  function getPingColor(p) {
    if (p.rxLog)
      return '#A126C3' // RxLog - Violet
    if (p.observed)
      return '#398821' // Observed - Green
    if (p.heard)
      return '#FEAA2C' // Repeated - Orange
    else
      return '#E04748' // Miss - Red
  }

  const pos = posFromHash(ping.hash);
  const pingMarker = L.circleMarker(pos, {
    radius: ping.rxLog ? 3 : 4, // Smaller RxLog pings.
    weight: 0.75,
    color: "white",
    fillColor: getPingColor(ping),
    fillOpacity: 1,
    pane: "markerPane",
    className: "marker-shadow",
    interactive: false
  });
  pingMarker.ping = ping;
  pingLayer.addLayer(pingMarker);
}

function redrawPingHistory() {
  pingLayer.clearLayers();
  state.pings.forEach(addPingMarker);
}

// --- Saved Settings ---
// One-time migration to new settings object.
function migrateSettings() {
  try {
    const id = localStorage.getItem(IGNORED_ID_KEY);
    if (id) {
      state.ignoredId = id;
    }
    saveSettings();
    localStorage.removeItem(IGNORED_ID_KEY);
  } catch (e) {
    console.warn("Failed to migrate ignored id", e);
  }
}

function loadSettings() {
  try {
    let settingsStr = localStorage.getItem(SETTINGS_ID_KEY);

    if (settingsStr === null) {
      migrateSettings();
      settingsStr = localStorage.getItem(SETTINGS_ID_KEY);
    }
    const settings = JSON.parse(settingsStr)
    state.ignoredId = settings.ignoredId ?? null;
    state.sendRadioName = settings.sendRadioName ?? false;
    refreshSettingsUI();
  } catch (e) {
    console.warn("Failed to load settings", e);
    localStorage.removeItem(SETTINGS_ID_KEY);
  }
}

function saveSettings() {
  const settings = {
    ignoredId: state.ignoredId,
    sendRadioName: state.sendRadioName
  };

  localStorage.setItem(SETTINGS_ID_KEY, JSON.stringify(settings));
}

function refreshSettingsUI() {
  ignoredRepeaterId.innerText = state.ignoredId ?? "<none>";
  sendRadioNameCB.checked = state.sendRadioName;
}

// --- Ignored Id ---
function promptIgnoredId() {
  const id = prompt("Enter repeater id to ignore.", state.ignoredId ?? '');

  // Was prompt cancelled?
  if (id === null)
    return;

  if (id && id.length !== 2) {
    alert(`Invalid id '${id}'. Must be 2 hex digits.`);
    return;
  }

  state.ignoredId = id ? id.toLowerCase() : null;
  saveSettings();
  refreshSettingsUI();
}

// --- Geolocation ---
async function startLocationTracking() {
  stopLocationTracking();
  await updateCurrentPosition(); // Run immediately, then on timer.
  state.locationTimer = setInterval(updateCurrentPosition, 1000);
}

function stopLocationTracking() {
  if (state.locationTimer) {
    clearInterval(state.locationTimer);
    state.locationTimer = null;
  }
}

async function updateCurrentPosition() {
  const pos = await getCurrentPosition();
  const lat = pos.coords.latitude;
  const lon = pos.coords.longitude;
  state.currentPos = [lat, lon];

  currentLocMarker.setLatLng(state.currentPos);

  if (state.following)
    map.panTo(state.currentPos);

  state.lastPosUpdate = Date.now();
}

function getCurrentPosition() {
  return new Promise((resolve, reject) => {
    if (!("geolocation" in navigator)) {
      reject(new Error("Geolocation is not available in this browser"));
      return;
    }
    navigator.geolocation.getCurrentPosition(
      (pos) => resolve(pos),
      (err) => reject(err),
      {
        enableHighAccuracy: true,
        maximumAge: 1000,
        timeout: 5000,
      }
    );
  });
}

// Helper to ensure the location tracking timer stays running.
async function ensureCurrentPositionIsFresh() {
  const dt = Date.now() - state.lastPosUpdate;
  if (dt > 3000) {
    await startLocationTracking();
  }
}

// --- WakeLock ---
async function acquireWakeLock() {
  // Bluefy-specfic -- it's a bit better when available.
  if ('setScreenDimEnabled' in navigator.bluetooth) {
    // This name is bad. setScreenDimEnabled(true) prevents screen locking.
    navigator.bluetooth.setScreenDimEnabled(true);
    log('setScreenDimEnabled(true)');
  } else {
    try {
      if ('wakeLock' in navigator) {
        state.wakeLock = await navigator.wakeLock.request('screen');
        log('navigator.wakeLock acquired');

        state.wakeLock.addEventListener('release',
          () => log('navigator.wakeLock released'));

      } else {
        log('navigator.wakeLock not supported');
      }
    } catch (err) {
      console.error(`Could not obtain wake lock: ${err.name}, ${err.message}`);
    }
  }
}

async function releaseWakeLock() {
  if ('setScreenDimEnabled' in navigator.bluetooth) {
    navigator.bluetooth.setScreenDimEnabled(false);
    log('setScreenDimEnabled(false)');
  } else {
    if (state.wakeLock !== null) {
      state.wakeLock.release();
      state.wakeLock = null;
    }
  }
}

// --- Wardrive channel ---
async function createWardriveChannel() {
  const create = window.confirm(
    `Channel "${wardriveChannelName}" not found on this device. Create it now?`
  );

  if (!create) {
    throw new Error("Wardrive channel not found");
  }

  // Find a free channel index.
  const channels = await state.connection.getChannels();
  let idx = 0;
  while (idx < channels.length) {
    if (channels[idx].name === '')
      break;
    ++idx;
  }

  if (idx >= channels.length) {
    throw new Error("No free channel slots available");
  }

  // Create and set the connection.
  const channel = { channelIdx: idx, name: wardriveChannelName, wardriveChannelKey };
  await state.connection.setChannel(idx, wardriveChannelName, wardriveChannelKey);
  return channel;
}

async function ensureWardriveChannel() {
  if (!state.connection) {
    throw new Error("Not connected");
  }

  if (state.wardriveChannel) {
    return state.wardriveChannel;
  }

  // Look for existing channel by name.
  let channel = await state.connection.findChannelByName(wardriveChannelName);

  if (!channel) {
    channel = await createWardriveChannel();
  }

  deviceInfoEl.textContent += ` CH:${channel.channelIdx}`;
  state.wardriveChannel = channel;
  return channel;
}

// --- Ping logic ---
async function listenForRepeat(message, timeoutMs) {
  return new Promise((resolve, reject) => {
    const on = e => {
      const detail = e.detail;
      if (detail.text?.endsWith(message)) {
        cleanup();
        resolve(detail);
      } else {
        log(`Ignored repeat ${JSON.stringify(detail)}`);
      }
    };

    const timeout = setTimeout(() => {
      cleanup();
      reject(new Error("timeout"));
    }, timeoutMs)

    function cleanup() {
      repeatEmitter.removeEventListener("repeat", on);
      if (timeout) clearTimeout(timeout);
    }

    repeatEmitter.addEventListener("repeat", on);
  });
}

async function sendPing({ auto = false } = {}) {
  if (!state.connection) {
    setStatus("Not connected", "text-red-300");
    return;
  }

  if (!state.channel) {
    try {
      state.channel = await ensureWardriveChannel();
    } catch (e) {
      console.warn(`Channel "${wardriveChannelName}" not available`, e);
      setStatus(`No "${wardriveChannelName}" channel`, "text-amber-300");
      return;
    }
  }

  try {
    await ensureCurrentPositionIsFresh();
  } catch (e) {
    console.error("Get location failed", e);
    setStatus("Get location failed", "text-amber-300");
    return;
  }

  let pos = state.currentPos;
  if (!isValidLocation(pos)) {
    setStatus("Outside coverage area", "text-red-300");
    return;
  }

  // Until everything is migrated to use has everywhere,
  // make sure the lat/lon in the ping is derived from the hash.
  const [rawLat, rawLon] = pos;
  const sampleId = geohash8(rawLat, rawLon);
  const tileId = sampleId.substring(0, 6);
  const [lat, lon] = posFromHash(sampleId);

  // A Ping is needed in the current tile if the tile
  // is missing an entry or the entry is old.
  const info = state.tiles.get(tileId);
  const needsPing = !info || info.a > refreshTileAge;
  if (auto && !needsPing) {
    setStatus("No ping needed", "text-amber-300");
    return;
  }

  // TODO: just send the sample geohash.
  let text = `${lat.toFixed(4)} ${lon.toFixed(4)}`;
  if (state.ignoredId !== null) text += ` ${state.ignoredId}`;

  try {
    // Send mesh message: "<lat> <lon> [<id>]".
    await state.connection.sendChannelTextMessage(state.channel.channelIdx, text);
    log("Sent MeshCore wardrive ping:", text);
    setStatus(auto ? "Auto ping sent" : "Ping sent", "text-emerald-300");
  } catch (e) {
    console.error("Mesh send failed", e);
    setStatus("Mesh send failed", "text-red-300");
    return;
  }

  let repeat = null;
  try {
    // Wait at most 2 seconds for a repeat.
    repeat = await listenForRepeat(text, 2000);
    log(`Heard repeat from ${repeat.repeater}`);
  } catch {
    log("Didn't hear a repeat in time, assuming lost.");
  }

  // Send sample to service.
  try {
    const data = { lat, lon };
    if (repeat) {
      data.path = [repeat.repeater];
      if (repeat.shouldSendRxStats) {
        data.snr = repeat.lastSnr;
        data.rssi = repeat.lastRssi;
      }
    }

    if (state.sendRadioName) {
      data.sender = state.radioName;
    }

    await fetch("/put-sample", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(data),
    });
  } catch (e) {
    console.error("Service POST failed", e);
    setStatus("Web send failed", "text-red-300");
  }

  // Update the tile state immediately.
  // Set "age" to the cutoff so it stops getting pinged.
  const heard = repeat?.repeater !== undefined;
  mergeCoverage(tileId, { o: 0, h: heard ? 1 : 0, a: refreshTileAge });

  // Enqueue fetching the sample from the service to update the UI.
  // The mesh+MQTT+service can be pretty slow so give it a few seconds to process.
  setTimeout(async () => {
    const sample = await getSample(sampleId);
    const ping = { hash: sampleId };

    if (sample) {
      const repeaters = sample.repeaters;
      ping.observed = sample.observed;
      ping.heard = repeaters.length > 0;
      mergeCoverage(tileId, {
        o: ping.observed ? 1 : 0,
        h: ping.heard ? 1 : 0,
        a: ageInDays(sample.time)
      });
    }

    addCoverageBox(tileId);
    addPingHistory(ping);
  }, 2500);
}

// --- UI ---
function updateControlsForConnection(connected) {
  connectBtn.disabled = false;

  if (connected) {
    connectBtn.textContent = "Disconnect";
    connectBtn.classList.remove("bg-emerald-600", "hover:bg-emerald-500");
    connectBtn.classList.add("bg-red-600", "hover:bg-red-500");
    sendPingBtn.disabled = false;
    autoToggleBtn.disabled = false;
  } else {
    connectBtn.textContent = "Connect";
    connectBtn.classList.add("bg-emerald-600", "hover:bg-emerald-500");
    connectBtn.classList.remove("bg-red-600", "hover:bg-red-500");
    sendPingBtn.disabled = true;
    autoToggleBtn.disabled = true;
  }
}

function updateFollowButton() {
  const followBtn = $("followBtn");
  if (state.following) {
    followBtn.classList.remove("bg-zinc-600", "hover:bg-zinc-500");
    followBtn.classList.add("bg-sky-600", "hover:bg-sky-500");
  } else {
    followBtn.classList.add("bg-zinc-600", "hover:bg-zinc-500");
    followBtn.classList.remove("bg-sky-600", "hover:bg-sky-500");
  }
}

function updateAutoButton() {
  if (state.running) {
    autoToggleBtn.textContent = "Stop Auto Ping";
    autoToggleBtn.classList.remove("bg-indigo-600", "hover:bg-indigo-500");
    autoToggleBtn.classList.add("bg-amber-600", "hover:bg-amber-500");
  } else {
    autoToggleBtn.textContent = "Start Auto Ping";
    autoToggleBtn.classList.add("bg-indigo-600", "hover:bg-indigo-500");
    autoToggleBtn.classList.remove("bg-amber-600", "hover:bg-amber-500");
  }
}

// --- Auto mode ---
function stopAutoPing() {
  if (state.autoTimerId != null) {
    clearInterval(state.autoTimerId);
    state.autoTimerId = null;
  }
  state.running = false;
  updateAutoButton();
}

async function startAutoPing() {
  if (!state.connection) {
    alert("Connect to a MeshCore device first.");
    return;
  }

  stopAutoPing();

  state.running = true;
  updateAutoButton();

  await refreshCoverage();
  redrawCoverage();

  // Send first ping immediately, then on interval.
  let intervalMs = 10 * 1000;
  sendPing({ auto: true }).catch(console.error);
  state.autoTimerId = setInterval(() => {
    sendPing({ auto: true }).catch(console.error);
  }, intervalMs);
}

// --- Connection handling ---
async function handleConnect() {
  if (state.connection) {
    return;
  }

  await ensureLatestVersion();

  if (!("bluetooth" in navigator)) {
    alert("Web Bluetooth not supported in this browser.");
    return;
  }

  setStatus("Connecting…", "text-sky-300");
  connectBtn.disabled = true;

  try {
    const connection = await WebBleConnection.open();
    state.connection = connection;

    // Add handlers
    connection.on("connected", onConnected);
    connection.on("disconnected", onDisconnected);
    connection.on(Constants.PushCodes.LogRxData, onLogRxData);
  } catch (e) {
    console.error("Failed to open BLE connection", e);
    setStatus("Failed to connect", "text-red-300");
    updateControlsForConnection(false);
  }
}

async function handleDisconnect() {
  if (!state.connection) return;

  try {
    await state.connection.close();
  } catch (e) {
    console.warn("Error closing connection", e);
  }

  // NB: onDisconnected will be called from the BLE event.
}

async function onConnected() {
  setStatus("Connected (syncing…)", "text-emerald-300");

  try {
    try {
      await state.connection.syncDeviceTime();
    } catch {
      // Might not be supported.
    }

    const selfInfo = await state.connection.getSelfInfo();
    state.radioName = selfInfo?.name ?? null;
    deviceInfoEl.textContent = state.radioName ?? "[No device]";

    setStatus("Connected", "text-emerald-300");

    // Try to ensure channel exists.
    try {
      await ensureWardriveChannel();
    } catch {
      // Will attempt again on ping.
    }

    // Don't enable ping buttons until after ensure channel.
    updateControlsForConnection(true);
    await acquireWakeLock();
  } catch (e) {
    console.error("Error during initial sync", e);
    setStatus("Connected, Failed init", "text-amber-300");
    await handleDisconnect();
  }
}

function onDisconnected() {
  stopAutoPing();

  // Remove handlers
  state.connection.off("connected", onConnected);
  state.connection.off("disconnected", onDisconnected);
  state.connection.off(Constants.PushCodes.LogRxData, onLogRxData);

  deviceInfoEl.textContent = "";
  state.connection = null;
  state.wardriveChannel = null;

  updateControlsForConnection(false);
  setStatus("Disconnected", "text-red-300");
  releaseWakeLock();
}

// --- RX log handling ---
async function blinkRxLog() {
  logoGlowEl.style.opacity = 1;
  logoBrightEl.style.opacity = 1;

  // Wait for two render frames. Sometimes the browser
  // just does layout and returns before painting.
  await nextPaint();
  await nextPaint();

  setTimeout(() => {
    logoGlowEl.style.opacity = 0;
    logoBrightEl.style.opacity = 0;
  }, 300);
}

function pushRxHistory(key) {
  // Add and keep the most recent 10. This goal is to prevent the
  // client from spamming a single tile, but also allow it to
  // eventually submit new samples after moving or refreshing.
  state.rxHistory.push(key);
  state.rxHistory = state.rxHistory.slice(-10);
}

async function trySendRxSample(repeater, lastSnr, lastRssi) {
  try {
    await ensureCurrentPositionIsFresh();
  } catch (e) {
    console.error("RxSample: Get location failed", e);
    return;
  }

  // Get the current position and see if a
  // new sample is needed for this tile.
  const pos = state.currentPos;
  const [lat, lon] = pos;
  if (!isValidLocation(pos)) {
    log("RxSample: Outside coverage area");
    return;
  }

  // Track history per (tile hash, repeater id).
  // It's interesting to know all of the repeaters that can be heard in a tile.
  const hash = geohash6(lat, lon);
  const historyKey = `${hash}#${repeater}`;

  // Does this tile need a sample?
  if (state.rxHistory.includes(historyKey))
    return;

  // Send sample to service.
  try {
    const data = {
      hash: hash,
      info: {
        time: Date.now(),
        rssi: lastRssi,
        snr: lastSnr,
        repeater: repeater
      }
    };
    const dataStr = JSON.stringify(data);

    // TODO: add timeout, this is "best effort" and shouldn't block.
    log(`RxSample: sending ${dataStr}`);
    await fetch("/put-rx-sample", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: dataStr,
    });

    pushRxHistory(historyKey);
    addPingHistory({ hash: geohash8(lat, lon), rxLog: true });
  } catch (e) {
    console.error("RxSample: Service POST failed", e);
  }
}

async function onLogRxData(frame) {
  const lastSnr = frame.lastSnr;
  const lastRssi = frame.lastRssi;
  let hitMobileRepeater = false;
  const packet = Packet.fromBytes(frame.raw);
  const payloadType = packet.getPayloadType();

  // Ignore direct/zero-hop messages.
  if (!packet.isRouteFlood() || packet.path.length == 0)
    return;

  // Receiving these payloads is a decent proxy for hearing the mesh.
  // Adverts are iffy as a proxy, but it's a nice source of packets.
  if (payloadType != Packet.PAYLOAD_TYPE_GRP_TXT
    && payloadType != Packet.PAYLOAD_TYPE_TXT_MSG
    && payloadType != Packet.PAYLOAD_TYPE_ADVERT)
    return;

  // Try to get the last hop, ignoring mobile repeaters.
  let lastRepeater = getPathEntry(packet.path, -1);
  if (lastRepeater === state.ignoredId) {
    hitMobileRepeater = true;
    lastRepeater = getPathEntry(packet.path, -2);
  }

  // Is there a valid path?
  if (!lastRepeater)
    return;

  // If the mobile repeater wasn't hit and the RSSI is still too high,
  // that usually means there's another repeater *very* close by. Ignore
  // these packet so "heard" doesn't get polluted.
  if (!hitMobileRepeater && !isValidRssi(lastRssi))
    return;

  // The RX data is not interesting if someone is using a mobile repeater
  // because the last hop signal is always going to look really good.
  // NB: It's expected to have invalid RSSI when hitMobileRepeater is true.
  const shouldSendRxStats = !hitMobileRepeater;
  if (shouldSendRxStats) {
    await blinkRxLog();
    await trySendRxSample(lastRepeater, lastSnr, lastRssi);
  }

  // The rest of the code is only interested in message to #wardrive.
  if (payloadType != Packet.PAYLOAD_TYPE_GRP_TXT)
    return;

  const reader = new BufferReader(packet.payload);
  const groupHash = reader.readByte();
  const mac = reader.readBytes(2); // Validate?
  const encrypted = reader.readRemainingBytes();

  // Invalid data for AES.
  if (encrypted.length % 16 !== 0)
    return;

  // Definitely not to wardrive channel.
  if (groupHash !== wardriveChannelHash)
    return;

  // Probably for wardrive, give it a try.
  try {
    const aesEcb = new aes.ModeOfOperation.ecb(wardriveChannelKey);
    const decrypted = aesEcb.decrypt(encrypted);
    const msgReader = new BufferReader(decrypted);
    msgReader.readBytes(5); // Skip Timestamp and Flags, remove trailing null padding.
    const msgText = utf8decoder.decode(msgReader.readRemainingBytes()).replace(/\0/g, '');
    repeatEmitter.dispatchEvent(new CustomEvent("repeat", {
      detail: {
        repeater: lastRepeater,
        text: msgText,
        shouldSendRxStats,
        lastSnr,
        lastRssi
      }
    }));
  } catch (e) {
    log("Failed to decrypt message:", e);
  }
}

// --- Event bindings ---
connectBtn.addEventListener("click", () => {
  if (state.connection)
    handleDisconnect().catch(console.error);
  else
    handleConnect().catch(console.error);
});

sendPingBtn.addEventListener("click", () => {
  sendPing({ auto: false }).catch(console.error);
});

autoToggleBtn.addEventListener("click", async () => {
  if (state.running) {
    stopAutoPing();
    setStatus("Auto mode stopped", "text-slate-300");
  } else {
    await startAutoPing();
  }
});

ignoredRepeaterBtn.addEventListener("click", promptIgnoredId);

sendRadioNameCB.addEventListener("change", e => {
  state.sendRadioName = e.target.checked;
  saveSettings();
});

// Automatically release wake lock when the page is hidden.
document.addEventListener('visibilitychange', async () => {
  if (document.hidden) {
    releaseWakeLock();
    stopLocationTracking();
  } else {
    await startLocationTracking();

    if (state.connection)
      await acquireWakeLock();
  }
});

// Bluefy-specific.
if ('bluetooth' in navigator) {
  navigator.bluetooth.addEventListener('backgroundstatechanged',
    (e) => {
      const isBackground = e.target.value;
      if (isBackground == true && state.connection) {
        stopAutoPing();
        setStatus('Lost focus, Stopped', 'text-amber-300');
      }
    });
}

export async function onLoad() {
  try {
    loadSettings();
    loadPingHistory();
    updateControlsForConnection(false);
    updateAutoButton();
    redrawPingHistory();

    await refreshCoverage();
    redrawCoverage();

    await startLocationTracking();
  } catch (e) {
    const stack = e?.stack;
    alert(`${String(e)}${stack ? `\nStack: ${stack}` : ''}`);
 }
}
