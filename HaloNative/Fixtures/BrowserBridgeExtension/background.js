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
  // Capped low so Halo reconnects within seconds after it restarts; a failed
  // attempt is cheap and the worker stops when Chrome idles it anyway.
  reconnectDelayMs = Math.min(reconnectDelayMs * 2, 5000);
}

// Site access is whatever Chrome currently grants this extension: all http(s)
// sites by default, narrowed if the user restricts "Site access" in Chrome.
async function hasSiteAccess(url) {
  try {
    const parsed = new URL(url);
    if (!["http:", "https:"].includes(parsed.protocol)) return false;
    return await chrome.permissions.contains({ origins: [parsed.origin + "/*"] });
  } catch (_) {
    return false;
  }
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

// Trusted form submissions reported by the content script, per tab. A
// submission usually unloads the page, so it is signalled before navigation.
const submittedTabs = new Set();

chrome.runtime.onMessage.addListener((message, sender, sendResponse) => {
  if (message && message.action === "haloSubmitted" && sender.tab) {
    submittedTabs.add(sender.tab.id);
    return false;
  }
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
    let announced = 0;
    for (const tab of tabs) {
      const url = tab.url || "";
      if (tab.incognito || !(url.startsWith("http://") || url.startsWith("https://"))) continue;
      if (++announced > 100) break;
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
      if (!(await hasSiteAccess(currentURL))) {
        sendError(requestID, sessionNonce, "hostNotGranted", "The extension does not have access to this site");
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
  } else if (msg.type === "clickElement") {
    await handleClick(msg, requestID, sessionNonce);
  } else if (msg.type === "typeText") {
    await handleType(msg, requestID, sessionNonce);
  } else if (msg.type === "selectOption" || msg.type === "scrollTab" || msg.type === "navigateTab") {
    await handlePhase5B3(msg, requestID, sessionNonce);
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

// Phase 5B.1: one approved click. Halo has already re-observed the element and
// obtained the user's approval; this re-checks everything against the live
// document, then sends a genuine mouse click through chrome.debugger attached to
// this tab only for the duration of the click.
async function handleClick(msg, requestID, sessionNonce) {
  const target = msg.targetTab;
  if (!target || !target.tabID || !msg.elementID || !msg.expectedElement) {
    sendError(requestID, sessionNonce, "payloadMalformed", "clickElement missing target, element, or fingerprint");
    return;
  }
  const tabID = target.tabID;
  const unchanged = async () => {
    const tab = await chrome.tabs.get(tabID);
    return !tab.incognito && (tab.url || "") === target.url &&
      tabGenerations.get(tabID) === target.documentGenerationID;
  };
  try {
    // A click is only valid in a document Halo has observed in this session.
    if (!tabContexts.has(tabID) || !(await unchanged())) {
      sendError(requestID, sessionNonce, "staleDocumentGeneration", "The page changed before the click");
      return;
    }
    if (!(await hasSiteAccess(target.url))) {
      sendError(requestID, sessionNonce, "hostNotGranted", "The extension does not have access to this site");
      return;
    }
  } catch (err) {
    sendError(requestID, sessionNonce, "tabNotAuthorized", "Tab not found");
    return;
  }

  const debuggee = { tabId: tabID };
  let attached = false;
  try {
    await chrome.debugger.attach(debuggee, "1.3");
    attached = true;
    const prep = await chrome.tabs.sendMessage(tabID, {
      action: "prepareClick", elementID: msg.elementID, expected: msg.expectedElement
    });
    if (!prep || prep.error) {
      sendError(requestID, sessionNonce, (prep && prep.error) || "elementChanged", (prep && prep.message) || "The element could not be prepared");
      return;
    }
    if (!(await unchanged())) {
      await chrome.tabs.sendMessage(tabID, { action: "cancelClick" }).catch(() => {});
      sendError(requestID, sessionNonce, "staleDocumentGeneration", "The page changed before the click");
      return;
    }
    const point = { x: prep.x, y: prep.y };
    const kind = (msg.expectedElement && msg.expectedElement.kind) || "button";
    submittedTabs.delete(tabID);
    await chrome.debugger.sendCommand(debuggee, "Input.dispatchMouseEvent", { type: "mouseMoved", ...point });
    await chrome.debugger.sendCommand(debuggee, "Input.dispatchMouseEvent", { type: "mousePressed", button: "left", clickCount: 1, ...point });
    await chrome.debugger.sendCommand(debuggee, "Input.dispatchMouseEvent", { type: "mouseReleased", button: "left", clickCount: 1, ...point });

    let outcome = null;
    try {
      outcome = await chrome.tabs.sendMessage(tabID, { action: "clickOutcome" });
    } catch (_) {
      outcome = null; // The click replaced the document before it could answer.
    }
    if (outcome && outcome.misdirected) {
      sendError(requestID, sessionNonce, "elementChanged", "The click did not land on the approved element and was blocked");
      return;
    }
    // Links and submissions navigate. Wait (bounded) for the new document so
    // Halo receives the navigation event before this result.
    let navigated = false;
    if (kind === "link" || kind === "submit") {
      for (let i = 0; i < 40; i++) {
        if (tabGenerations.get(tabID) !== target.documentGenerationID) { navigated = true; break; }
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }
    let performed;
    if (kind === "submit") performed = Boolean(outcome && outcome.submitted) || submittedTabs.has(tabID);
    else if (kind === "link") performed = navigated || Boolean(outcome && outcome.landed);
    else performed = Boolean(outcome && outcome.landed);
    submittedTabs.delete(tabID);
    nativePort.postMessage({
      requestID: requestID,
      protocolVersion: 1,
      sessionNonce: sessionNonce,
      success: true,
      actionResult: { tab: target, elementID: msg.elementID, performed: performed }
    });
  } catch (err) {
    sendError(requestID, sessionNonce, "internalError", "Click failed: " + String(err && err.message));
  } finally {
    if (attached) await chrome.debugger.detach(debuggee).catch(() => {});
  }
}

// Phase 5B.2: replace one approved field's contents with approved text using
// trusted input. Input.insertText inserts text only; it never presses Enter, so
// typing cannot submit a form. The field value is never sent to Halo.
async function handleType(msg, requestID, sessionNonce) {
  const target = msg.targetTab;
  const text = msg.text;
  if (!target || !target.tabID || !msg.elementID || !msg.expectedElement || typeof text !== "string" ||
      text.length === 0 || text.length > 4000 || /[\u0000-\u001f\u007f-\u009f\u2028\u2029]/.test(text)) {
    sendError(requestID, sessionNonce, "payloadMalformed", "typeText requires a target, field, fingerprint, and plain single-line text");
    return;
  }
  const tabID = target.tabID;
  const unchanged = async () => {
    const tab = await chrome.tabs.get(tabID);
    return !tab.incognito && (tab.url || "") === target.url &&
      tabGenerations.get(tabID) === target.documentGenerationID;
  };
  try {
    if (!tabContexts.has(tabID) || !(await unchanged())) {
      sendError(requestID, sessionNonce, "staleDocumentGeneration", "The page changed before typing");
      return;
    }
    if (!(await hasSiteAccess(target.url))) {
      sendError(requestID, sessionNonce, "hostNotGranted", "The extension does not have access to this site");
      return;
    }
  } catch (err) {
    sendError(requestID, sessionNonce, "tabNotAuthorized", "Tab not found");
    return;
  }

  const debuggee = { tabId: tabID };
  let attached = false;
  try {
    await chrome.debugger.attach(debuggee, "1.3");
    attached = true;
    const prep = await chrome.tabs.sendMessage(tabID, {
      action: "prepareType", elementID: msg.elementID, expected: msg.expectedElement
    });
    if (!prep || prep.error) {
      sendError(requestID, sessionNonce, (prep && prep.error) || "elementChanged", (prep && prep.message) || "The field could not be prepared");
      return;
    }
    const focus = await chrome.tabs.sendMessage(tabID, { action: "typeFocusHeld" });
    if (!(await unchanged()) || !focus || !focus.held) {
      sendError(requestID, sessionNonce, "elementChanged", "The page or field focus changed before typing");
      return;
    }
    await chrome.debugger.sendCommand(debuggee, "Input.insertText", { text: text });
    const outcome = await chrome.tabs.sendMessage(tabID, { action: "typeOutcome", text: text }).catch(() => null);
    nativePort.postMessage({
      requestID: requestID,
      protocolVersion: 1,
      sessionNonce: sessionNonce,
      success: true,
      actionResult: { tab: target, elementID: msg.elementID, performed: Boolean(outcome && outcome.matched) }
    });
  } catch (err) {
    sendError(requestID, sessionNonce, "internalError", "Typing failed: " + String(err && err.message));
  } finally {
    if (attached) await chrome.debugger.detach(debuggee).catch(() => {});
  }
}

// Phase 5B.3: select an option, scroll, or navigate. Each re-checks the
// approved document first; scroll uses a trusted wheel event through
// chrome.debugger attached to this tab only for the action.
async function handlePhase5B3(msg, requestID, sessionNonce) {
  const target = msg.targetTab;
  if (!target || !target.tabID) {
    sendError(requestID, sessionNonce, "payloadMalformed", msg.type + " requires a target tab");
    return;
  }
  const tabID = target.tabID;
  const unchanged = async () => {
    const tab = await chrome.tabs.get(tabID);
    return !tab.incognito && (tab.url || "") === target.url &&
      tabGenerations.get(tabID) === target.documentGenerationID;
  };
  const respond = (performed) => nativePort.postMessage({
    requestID: requestID, protocolVersion: 1, sessionNonce: sessionNonce, success: true,
    actionResult: { tab: target, elementID: msg.elementID || "el_page", performed: performed }
  });
  try {
    if (!tabContexts.has(tabID) || !(await unchanged())) {
      sendError(requestID, sessionNonce, "staleDocumentGeneration", "The page changed before the action");
      return;
    }
    if (!(await hasSiteAccess(target.url))) {
      sendError(requestID, sessionNonce, "hostNotGranted", "The extension does not have access to this site");
      return;
    }
  } catch (err) {
    sendError(requestID, sessionNonce, "tabNotAuthorized", "Tab not found");
    return;
  }

  if (msg.type === "navigateTab") {
    let url;
    try { url = new URL(msg.url); } catch (_) { url = null; }
    if (!url || !["http:", "https:"].includes(url.protocol) || url.username || url.password) {
      sendError(requestID, sessionNonce, "payloadMalformed", "Navigation URL must be http(s) without credentials");
      return;
    }
    try {
      const before = target.documentGenerationID;
      await chrome.tabs.update(tabID, { url: url.href });
      // Respond once the new document has started loading, so Halo applies the
      // navigation event (and invalidates old references) before the result.
      for (let i = 0; i < 100 && tabGenerations.get(tabID) === before; i++) {
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
      respond(tabGenerations.get(tabID) !== before);
    } catch (err) {
      sendError(requestID, sessionNonce, "internalError", "Navigation failed: " + String(err && err.message));
    }
    return;
  }

  if (msg.type === "selectOption") {
    if (!msg.elementID || !msg.expectedElement || typeof msg.option !== "string") {
      sendError(requestID, sessionNonce, "payloadMalformed", "selectOption requires a dropdown, fingerprint, and option");
      return;
    }
    try {
      const result = await chrome.tabs.sendMessage(tabID, {
        action: "applySelect", elementID: msg.elementID, expected: msg.expectedElement, option: msg.option
      });
      if (!result || result.error) {
        sendError(requestID, sessionNonce, (result && result.error) || "elementChanged", (result && result.message) || "The dropdown could not be changed");
        return;
      }
      respond(Boolean(result.matched));
    } catch (err) {
      sendError(requestID, sessionNonce, "internalError", "Selection failed: " + String(err && err.message));
    }
    return;
  }

  // scrollTab
  const scroll = msg.scroll || {};
  const steps = Number(scroll.amount);
  if (!["up", "down", "left", "right"].includes(scroll.direction) || !(steps >= 1 && steps <= 20)) {
    sendError(requestID, sessionNonce, "payloadMalformed", "scrollTab requires a direction and 1-20 steps");
    return;
  }
  const debuggee = { tabId: tabID };
  let attached = false;
  try {
    await chrome.debugger.attach(debuggee, "1.3");
    attached = true;
    const prep = await chrome.tabs.sendMessage(tabID, {
      action: "prepareScroll", elementID: msg.elementID || null, expected: msg.expectedElement || null
    });
    if (!prep || prep.error) {
      sendError(requestID, sessionNonce, (prep && prep.error) || "elementChanged", (prep && prep.message) || "The scroll target could not be prepared");
      return;
    }
    if (!(await unchanged())) {
      sendError(requestID, sessionNonce, "staleDocumentGeneration", "The page changed before scrolling");
      return;
    }
    const delta = 120 * steps;
    const deltaX = scroll.direction === "left" ? -delta : scroll.direction === "right" ? delta : 0;
    const deltaY = scroll.direction === "up" ? -delta : scroll.direction === "down" ? delta : 0;
    await chrome.debugger.sendCommand(debuggee, "Input.dispatchMouseEvent", {
      type: "mouseWheel", x: prep.x, y: prep.y, deltaX: deltaX, deltaY: deltaY
    });
    const outcome = await chrome.tabs.sendMessage(tabID, { action: "scrollOutcome" }).catch(() => null);
    respond(Boolean(outcome && outcome.moved));
  } catch (err) {
    sendError(requestID, sessionNonce, "internalError", "Scroll failed: " + String(err && err.message));
  } finally {
    if (attached) await chrome.debugger.detach(debuggee).catch(() => {});
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
