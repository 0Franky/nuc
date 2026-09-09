// Nexus Universal Continuity - Service Worker Background Script (Manifest V3)

const DAEMON_WS_URL = "ws://127.0.0.1:28471/media";
const MAX_RETRIES = 5;
const BACKOFF_DELAYS_MS = [3000, 5000, 10000, 15000, 30000]; // 3s, 5s, 10s, 15s, 30s

let ws = null;
let retryCount = 0;
let reconnectTimeoutId = null;
let currentConnectionState = "IDLE"; // "IDLE" | "CONNECTING" | "CONNECTED" | "RETRYING" | "FAILED"
let lastMonitoredMedia = null;
let lastBroadcastMediaStr = "";
let lastErrorMessage = "";
let pingIntervalId = null;

// Multi-Tab Media Tracking & Audible History Engine
const tabMediaCache = new Map();
let lastAudibleTabId = null;
let lastAudibleTime = 0;
let lastPlayingTabId = null;
let lastPlayingTime = 0;

function logMsg(msg) {
  console.log(`[Nexus BG] ${msg}`);
  if (ws && ws.readyState === WebSocket.OPEN) {
    try {
      ws.send(JSON.stringify({ type: "EXTENSION_LOG", log: `[Background] ${msg}` }));
    } catch (_) {}
  }
}

// -------------------------------------------------------------
// Chrome Tabs & Windows Event Listeners for Audible & Focus
// -------------------------------------------------------------
// 1. Listen for tab audible changes (Chrome API: changeInfo.audible)
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (changeInfo.audible !== undefined) {
    if (changeInfo.audible === true) {
      lastAudibleTabId = tabId;
      lastAudibleTime = Date.now();
      logMsg(`Tab ${tabId} started playing audio: "${tab.title}" (${tab.url})`);
    }

    if (tabMediaCache.has(tabId)) {
      const entry = tabMediaCache.get(tabId);
      entry.is_audible = changeInfo.audible;
      if (changeInfo.audible) {
        entry.lastAudibleTime = Date.now();
      }
    }
    reevaluateAndBroadcast();
  }

  // Handle URL navigation away from video page
  if (changeInfo.status === "loading" && changeInfo.url) {
    if (tabMediaCache.has(tabId)) {
      const entry = tabMediaCache.get(tabId);
      if (entry.media_url !== changeInfo.url) {
        tabMediaCache.delete(tabId);
        if (lastPlayingTabId === tabId) lastPlayingTabId = null;
        if (lastAudibleTabId === tabId) lastAudibleTabId = null;
        reevaluateAndBroadcast();
      }
    }
  }
});

// 2. Clean up closed tabs
chrome.tabs.onRemoved.addListener((tabId) => {
  tabMediaCache.delete(tabId);
  if (lastAudibleTabId === tabId) lastAudibleTabId = null;
  if (lastPlayingTabId === tabId) lastPlayingTabId = null;
  reevaluateAndBroadcast();
});

// 3. Re-evaluate when user switches active tab
chrome.tabs.onActivated.addListener(() => {
  reevaluateAndBroadcast();
});

// 4. Re-evaluate when user focuses another window
chrome.windows.onFocusChanged.addListener((windowId) => {
  if (windowId !== chrome.windows.WINDOW_ID_NONE) {
    reevaluateAndBroadcast();
  }
});

// -------------------------------------------------------------
// Auto-Injection into existing tabs upon extension load/reload
// -------------------------------------------------------------
function injectIntoAllExistingTabs() {
  if (chrome.scripting && chrome.tabs) {
    chrome.tabs.query({}, (tabs) => {
      for (const tab of tabs) {
        if (tab.id && tab.url && (tab.url.startsWith("http://") || tab.url.startsWith("https://"))) {
          chrome.scripting
            .executeScript({
              target: { tabId: tab.id, allFrames: false },
              files: ["content_script.js"],
            })
            .then(() => {
              logMsg(`Auto-injected content_script into tab ${tab.id} (${tab.url})`);
            })
            .catch(() => {});
        }
      }
    });
  }
}

chrome.runtime.onInstalled.addListener(() => {
  logMsg("Extension installed/updated. Running auto-injection...");
  injectIntoAllExistingTabs();
});

