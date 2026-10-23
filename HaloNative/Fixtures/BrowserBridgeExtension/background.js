// Minimal read-only Manifest V3 service worker for Halo browser bridge
// Manages per-tab document generations, handshake binding, and protocol-compliant lifecycle events.
const NATIVE_HOST_NAME = "app.halo.browser_bridge";
let nativePort = null;
let activeSessionNonce = "";

// Per-tab document generations (tabId -> documentGenerationID)
const tabGenerations = new Map();
const tabContexts = new Map();
// When each tab last started loading a document (Date.now()).
const loadingSince = new Map();

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

  if (msg.type === "observeTab" || msg.type === "findElements") {
    if (!msg.targetTab || !msg.targetTab.tabID) {
      sendError(requestID, sessionNonce, "payloadMalformed", msg.type + " missing targetTab");
      return;
    }
    if (msg.type === "findElements" && (!msg.query || typeof msg.query.text !== "string")) {
      sendError(requestID, sessionNonce, "payloadMalformed", "findElements missing query");
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
      // A document that just started loading is read once its scripts have
      // stopped building it (bounded), not half-built. Injection already waits
      // for the document to be parsed; images need not finish.
      const settle = msg.type === "observeTab" && (tab.status === "loading" || Date.now() - (loadingSince.get(tabID) || 0) < 5000);
      const domResponse = msg.type === "findElements"
        ? await queryDocument(tabID, genID, { action: "find", generationID: genID, query: msg.query })
        : await queryDocument(tabID, genID, { action: "observe", generationID: genID, settle: settle });

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
        title: (after.title || tab.title || "").substring(0, 32768),
        elements: domResponse.elements.slice(0, msg.type === "findElements" ? 20 : 200),
        text: typeof domResponse.text === "string" ? domResponse.text.substring(0, 8000) : undefined
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
  } else if (msg.type === "selectOption" || msg.type === "scrollTab" || msg.type === "navigateTab" || msg.type === "mediaControl") {
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
async function queryDocument(tabID, genID, message) {
  for (let attempt = 0; ; attempt++) {
    try {
      return await chrome.tabs.sendMessage(tabID, message);
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
    await detachStale(tabID);
    await chrome.debugger.attach(debuggee, "1.3");
    attached = true;
    const prep = await pageMessage(tabID, {
      action: "prepareClick", elementID: msg.elementID, expected: msg.expectedElement
    });
    if (!prep || prep.error) {
      sendError(requestID, sessionNonce, (prep && prep.error) || "elementChanged", (prep && prep.message) || "The element could not be prepared");
      return;
    }
    if (!(await unchanged())) {
      await pageMessage(tabID, { action: "cancelClick" }).catch(() => {});
      sendError(requestID, sessionNonce, "staleDocumentGeneration", "The page changed before the click");
      return;
    }
    const point = { x: prep.x, y: prep.y };
    const kind = (msg.expectedElement && msg.expectedElement.kind) || "button";
    submittedTabs.delete(tabID);
    if (kind === "button") await watchRequests(debuggee);
    await chrome.debugger.sendCommand(debuggee, "Input.dispatchMouseEvent", { type: "mouseMoved", ...point });
    await chrome.debugger.sendCommand(debuggee, "Input.dispatchMouseEvent", { type: "mousePressed", button: "left", clickCount: 1, ...point });
    await chrome.debugger.sendCommand(debuggee, "Input.dispatchMouseEvent", { type: "mouseReleased", button: "left", clickCount: 1, ...point });

    let outcome = null;
    try {
      // A link or submit is replacing the document, which may never answer;
      // navigation (or the submit signal) confirms those instead.
      outcome = await pageMessage(tabID, { action: "clickOutcome" }, kind === "button" ? 5000 : 600);
    } catch (_) {
      outcome = null; // The click replaced the document before it could answer.
    }
    if (outcome && outcome.misdirected) {
      sendError(requestID, sessionNonce, "elementChanged", "The click did not land on the approved element and was blocked");
      return;
    }
    // Links and submissions navigate. Wait (bounded, up to 5 s for a slow
    // page) for the new document so Halo receives the navigation event before this result.
    let navigated = false;
    if (kind === "link" || kind === "submit") {
      for (let i = 0; i < 100; i++) {
        if (tabGenerations.get(tabID) !== target.documentGenerationID) { navigated = true; break; }
        await new Promise((resolve) => setTimeout(resolve, 50));
      }
    }
    let performed;
    if (kind === "submit") performed = Boolean(outcome && outcome.submitted) || submittedTabs.has(tabID);
    else if (kind === "link") performed = navigated || Boolean(outcome && outcome.landed);
    else performed = Boolean(outcome && outcome.landed);
    submittedTabs.delete(tabID);
    // A plain button changes its own document; links and submissions replace it.
    const changes = kind === "button" && !navigated ? await settledChanges(tabID, target.documentGenerationID) : undefined;
    nativePort.postMessage({
      requestID: requestID,
      protocolVersion: 1,
      sessionNonce: sessionNonce,
      success: true,
      actionResult: { tab: target, elementID: msg.elementID, performed: performed, changes: changes }
    });
  } catch (err) {
    sendError(requestID, sessionNonce, "internalError", "Click failed: " + String(err && err.message));
  } finally {
    actionRequests.delete(tabID);
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
    await detachStale(tabID);
    await chrome.debugger.attach(debuggee, "1.3");
    attached = true;
    const prep = await pageMessage(tabID, {
      action: "prepareType", elementID: msg.elementID, expected: msg.expectedElement
    });
    if (!prep || prep.error) {
      sendError(requestID, sessionNonce, (prep && prep.error) || "elementChanged", (prep && prep.message) || "The field could not be prepared");
      return;
    }
    const focus = await pageMessage(tabID, { action: "typeFocusHeld" });
    if (!(await unchanged()) || !focus || !focus.held) {
      sendError(requestID, sessionNonce, "elementChanged", "The page or field focus changed before typing");
      return;
    }
    await watchRequests(debuggee);
    await chrome.debugger.sendCommand(debuggee, "Input.insertText", { text: text });
    const outcome = await pageMessage(tabID, { action: "typeOutcome", text: text }).catch(() => null);
    const changes = await settledChanges(tabID, target.documentGenerationID);
    nativePort.postMessage({
      requestID: requestID,
      protocolVersion: 1,
      sessionNonce: sessionNonce,
      success: true,
      actionResult: { tab: target, elementID: msg.elementID, performed: Boolean(outcome && outcome.matched), changes: changes }
    });
  } catch (err) {
    sendError(requestID, sessionNonce, "internalError", "Typing failed: " + String(err && err.message));
  } finally {
    actionRequests.delete(tabID);
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
  const respond = (performed, changes) => nativePort.postMessage({
    requestID: requestID, protocolVersion: 1, sessionNonce: sessionNonce, success: true,
    actionResult: { tab: target, elementID: msg.elementID || "el_page", performed: performed, changes: changes }
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

  if (msg.type === "mediaControl") {
    await handleMedia(msg, requestID, sessionNonce, unchanged);
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
      const result = await pageMessage(tabID, {
        action: "applySelect", elementID: msg.elementID, expected: msg.expectedElement, option: msg.option
      });
      if (!result || result.error) {
        sendError(requestID, sessionNonce, (result && result.error) || "elementChanged", (result && result.message) || "The dropdown could not be changed");
        return;
      }
      respond(Boolean(result.matched), await settledChanges(tabID, target.documentGenerationID));
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
    await detachStale(tabID);
    await chrome.debugger.attach(debuggee, "1.3");
    attached = true;
    const prep = await pageMessage(tabID, {
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
    await watchRequests(debuggee);
    const delta = 120 * steps;
    const deltaX = scroll.direction === "left" ? -delta : scroll.direction === "right" ? delta : 0;
    const deltaY = scroll.direction === "up" ? -delta : scroll.direction === "down" ? delta : 0;
    await chrome.debugger.sendCommand(debuggee, "Input.dispatchMouseEvent", {
      type: "mouseWheel", x: prep.x, y: prep.y, deltaX: deltaX, deltaY: deltaY
    });
    const outcome = await pageMessage(tabID, { action: "scrollOutcome" }).catch(() => null);
    respond(Boolean(outcome && outcome.moved), await settledChanges(tabID, target.documentGenerationID));
  } catch (err) {
    sendError(requestID, sessionNonce, "internalError", "Scroll failed: " + String(err && err.message));
  } finally {
    actionRequests.delete(tabID);
    if (attached) await chrome.debugger.detach(debuggee).catch(() => {});
  }
}

// Media control. The content script acts through the media API; when the page
// needs a user gesture (play blocked by autoplay rules, full screen) the
// debugger grants one with an empty evaluation, and site keys are pressed as
// trusted input. The debugger is attached to this tab only for that moment.
const MEDIA_COMMANDS = ["status", "play", "pause", "toggle", "mute", "unmute", "seek", "volume", "fullscreen", "exit_fullscreen"];
const MEDIA_KEYS = { ArrowRight: 39, ArrowLeft: 37 };

async function handleMedia(msg, requestID, sessionNonce, unchanged) {
  const target = msg.targetTab;
  const tabID = target.tabID;
  const media = msg.media || {};
  if (!MEDIA_COMMANDS.includes(media.command)) {
    sendError(requestID, sessionNonce, "payloadMalformed", "Unknown media command");
    return;
  }
  const respond = (result) => nativePort.postMessage({
    requestID: requestID, protocolVersion: 1, sessionNonce: sessionNonce, success: true,
    actionResult: { tab: target, elementID: "el_page", performed: Boolean(result.performed), media: result.state }
  });
  const fail = (result, fallback) =>
    sendError(requestID, sessionNonce, (result && result.error) || "elementChanged", (result && result.message) || fallback);
  try {
    const first = await pageMessage(tabID, { action: "mediaApply", command: media.command, value: media.value });
    if (!first || first.error) { fail(first, "The media could not be controlled"); return; }
    if (first.done) { respond(first); return; }
    const debuggee = { tabId: tabID };
    let attached = false;
    try {
      await detachStale(tabID);
      await chrome.debugger.attach(debuggee, "1.3");
      attached = true;
      if (!(await unchanged())) {
        sendError(requestID, sessionNonce, "staleDocumentGeneration", "The page changed before the media action");
        return;
      }
      if (first.needs === "keys" && MEDIA_KEYS[first.key]) {
        const key = { key: first.key, code: first.key, windowsVirtualKeyCode: MEDIA_KEYS[first.key] };
        for (let i = 0; i < first.presses; i++) {
          await chrome.debugger.sendCommand(debuggee, "Input.dispatchKeyEvent", { type: "rawKeyDown", ...key });
          await chrome.debugger.sendCommand(debuggee, "Input.dispatchKeyEvent", { type: "keyUp", ...key });
        }
      } else {
        await chrome.debugger.sendCommand(debuggee, "Runtime.evaluate", { expression: "0", userGesture: true });
      }
      const after = await pageMessage(tabID, { action: "mediaAfterGesture" });
      if (!after || after.error) { fail(after, "The media could not be controlled"); return; }
      respond(after);
    } finally {
      if (attached) await chrome.debugger.detach(debuggee).catch(() => {});
    }
  } catch (err) {
    sendError(requestID, sessionNonce, "internalError", "Media control failed: " + String(err && err.message));
  }
}

// Fetch and XHR requests a page starts after an approved action, seen through
// the debugger already attached for that action. A page waiting on its server
// is not settled even when its DOM is quiet (a spinner, then nothing).
const actionRequests = new Map(); // tabId -> { open: Set of requestIds, startedAt }

chrome.debugger.onEvent.addListener((source, method, params) => {
  const watch = actionRequests.get(source.tabId);
  if (!watch) return;
  if (method === "Network.requestWillBeSent" && (params.type === "XHR" || params.type === "Fetch")) watch.open.add(params.requestId);
  else if (method === "Network.loadingFinished" || method === "Network.loadingFailed") watch.open.delete(params.requestId);
});

async function watchRequests(debuggee) {
  actionRequests.set(debuggee.tabId, { open: new Set(), startedAt: Date.now() });
  await chrome.debugger.sendCommand(debuggee, "Network.enable").catch(() => {});
}

// Waits (bounded, 2.5 s from the action) for the action's requests to finish.
// Returns whether any were in flight.
async function requestsDone(tabID) {
  const watch = actionRequests.get(tabID);
  if (!watch) return false;
  const busy = watch.open.size > 0;
  while (watch.open.size > 0 && Date.now() - watch.startedAt < 2500) {
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  actionRequests.delete(tabID);
  return busy;
}

// What an approved action changed in the same document once it settled, or
// undefined when the document was replaced or the page could not report. The
// content script caps its wait below this deadline.
async function settledChanges(tabID, generation) {
  if (tabGenerations.get(tabID) !== generation) return undefined;
  const waitedOnRequests = await requestsDone(tabID);
  const changes = await pageMessage(tabID, { action: "settleChanges", afterRequests: waitedOnRequests }, 4500).catch(() => null);
  if (!changes || changes.error || tabGenerations.get(tabID) !== generation) return undefined;
  return changes;
}

// A page that stops answering must never leave an action hanging: every
// message to the page has a deadline, below Halo's own 10 s limit.
function pageMessage(tabID, message, ms = 5000) {
  return Promise.race([
    chrome.tabs.sendMessage(tabID, message),
    new Promise((_, reject) => setTimeout(() => reject(new Error("The page didn't respond in time; nothing was done")), ms))
  ]);
}

// Clears a debugger attachment this extension left on the tab (for example
// after an interrupted action), so the next action can attach.
async function detachStale(tabID) {
  try {
    const targets = await chrome.debugger.getTargets();
    if (targets.some((t) => t.tabId === tabID && t.attached && t.extensionId === chrome.runtime.id)) {
      await chrome.debugger.detach({ tabId: tabID }).catch(() => {});
    }
  } catch (_) {}
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
    loadingSince.set(tabId, Date.now());
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
  loadingSince.delete(tabId);

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
