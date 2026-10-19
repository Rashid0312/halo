// Minimal read-only Manifest V3 service worker for Halo browser bridge
// Manages per-tab document generations, handshake binding, and protocol-compliant lifecycle events.
const NATIVE_HOST_NAME = "app.halo.browser_bridge";
let nativePort = null;
let activeSessionNonce = "";

// Per-tab document generations (tabId -> documentGenerationID)
const tabGenerations = new Map();
const tabContexts = new Map();

function getTabGeneration(tabId) {
  if (!tabGenerations.has(tabId)) {
    tabGenerations.set(tabId, 1);
  }
  return tabGenerations.get(tabId);
}

function advanceTabGeneration(tabId) {
  const current = getTabGeneration(tabId);
  const next = current + 1;
  tabGenerations.set(tabId, next);
  return { previous: current, next: next };
}

function randomHex(byteCount) {
  const bytes = crypto.getRandomValues(new Uint8Array(byteCount));
  return Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
}

// Halo may restart or rotate its session; retry with capped backoff. While the
// bridge is disabled the host is not registered and each attempt fails cheaply.
let reconnectDelayMs = 1000;
let reconnectTimer = null;

function scheduleReconnect() {
  if (reconnectTimer) return;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    if (!nativePort) connectToNativeHost();
  }, reconnectDelayMs);
  reconnectDelayMs = Math.min(reconnectDelayMs * 2, 30000);
}

function connectToNativeHost() {
  if (typeof chrome.extension !== "undefined" && chrome.extension.inIncognitoContext) {
    console.error("[HaloBridge] Incognito context rejected.");
    return null;
  }
  try {
    const port = chrome.runtime.connectNative(NATIVE_HOST_NAME);
    port.onMessage.addListener(handleHostMessage);
    port.onDisconnect.addListener(() => {
      console.warn("[HaloBridge] Native host disconnected:", chrome.runtime.lastError?.message);
      if (nativePort === port) {
        nativePort = null;
        activeSessionNonce = "";
        scheduleReconnect();
      }
    });
    nativePort = port;
    return port;
  } catch (err) {
    console.error("[HaloBridge] Failed to connect native host:", err);
    return null;
  }
}

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.action === "ensureNativeConnection") {
    if (!nativePort) connectToNativeHost();
    sendResponse({ connected: Boolean(nativePort) });
  }
});
chrome.runtime.onInstalled.addListener(() => { if (!nativePort) connectToNativeHost(); });
chrome.runtime.onStartup.addListener(() => { if (!nativePort) connectToNativeHost(); });

async function handleHostMessage(msg) {
  if (!nativePort) return;

  // 1. Handle Handshake challenge from HaloNativeHost
  if (msg.issuedAt && msg.serverNonce && !msg.type) {
    activeSessionNonce = msg.serverNonce;
    reconnectDelayMs = 1000;
    const response = {
      version: 1,
      serverNonce: msg.serverNonce,
      clientNonce: randomHex(32),
      extensionID: chrome.runtime.id,
      acceptedAt: new Date().toISOString()
    };
    nativePort.postMessage({
      requestID: "handshake_response",
      protocolVersion: 1,
      sessionNonce: msg.serverNonce,
      success: true,
      handshake: response
    });
    const tabs = await chrome.tabs.query({});
    for (const tab of tabs) {
      const url = tab.url || "";
      if (tab.incognito || (!url.startsWith("http://127.0.0.1") && !url.startsWith("http://localhost"))) continue;
      let domain = "";
      try { domain = new URL(url).hostname.toLowerCase(); } catch (_) { continue; }
      nativePort.postMessage({
        requestID: "announce_" + tab.id,
        protocolVersion: 1,
        sessionNonce: activeSessionNonce,
        success: true,
        tabAnnouncement: {
          tabID: tab.id,
          documentGenerationID: getTabGeneration(tab.id),
          title: (tab.title || "").substring(0, 32768),
          url: url,
          domain: domain,
          isIncognito: false
        }
      });
    }
    return;
  }

  // 2. Handle standard BridgeRequest envelopes
  const requestID = msg.requestID || "unknown";
  const sessionNonce = msg.sessionNonce || activeSessionNonce;

  if (msg.type === "observeTab") {
    if (!msg.targetTab || !msg.targetTab.tabID) {
      sendError(requestID, sessionNonce, "payloadMalformed", "observeTab missing targetTab");
      return;
    }
    const tabID = msg.targetTab.tabID;

    try {
      const tab = await chrome.tabs.get(tabID);
      if (!tab) {
        sendError(requestID, sessionNonce, "tabNotAuthorized", "Tab not found");
        return;
      }
      if (tab.incognito) {
        sendError(requestID, sessionNonce, "tabNotAuthorized", "Incognito tab access is forbidden");
        return;
      }

      // Check URL bounds (fixture restricted to loopback)
      const currentURL = tab.url || "";
      if (!currentURL.startsWith("http://127.0.0.1") && !currentURL.startsWith("http://localhost")) {
        sendError(requestID, sessionNonce, "tabNotAuthorized", "Host permission restricted to loopback fixture");
        return;
      }

      let currentDomain = "";
      try { currentDomain = new URL(currentURL).hostname.toLowerCase(); } catch (_) {}
      if (currentURL !== msg.targetTab.url || currentDomain !== msg.targetTab.domain.toLowerCase()) {
        sendError(requestID, sessionNonce, "staleDocumentGeneration", "Tab URL changed before observation");
        return;
      }

      // Query content script with current document generation
      if (!tabGenerations.has(tabID)) {
        tabGenerations.set(tabID, msg.targetTab.documentGenerationID);
      }
      const genID = getTabGeneration(tabID);
      if (genID !== msg.targetTab.documentGenerationID) {
        sendError(requestID, sessionNonce, "staleDocumentGeneration", "Document generation changed before observation");
        return;
      }
      tabContexts.set(tabID, { browser: msg.targetTab.browser, domain: currentDomain });
      const domResponse = await observeDocument(tabID, genID);

      // The document must still be the one that was checked before observing.
      const after = await chrome.tabs.get(tabID);
      if (getTabGeneration(tabID) !== genID || (after.url || "") !== currentURL) {
        sendError(requestID, sessionNonce, "staleDocumentGeneration", "Document changed during observation");
        return;
      }

      if (!domResponse || !domResponse.elements) {
        sendError(requestID, sessionNonce, "internalError", "Content script returned invalid DOM snapshot");
        return;
      }

      const observation = {
        tab: {
          browser: msg.targetTab.browser,
          tabID: tabID,
          documentGenerationID: genID,
          url: currentURL,
          domain: currentDomain,
          isIncognito: false
        },
        title: (tab.title || "").substring(0, 32768),
        elements: domResponse.elements.slice(0, 200)
      };

      nativePort.postMessage({
        requestID: requestID,
        protocolVersion: 1,
        sessionNonce: sessionNonce,
        success: true,
        observation: observation
      });
    } catch (err) {
      sendError(requestID, sessionNonce, "internalError", "Failed to observe tab: " + err.message);
    }
  } else if (msg.type === "pauseTabs" || msg.type === "revokeTab") {
    nativePort.postMessage({
      requestID: requestID,
      protocolVersion: 1,
      sessionNonce: sessionNonce,
      success: true
    });
  } else {
    sendError(requestID, sessionNonce, "unknownMessageType", "Unknown request type: " + msg.type);
  }
}