// -------------------------------------------------------------
// Keep-Alive Connection from Content Scripts (Prevents MV3 sleep)
// -------------------------------------------------------------
const activePorts = new Set();
chrome.runtime.onConnect.addListener((port) => {
  if (port.name === "nexus_keepalive") {
    activePorts.add(port);
    port.onDisconnect.addListener(() => {
      activePorts.delete(port);
    });
  }
});

// -------------------------------------------------------------
// Media Arbitration Hierarchy Engine
// -------------------------------------------------------------
/**
 * Decision hierarchy:
 * 1. Check which video is currently in execution (is_playing: true).
 *    - 1a. If the active tab in the focused window is playing, prefer it immediately.
 *    - 1b. If any audible tab is playing, prefer the one that started playing most recently.
 *    - 1c. If any other tab has is_playing: true, pick the most recent.
 * 2. If no video is currently playing, check the LAST tab that played something (recency tracking).
 *    - 2a. Check lastAudibleTabId (tab that produced sound).
 *    - 2b. Check lastPlayingTabId.
 *    - 2c. Check any cached tab with playback within the last 15 minutes.
 * 3. Fallback on the active tab in the active window.
 */
async function selectBestMedia() {
  // Query active tab in the focused window
  let activeTab = null;
  try {
    const activeTabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true });
    if (activeTabs && activeTabs.length > 0) {
      activeTab = activeTabs[0];
    }
  } catch (_) {}

  // Query audible tabs
  let audibleTabs = [];
  try {
    audibleTabs = await chrome.tabs.query({ audible: true });
  } catch (_) {}
  const audibleTabIds = new Set(audibleTabs.map((t) => t.id));

  // --- STEP 1: Video currently in execution (is_playing: true) ---
  // 1a. Is the active tab in the active window playing right now?
  if (activeTab && tabMediaCache.has(activeTab.id)) {
    const activeMedia = tabMediaCache.get(activeTab.id);
    if (activeMedia.is_playing) {
      return activeMedia;
    }
  }

  // 1b. Are any audible tabs currently playing?
  const playingAudible = [];
  for (const aTab of audibleTabs) {
    if (tabMediaCache.has(aTab.id)) {
      const m = tabMediaCache.get(aTab.id);
      if (m.is_playing) {
        playingAudible.push(m);
      }
    }
  }
  if (playingAudible.length > 0) {
    // Pick the one with the most recent playback update
    playingAudible.sort((a, b) => (b.lastPlaybackTime || b.lastUpdated || 0) - (a.lastPlaybackTime || a.lastUpdated || 0));
    return playingAudible[0];
  }

  // 1c. Any other tab with is_playing: true
  const allPlaying = Array.from(tabMediaCache.values()).filter((m) => m.is_playing);
  if (allPlaying.length > 0) {
    allPlaying.sort((a, b) => (b.lastPlaybackTime || b.lastUpdated || 0) - (a.lastPlaybackTime || a.lastUpdated || 0));
    return allPlaying[0];
  }

  // --- STEP 2: No video currently playing -> Fallback to the LAST tab that played ---
  // 2a. Last tab that was audible
  if (lastAudibleTabId && tabMediaCache.has(lastAudibleTabId)) {
    const lastAudible = tabMediaCache.get(lastAudibleTabId);
    if (lastAudible && (Date.now() - (lastAudibleTime || lastAudible.lastUpdated || 0) < 900000)) {
      return lastAudible;
    }
  }

  // 2b. Last tab that had is_playing: true
  if (lastPlayingTabId && tabMediaCache.has(lastPlayingTabId)) {
    const lastPlaying = tabMediaCache.get(lastPlayingTabId);
    if (lastPlaying && (Date.now() - (lastPlayingTime || lastPlaying.lastUpdated || 0) < 900000)) {
      return lastPlaying;
    }
  }

  // 2c. Any tab with media updated recently (within 15 minutes)
  const recentCandidates = Array.from(tabMediaCache.values())
    .filter((m) => Date.now() - (m.lastUpdated || 0) < 900000)
    .sort((a, b) => (b.lastPlaybackTime || b.lastUpdated || 0) - (a.lastPlaybackTime || a.lastUpdated || 0));

  if (recentCandidates.length > 0) {
    return recentCandidates[0];
  }

  // --- STEP 3: Fallback on the active tab in the active window ---
  if (activeTab && tabMediaCache.has(activeTab.id)) {
    return tabMediaCache.get(activeTab.id);
  }

  // Fallback: If active tab is on YouTube watch page, build fallback descriptor
  if (activeTab && activeTab.url && activeTab.url.includes("youtube.com/watch")) {
    return {
      tabId: activeTab.id,
      windowId: activeTab.windowId,
      type: "NEXUS_MEDIA_STATE_UPDATE",
      source_app: "YouTube (www.youtube.com)",
      media_title: (activeTab.title || "Video YouTube").replace(/ - YouTube$/, ""),
      media_url: activeTab.url,
      position_ms: 0,
      duration_ms: 1800000,
      is_playing: false,
      is_audible: audibleTabIds.has(activeTab.id),
      is_visible: true,
      lastUpdated: Date.now(),
    };
  }

  return null;
}

