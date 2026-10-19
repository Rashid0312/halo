// Content script for Halo's browser bridge. Observation is read-only and never
// reads form values; Phase 5B.1 adds one tightly checked click path.
(() => {
  // On-demand injection may run this file again in a document that already
  // has it; keep exactly one listener and one element map per document.
  if (globalThis.__haloBridgeContent) return;
  globalThis.__haloBridgeContent = true;

  // Element references are stable for the lifetime of this document. A new
  // document (navigation or reload) gets a new content script and new IDs, so
  // a reference can never resolve in a different document.
  const idsByElement = new WeakMap();
  const elementsByID = new Map();

  function referenceFor(el, generationID) {
    let id = idsByElement.get(el);
    if (!id) {
      const bytes = crypto.getRandomValues(new Uint8Array(8));
      id = "el_" + generationID + "_" + Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");
      idsByElement.set(el, id);
      elementsByID.set(id, new WeakRef(el));
    }
    return id;
  }

  function isProtectedElement(el) {
    const type = (el.getAttribute("type") || el.type || "").toLowerCase();
    const role = (el.getAttribute("role") || "").toLowerCase();
    const name = (el.getAttribute("name") || "").toLowerCase();
    const autocomplete = (el.getAttribute("autocomplete") || "").toLowerCase();
    return (
      type === "password" ||
      role === "password" ||
      el.hasAttribute("data-protected") ||
      autocomplete.includes("password") ||
      autocomplete.includes("one-time-code") ||
      name.includes("password") ||
      name.includes("passwd") ||
      name.includes("secret") ||
      name.includes("token")
    );
  }

  function describe(el) {
    const tagName = (el.tagName || "").toLowerCase().substring(0, 128);
    const role = (el.getAttribute("role") || "").toLowerCase().substring(0, 128);
    const isProtected = isProtectedElement(el);
    let label;
    if (isProtected) {
      // Only accessible descriptions; a protected element's value is never read.
      label = (el.getAttribute("aria-label") || el.getAttribute("placeholder") || "").trim();
    } else {
      // Form values are user data, not labels. Never read `.value`.
      label = (el.innerText || el.getAttribute("aria-label") || el.getAttribute("placeholder") || "").trim();
    }
    return { tagName, role, label: label.substring(0, 32768), isProtected };
  }

  // Phase 5B.1 click policy: plain buttons only. Anything that can submit a
  // form, navigate, or touch credentials is refused until a later slice.
  function isActionable(el, info) {
    if (info.isProtected || el.disabled || el.getAttribute("aria-disabled") === "true") return false;
    if (el.closest("form, a[href]")) return false;
    const isPlainButton = info.tagName === "button" && (el.getAttribute("type") || "").toLowerCase() === "button";
    const isRoleButton = info.role === "button" && !["a", "input", "select", "textarea", "form"].includes(info.tagName);
    if (!isPlainButton && !isRoleButton) return false;
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
  }

  function observe(generationID) {
    const elements = [];
    const candidates = document.querySelectorAll(
      "button, input, select, textarea, a[href], h1, h2, h3, [role='button'], [role='textbox']"
    );
    for (const el of candidates) {
      if (elements.length >= 200) break; // Strict upper bound per observation
      const info = describe(el);
      const rect = el.getBoundingClientRect();
      elements.push({
        elementID: referenceFor(el, generationID),
        tagName: info.tagName,
        role: info.role,
        label: info.label,
        isProtected: info.isProtected,
        isEnabled: !el.disabled,
        isActionable: isActionable(el, info),
        bounds: {
          x: Math.max(0, rect.x),
          y: Math.max(0, rect.y),
          width: Math.max(0, rect.width),
          height: Math.max(0, rect.height)
        }
      });
    }
    return elements;
  }

  const nextFrame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));

  // Armed for exactly one approved click: any click sequence that lands outside
  // the approved element is blocked, and whether the trusted click reached the
  // element is recorded for verification.
  let armedGuard = null;

  function disarm() {
    if (!armedGuard) return;
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
      window.removeEventListener(type, armedGuard.listener, true);
    }
    clearTimeout(armedGuard.timer);
    armedGuard = null;
  }

  function arm(el) {
    disarm();
    const guard = { target: el, landed: false, misdirected: false, listener: null, timer: 0 };
    guard.listener = (event) => {
      if (!event.isTrusted) return;
      if (el.contains(event.target)) {
        if (event.type === "click") guard.landed = true;
        return;
      }
      guard.misdirected = true;
      event.preventDefault();
      event.stopImmediatePropagation();
    };
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
      window.addEventListener(type, guard.listener, true);
    }
    guard.timer = setTimeout(disarm, 5000);
    armedGuard = guard;
  }

  async function prepareClick(request) {
    const ref = elementsByID.get(request.elementID);
    const el = ref && ref.deref();
    if (!el || !el.isConnected) return { error: "elementChanged", message: "The element is no longer on the page." };
    const info = describe(el);
    const expected = request.expected || {};
    if (info.tagName !== expected.tagName || info.role !== expected.role || info.label !== expected.label) {
      return { error: "elementChanged", message: "The element changed after approval." };
    }
    if (!isActionable(el, info)) return { error: "elementNotActionable", message: "The element is not a plain, enabled, visible button." };

    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    // Let layout settle (including the debugger infobar) before measuring.
    await nextFrame();
    await nextFrame();
    const rect = el.getBoundingClientRect();
    const x = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;
    const hit = document.elementFromPoint(x, y);
    if (!hit || !el.contains(hit)) {
      return { error: "elementChanged", message: "Another element covers the approved element at its click point." };
    }
    arm(el);
    return { x, y };
  }

  chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "observe") {
      sendResponse({ elements: observe(request.generationID || 1) });
      return false;
    }
    if (request.action === "prepareClick") {
      prepareClick(request).then(sendResponse, (err) => sendResponse({ error: "internalError", message: String(err && err.message) }));
      return true;
    }
    if (request.action === "clickOutcome") {
      const guard = armedGuard;
      const outcome = guard ? { landed: guard.landed, misdirected: guard.misdirected } : { landed: false, misdirected: false };
      disarm();
      sendResponse(outcome);
      return false;
    }
    if (request.action === "cancelClick") {
      disarm();
      sendResponse({ ok: true });
      return false;
    }
    return false;
  });

  // Wake the MV3 service worker when an eligible document loads. Service
  // workers are intentionally ephemeral and must not rely on install-time startup.
  chrome.runtime.sendMessage({ action: "ensureNativeConnection" }).catch(() => {});
})();