// A document may have no content script yet: it runs at document_idle, and
// pages loaded before the extension started never receive one. Inject it on
// demand (host permissions still limit this to loopback), then retry briefly.
async function observeDocument(tabID, genID) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await chrome.tabs.sendMessage(tabID, { action: "observe", generationID: genID });
    } catch (err) {
      const missing = String(err && err.message).includes("Receiving end does not exist");
      if (!missing || attempt >= 20) throw err;
      if (attempt === 0) {
        await chrome.scripting.executeScript({ target: { tabId: tabID }, files: ["content.js"] }).catch(() => {});
        continue;
      }
      await new Promise((resolve) => setTimeout(resolve, 100));
      if (getTabGeneration(tabID) !== genID) throw new Error("Document changed while waiting for content script");
    }
  }
}

function sendError(requestID, sessionNonce, code, message) {
  if (!nativePort) return;
  nativePort.postMessage({
    requestID: requestID,
    protocolVersion: 1,
    sessionNonce: sessionNonce || activeSessionNonce,
    success: false,
    error: {
      code: code,
      message: message.substring(0, 1024)
    }
  });
}

// 3. Per-tab navigation lifecycle tracking with valid envelopes
chrome.tabs.onUpdated.addListener((tabId, changeInfo, tab) => {
  if (!nativePort || !activeSessionNonce || tab.incognito) return;
  const context = tabContexts.get(tabId);
  if (!context) return;
  if (changeInfo.status === "loading") {
    const { previous, next } = advanceTabGeneration(tabId);
    let domain = "";
    const targetURL = changeInfo.url || tab.url || "";
    try { domain = new URL(targetURL).hostname.toLowerCase(); } catch (_) {}

    const navEvent = {
      browser: {
        bundleID: context.browser.bundleID,
        sessionID: context.browser.sessionID,
        pid: context.browser.pid
      },
      tabID: tabId,
      previousDocumentGenerationID: previous,
      newDocumentGenerationID: next,
      newURL: targetURL,
      newDomain: domain
    };

    nativePort.postMessage({
      requestID: "evt_nav_" + tabId + "_" + next,
      protocolVersion: 1,
      sessionNonce: activeSessionNonce,
      success: true,
      navigation: navEvent
    });
  }
});

// 4. Tab closure lifecycle tracking
chrome.tabs.onRemoved.addListener((tabId) => {
  if (!nativePort || !activeSessionNonce) return;
  const context = tabContexts.get(tabId);
  if (!context) return;
  const currentGen = getTabGeneration(tabId);
  tabGenerations.delete(tabId);
  tabContexts.delete(tabId);

  nativePort.postMessage({
    requestID: "evt_close_" + tabId + "_" + Date.now(),
    protocolVersion: 1,
    sessionNonce: activeSessionNonce,
    success: true,
    tabClosed: {
      browser: {
        bundleID: context.browser.bundleID,
        sessionID: context.browser.sessionID,
        pid: context.browser.pid
      },
      tabID: tabId,
      documentGenerationID: currentGen
    }
  });
});

// Auto-connect upon service worker initialization
connectToNativeHost();