let isReevaluating = false;
async function reevaluateAndBroadcast() {
  if (isReevaluating) return;
  isReevaluating = true;

  try {
    const bestMedia = await selectBestMedia();
    if (!bestMedia) return;

    lastMonitoredMedia = bestMedia;

    // Check if meaningful media state changed before broadcasting
    const comparisonKey = `${bestMedia.media_url}|${bestMedia.media_title}|${bestMedia.is_playing}|${Math.floor((bestMedia.position_ms || 0) / 2000)}`;
    if (comparisonKey === lastBroadcastMediaStr) {
      return;
    }
    lastBroadcastMediaStr = comparisonKey;

    const payload = {
      type: "NEXUS_MEDIA_STATE_UPDATE",
      source_app: bestMedia.source_app || "Browser",
      media_title: bestMedia.media_title,
      media_url: bestMedia.media_url,
      position_ms: bestMedia.position_ms || 0,
      duration_ms: bestMedia.duration_ms || 1800000,
      is_playing: bestMedia.is_playing || false,
      tab_id: bestMedia.tabId,
    };

    chrome.storage.local.set({ activeMedia: payload }).catch(() => {});

    if (ws && ws.readyState === WebSocket.OPEN) {
      try {
        ws.send(JSON.stringify(payload));
        logMsg(`[Broadcast] Selected tab ${bestMedia.tabId} ("${bestMedia.media_title}") -> ws sent (playing: ${bestMedia.is_playing})`);
      } catch (e) {
        console.error("[Nexus] Invio aggiornamento media fallito:", e);
      }
    }
  } catch (err) {
    console.error("[Nexus] Errore in reevaluateAndBroadcast:", err);
  } finally {
    isReevaluating = false;
  }
}

// -------------------------------------------------------------
// Visual Badge & Notification Indicator Management
// -------------------------------------------------------------
function setStatus(state, details = {}) {
  currentConnectionState = state;
  if (details.error) lastErrorMessage = details.error;

  const storageData = {
    connectionState: state,
    retryCount: retryCount,
    maxRetries: MAX_RETRIES,
    lastError: lastErrorMessage,
    updatedAt: Date.now(),
    activeMedia: lastMonitoredMedia,
  };

  chrome.storage.local.set(storageData).catch(() => {});

  switch (state) {
    case "CONNECTED":
      chrome.action.setBadgeText({ text: "OK" });
      chrome.action.setBadgeBackgroundColor({ color: "#10B981" }); // Emerald Green
      chrome.action.setTitle({
        title: "Nexus Universal Continuity: Connesso al Core Locale (127.0.0.1:28471)",
      });
      break;

    case "CONNECTING":
      chrome.action.setBadgeText({ text: "..." });
      chrome.action.setBadgeBackgroundColor({ color: "#6366F1" }); // Indigo
      chrome.action.setTitle({
        title: "Nexus Continuity: Connessione in corso a 127.0.0.1:28471...",
      });
      break;

    case "RETRYING":
      chrome.action.setBadgeText({ text: `${retryCount}/${MAX_RETRIES}` });
      chrome.action.setBadgeBackgroundColor({ color: "#F59E0B" }); // Amber / Yellow Warning
      chrome.action.setTitle({
        title: `Nexus Continuity: Tentativo di riconnessione ${retryCount} di ${MAX_RETRIES} in corso...`,
      });
      break;

    case "FAILED":
      chrome.action.setBadgeText({ text: "!" });
      chrome.action.setBadgeBackgroundColor({ color: "#EF4444" }); // Bright Red
      chrome.action.setTitle({
        title: "Nexus Continuity: Demone offline. Nessun servizio in ascolto su 127.0.0.1:28471. Clicca per riconnettere.",
      });
      break;

    default:
      chrome.action.setBadgeText({ text: "" });
  }
}

// -------------------------------------------------------------
// WebSocket Connection & Exponential Backoff Engine
// -------------------------------------------------------------
function connectToNexusDaemon(isManualTrigger = false) {
  if (isManualTrigger) {
    retryCount = 0;
    clearPendingReconnect();
  }

  if (ws) {
    try {
      ws.onopen = null;
      ws.onmessage = null;
      ws.onclose = null;
      ws.onerror = null;
      ws.close();
    } catch (_) {}
    ws = null;
  }

  setStatus("CONNECTING");
  console.log(`[Nexus] Tentativo di connessione a ${DAEMON_WS_URL} (Tentativo ${retryCount}/${MAX_RETRIES})...`);

  try {
    ws = new WebSocket(DAEMON_WS_URL);

    ws.onopen = () => {
      console.log("[Nexus] ✅ Connessione stabilita con successo al Demone Nexus!");
      retryCount = 0;
      clearPendingReconnect();
      setStatus("CONNECTED");
      injectIntoAllExistingTabs();

      // Start ping heartbeat every 15s
      if (pingIntervalId) clearInterval(pingIntervalId);
      pingIntervalId = setInterval(() => {
        if (ws && ws.readyState === WebSocket.OPEN) {
          try {
            ws.send(JSON.stringify({ type: "PING", time: Date.now() }));
          } catch (_) {}
        }
      }, 15000);

      // Arbitrate and broadcast current best media playback
      reevaluateAndBroadcast();
    };

    ws.onmessage = (event) => {
      try {
        const cmd = JSON.parse(event.data);
        if (cmd.type === "PONG") return;

        // Forward remote control command (e.g. PAUSE, PLAY, SEEK) to the TARGET media tab first!
        if (lastMonitoredMedia && lastMonitoredMedia.tabId) {
          chrome.tabs.sendMessage(lastMonitoredMedia.tabId, cmd).catch(() => {
            broadcastCommandFallback(cmd);
          });
        } else {
          broadcastCommandFallback(cmd);
        }
      } catch (err) {
        console.error("[Nexus] Errore parsing messaggio dal demone:", err);
      }
    };

    ws.onclose = (event) => {
      console.log(`[Nexus] Connessione chiusa (code: ${event.code}).`);
      if (pingIntervalId) {
        clearInterval(pingIntervalId);
        pingIntervalId = null;
      }
      ws = null;
      handleConnectionFailure("Connessione chiusa o rifiutata (net::ERR_CONNECTION_REFUSED)");
    };

    ws.onerror = (err) => {
      console.warn("[Nexus] Errore WebSocket:", err);
    };
  } catch (err) {
    console.error("[Nexus] Eccezione avvio WebSocket:", err);
    handleConnectionFailure(err.message || "Errore sconosciuto di connessione");
  }
}

function broadcastCommandFallback(cmd) {
  chrome.tabs.query({ active: true, lastFocusedWindow: true }, (tabs) => {
    if (tabs && tabs.length > 0 && tabs[0].id) {
      chrome.tabs.sendMessage(tabs[0].id, cmd).catch(() => {});
    } else {
      chrome.tabs.query({ audible: true }, (audibleTabs) => {
        audibleTabs.forEach((tab) => {
          if (tab.id) {
            chrome.tabs.sendMessage(tab.id, cmd).catch(() => {});
          }
        });
      });
    }
  });
}

function handleConnectionFailure(errorMessage) {
  if (currentConnectionState === "CONNECTED") {
    retryCount = 0;
  }

  if (retryCount < MAX_RETRIES) {
    retryCount++;
    const delayMs = BACKOFF_DELAYS_MS[retryCount - 1] || 30000;
    setStatus("RETRYING", { error: errorMessage });
    console.log(`[Nexus] ⏳ Riconnessione programmata tra ${delayMs / 1000}s (Tentativo ${retryCount}/${MAX_RETRIES})...`);

    clearPendingReconnect();
    reconnectTimeoutId = setTimeout(() => {
      connectToNexusDaemon(false);
    }, delayMs);

    chrome.alarms.create("nexus_reconnect_alarm", {
      delayInMinutes: Math.max(delayMs / 60000, 0.05),
    });
  } else {
    console.warn(`[Nexus] ❌ Raggiunto limite massimo di ${MAX_RETRIES} tentativi. Demone Offline.`);
    clearPendingReconnect();
    setStatus("FAILED", {
      error: `Nessuna risposta da ${DAEMON_WS_URL} dopo ${MAX_RETRIES} tentativi. Assicurati che 'nexus-daemon.exe' o 'nexus_ui.exe' sia in esecuzione.`,
    });
  }
}

function clearPendingReconnect() {
  if (reconnectTimeoutId) {
    clearTimeout(reconnectTimeoutId);
    reconnectTimeoutId = null;
  }
  chrome.alarms.clear("nexus_reconnect_alarm").catch(() => {});
}

// -------------------------------------------------------------
// Chrome Alarms Listener (MV3 Service Worker Wakeup)
// -------------------------------------------------------------
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === "nexus_reconnect_alarm") {
    if (currentConnectionState === "RETRYING") {
      connectToNexusDaemon(false);
    }
  }
});

// -------------------------------------------------------------
// Runtime Messaging (Popup & Content Scripts Interface)
// -------------------------------------------------------------
chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (!message) return;

  if (message.type === "EXTENSION_LOG") {
    if (ws && ws.readyState === WebSocket.OPEN) {
      try {
        ws.send(JSON.stringify(message));
      } catch (_) {}
    }
    return;
  }

  if (message.type === "NEXUS_RECONNECT_NOW") {
    console.log("[Nexus] Riconnessione manuale richiesta dall'utente tramite Popup.");
    connectToNexusDaemon(true);
    sendResponse({
      success: true,
      state: "CONNECTING",
      retryCount: 0,
      maxRetries: MAX_RETRIES,
    });
    return true;
  }

  if (message.type === "GET_STATUS") {
    sendResponse({
      connectionState: currentConnectionState,
      retryCount: retryCount,
      maxRetries: MAX_RETRIES,
      lastError: lastErrorMessage,
      activeMedia: lastMonitoredMedia,
    });
    return true;
  }

  if (message.type === "NEXUS_MEDIA_STATE_UPDATE") {
    const tabId = sender.tab ? sender.tab.id : (message.tab_id || 0);
    const windowId = sender.tab ? sender.tab.windowId : 0;
    const isAudible = sender.tab ? Boolean(sender.tab.audible) : Boolean(message.is_audible);

    const now = Date.now();
    const mediaEntry = {
      ...message,
      tabId: tabId,
      windowId: windowId,
      is_audible: isAudible,
      lastUpdated: now,
    };

    if (message.is_playing) {
      mediaEntry.lastPlaybackTime = now;
      lastPlayingTabId = tabId;
      lastPlayingTime = now;
    }

    if (isAudible) {
      mediaEntry.lastAudibleTime = now;
      lastAudibleTabId = tabId;
      lastAudibleTime = now;
    }

    tabMediaCache.set(tabId, mediaEntry);

    // Run arbitration hierarchy to determine and broadcast the true active media
    reevaluateAndBroadcast();

    if (!ws || ws.readyState !== WebSocket.OPEN) {
      if (currentConnectionState !== "CONNECTING" && currentConnectionState !== "CONNECTED") {
        connectToNexusDaemon(false);
      }
    }
  }
});

// Startup trigger
connectToNexusDaemon(true);
