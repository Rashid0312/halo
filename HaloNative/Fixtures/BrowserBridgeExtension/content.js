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
      // Form values are user data, not labels. Never read `.value`. Fields are
      // named by their associated <label>, then aria-label, then placeholder.
      const associated = el.labels && el.labels.length ? el.labels[0].innerText : "";
      // A form field's own text is its contents (select options, textarea
      // text), which is user data: name fields only by their labels.
      const isField = ["input", "select", "textarea"].includes(tagName);
      label = ((isField ? "" : el.innerText) || associated || el.getAttribute("aria-label") || el.getAttribute("placeholder") || "").trim();
    }
    // Labels are capped so large pages stay well inside the 1 MB message limit.
    return { tagName, role, label: label.substring(0, 500), isProtected };
  }

  // Phase 5B.1 click policy: plain buttons only. Anything that can submit a
  // form, navigate, or touch credentials is refused until a later slice.
  function isVisibleAndEnabled(el, info) {
    if (info.isProtected || el.disabled || el.getAttribute("aria-disabled") === "true") return false;
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
  }

  // Phase 5B.4 sensitive-action families. These stay blocked, each with its
  // own reason, until a later slice gives them dedicated approval language.
  const PAYMENT_WORDS = /\b(buy|pay|purchase|checkout|check out|place order|order now|subscribe|donate|add to (cart|bag|basket)|confirm (payment|order))\b/i;
  const ACCOUNT_WORDS = /\b(delete|deactivate|close (my |your )?account|remove (my |your )?account|unsubscribe|cancel (my |your )?(subscription|membership)|change (email|password)|reset password|log ?out|sign ?out)\b/i;
  const LOGIN_WORDS = /\b(log ?in|sign ?in|sign ?up|register|create account|verify)\b/i;
  const MESSAGE_WORDS = /\b(send|post|reply|comment|publish|share|tweet|message)\b/i;
  const FILE_EXTENSION = /\.(zip|dmg|pkg|exe|msi|iso|tar|gz|tgz|7z|rar|apk|deb|rpm|csv|xlsx?|docx?|pptx?|pdf)$/i;

  function sensitiveWords(label) {
    if (PAYMENT_WORDS.test(label)) return "payment";
    if (ACCOUNT_WORDS.test(label)) return "account";
    if (LOGIN_WORDS.test(label)) return "login";
    if (MESSAGE_WORDS.test(label)) return "message";
    return null;
  }

  let currentGeneration = 1;

  // What clicking `el` would do: { kind } for a plain button, an ordinary
  // same-site form submission, or a same-tab http(s) link; { reason } when the
  // action belongs to a blocked family; {} when it is not clickable at all.
  function classify(el, info) {
    if (!isVisibleAndEnabled(el, info)) return {};
    const type = (el.getAttribute("type") || "").toLowerCase();

    if (info.tagName === "a" && el.hasAttribute("href")) {
      let url = null;
      try { url = new URL(el.href); } catch (_) {}
      if (!url || !["http:", "https:"].includes(url.protocol)) return { reason: "nonHttpLink" };
      const target = (el.getAttribute("target") || "").toLowerCase();
      if (target && target !== "_self") return { reason: "newTab" };
      if (el.hasAttribute("download") || FILE_EXTENSION.test(url.pathname)) return { reason: "download" };
      const words = sensitiveWords(info.label);
      if (words) return { reason: words };
      return { kind: "link", destination: url.href };
    }

    const isSubmit = (info.tagName === "button" && (type === "" || type === "submit") && el.form) ||
      (info.tagName === "input" && ["submit", "image"].includes(type));
    if (isSubmit) {
      const form = el.form;
      if (!form) return {};
      const fields = Array.from(form.elements);
      if (fields.some((f) => (f.type || "").toLowerCase() === "password" ||
          (f.getAttribute("autocomplete") || "").toLowerCase().includes("one-time-code"))) return { reason: "login" };
      if (fields.some((f) => (f.type || "").toLowerCase() === "file")) return { reason: "upload" };
      if (fields.some((f) => (f.getAttribute("autocomplete") || "").toLowerCase().startsWith("cc-") ||
          SENSITIVE_HINT.test([f.getAttribute("name"), f.id, f.getAttribute("aria-label")].join(" ")))) return { reason: "payment" };
      const words = sensitiveWords(info.label);
      if (words) return { reason: words };
      if (fields.some((f) => (f.tagName || "").toLowerCase() === "textarea")) return { reason: "message" };
      let action = null;
      // A submitter's formAction/formMethod properties return the document URL
      // and a default when the attribute is absent, so only honour them when
      // the attribute is present; otherwise the form's own action applies.
      const actionAttribute = el.hasAttribute("formaction") ? el.getAttribute("formaction") : form.getAttribute("action");
      try { action = new URL(actionAttribute || location.href, location.href); } catch (_) {}
      if (!action || action.origin !== location.origin) return { reason: "crossSiteForm" };
      const method = (el.hasAttribute("formmethod") ? el.getAttribute("formmethod") : form.getAttribute("method")) || "get";
      if (method.toLowerCase() === "dialog") return { reason: "other" };
      const formFields = fields.filter((f) => {
        const t = (f.type || "").toLowerCase();
        return ["input", "select", "textarea"].includes((f.tagName || "").toLowerCase()) &&
          !["hidden", "submit", "button", "image", "reset", "file", "password"].includes(t);
      }).slice(0, 30).map((f) => ({
        elementID: referenceFor(f, currentGeneration),
        label: describe(f).label.substring(0, 200),
        // Only whether a field is filled is reported, never its value.
        filled: (f.tagName || "").toLowerCase() === "select" ? f.selectedIndex >= 0 : f.value !== ""
      }));
      return { kind: "submit", destination: action.href, formFields };
    }

    if (el.closest("form, a[href]")) return {};
    // A <button> with no form owner submits nothing, whatever its type, so it
    // behaves as a plain button (common on real sites, e.g. search buttons
    // wired up in script).
    const isPlainButton = info.tagName === "button" && (type === "button" || ((type === "" || type === "submit") && !el.form));
    const isRoleButton = info.role === "button" && !["a", "input", "select", "textarea", "form"].includes(info.tagName);
    if (!isPlainButton && !isRoleButton) return {};
    const words = sensitiveWords(info.label);
    if (words) return { reason: words };
    return { kind: "button" };
  }

  function isActionable(el, info) {
    return classify(el, info).kind === "button";
  }

  // Phase 5B.2 text-entry policy: plain text fields only. Credentials,
  // one-time codes, and payment fields are never typed into.
  const TEXT_INPUT_TYPES = ["", "text", "search", "email", "url", "tel", "number"];
  const SENSITIVE_HINT = /(otp|one.?time|verification.?code|2fa|mfa|totp|cvv|cvc|card.?num|cc.?num|credit.?card|iban|ssn|social.?security|pin\b|security.?code)/i;

  function isEditable(el, info) {
    if (info.isProtected || el.disabled || el.readOnly || el.getAttribute("aria-disabled") === "true") return false;
    if (info.tagName === "input") {
      if (!TEXT_INPUT_TYPES.includes((el.getAttribute("type") || "").toLowerCase())) return false;
    } else if (info.tagName !== "textarea") {
      return false;
    }
    const autocomplete = (el.getAttribute("autocomplete") || "").toLowerCase();
    if (autocomplete.startsWith("cc-") || autocomplete.includes("one-time-code")) return false;
    const hints = [el.getAttribute("name"), el.id, el.getAttribute("aria-label"), el.getAttribute("placeholder"), info.label].join(" ");
    if (SENSITIVE_HINT.test(hints)) return false;
    const rect = el.getBoundingClientRect();
    const style = getComputedStyle(el);
    return rect.width > 0 && rect.height > 0 && style.visibility !== "hidden" && style.display !== "none";
  }

  // Phase 5B.3 select policy: single-choice, enabled, visible, not payment or
  // credential related.
  function isSelectable(el, info) {
    if (info.tagName !== "select" || el.multiple || el.disabled || info.isProtected) return false;
    if ((el.getAttribute("autocomplete") || "").toLowerCase().startsWith("cc-")) return false;
    const hints = [el.getAttribute("name"), el.id, el.getAttribute("aria-label"), info.label].join(" ");
    if (SENSITIVE_HINT.test(hints) || /(expir|exp.?month|exp.?year)/i.test(hints)) return false;
    const rect = el.getBoundingClientRect();
    return rect.width > 0 && rect.height > 0 && getComputedStyle(el).visibility !== "hidden";
  }

  function optionLabels(el) {
    return Array.from(el.options).filter((o) => !o.disabled).slice(0, 100)
      .map((o) => (o.label || o.text || "").trim().substring(0, 200));
  }

  function isScrollableElement(el) {
    const style = getComputedStyle(el);
    const y = /(auto|scroll)/.test(style.overflowY) && el.scrollHeight > el.clientHeight + 1;
    const x = /(auto|scroll)/.test(style.overflowX) && el.scrollWidth > el.clientWidth + 1;
    const rect = el.getBoundingClientRect();
    return (x || y) && rect.width > 0 && rect.height > 0;
  }

  function scrollRegionLabel(el) {
    const named = el.getAttribute("aria-label") || (el.labels && el.labels[0] && el.labels[0].innerText);
    return (named || (el.innerText || "").trim().split("\n")[0] || "Scrollable region").trim().substring(0, 120);
  }

  // Real pages use open shadow roots (web components); search into them too.
  function deepQueryAll(selector, root = document, out = []) {
    out.push(...root.querySelectorAll(selector));
    for (const host of root.querySelectorAll("*")) {
      if (host.shadowRoot) deepQueryAll(selector, host.shadowRoot, out);
    }
    return out;
  }

  // elementFromPoint stops at shadow hosts; descend to the real target.
  function deepElementFromPoint(x, y) {
    let el = document.elementFromPoint(x, y);
    while (el && el.shadowRoot) {
      const inner = el.shadowRoot.elementFromPoint(x, y);
      if (!inner || inner === el) break;
      el = inner;
    }
    return el;
  }

  function deepActiveElement() {
    let active = document.activeElement;
    while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
    return active;
  }

  function isRendered(el, rect) {
    if (rect.width <= 0 || rect.height <= 0) return false;
    const style = getComputedStyle(el);
    return style.visibility !== "hidden" && style.display !== "none";
  }

  // The page's readable text (what a person reads: titles, dates, prices),
  // capped. innerText excludes form field values, which stay unread.
  function visibleText() {
    const raw = (document.body && document.body.innerText) || "";
    const lines = raw.split("\n").map((line) => line.trim()).filter(Boolean);
    let text = "";
    for (const line of lines) {
      const room = 8000 - text.length;
      if (room <= 1) break;
      // A long line is cut at the cap rather than dropped.
      text += line.substring(0, room - 1) + "\n";
    }
    return text;
  }

  function observe(generationID) {
    currentGeneration = generationID;
    const elements = [];
    // Large pages have thousands of controls: list only rendered ones, those
    // on screen first (top to bottom), then the rest by distance from view.
    const candidates = deepQueryAll("button, input, select, textarea, a[href], h1, h2, h3, [role='button'], [role='textbox']")
      .map((el) => ({ el, rect: el.getBoundingClientRect() }))
      .filter(({ el, rect }) => isRendered(el, rect))
      .map(({ el, rect }) => {
        const onScreen = rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth;
        const distance = onScreen ? 0 : rect.top >= innerHeight ? rect.top - innerHeight : -rect.bottom;
        return { el, rect, onScreen, distance };
      })
      .sort((a, b) => (a.onScreen === b.onScreen ? 0 : a.onScreen ? -1 : 1) ||
        (a.onScreen ? a.rect.top - b.rect.top : a.distance - b.distance));
    for (const { el, rect } of candidates) {
      if (elements.length >= 200) break; // Strict upper bound per observation
      const info = describe(el);
      elements.push({
        elementID: referenceFor(el, generationID),
        tagName: info.tagName,
        role: info.role,
        label: info.label,
        isProtected: info.isProtected,
        isEnabled: !el.disabled,
        isActionable: isActionable(el, info),
        ...(() => {
          const c = classify(el, info);
          return {
            actionKind: c.kind || undefined,
            blockedReason: c.reason || undefined,
            destinationURL: c.destination || undefined,
            formFields: c.kind === "submit" ? c.formFields : undefined
          };
        })(),
        isEditable: isEditable(el, info),
        isSelectable: isSelectable(el, info),
        isScrollable: false,
        options: info.tagName === "select" && isSelectable(el, info) ? optionLabels(el) : undefined,
        bounds: {
          x: Math.max(0, rect.x),
          y: Math.max(0, rect.y),
          width: Math.max(0, rect.width),
          height: Math.max(0, rect.height)
        }
      });
    }
    // Scrollable regions (lists, panes) are reported separately, at most 20.
    let regions = 0;
    for (const el of deepQueryAll("div, section, main, aside, nav, article, ul, ol, pre, textarea")) {
      if (elements.length >= 200 || regions >= 20) break;
      if (!isScrollableElement(el) || el.tagName.toLowerCase() === "textarea") continue;
      const rect = el.getBoundingClientRect();
      elements.push({
        elementID: referenceFor(el, generationID),
        tagName: el.tagName.toLowerCase(),
        role: "scrollable region",
        label: scrollRegionLabel(el),
        isProtected: false,
        isEnabled: true,
        isActionable: false,
        isEditable: false,
        isSelectable: false,
        isScrollable: true,
        bounds: { x: Math.max(0, rect.x), y: Math.max(0, rect.y), width: Math.max(0, rect.width), height: Math.max(0, rect.height) }
      });
      regions++;
    }
    return elements;
  }

  function fingerprintMatches(el, expected) {
    const info = describe(el);
    const role = isScrollableElement(el) && expected.role === "scrollable region" ? "scrollable region" : info.role;
    const label = role === "scrollable region" ? scrollRegionLabel(el) : info.label;
    return info.tagName === expected.tagName && role === expected.role && label === expected.label;
  }

  // Select: set the approved option and dispatch input/change, as browser
  // automation frameworks do (native select popups are not reliably drivable
  // with input events). Only a match/no-match result leaves the page.
  function applySelect(request) {
    const ref = elementsByID.get(request.elementID);
    const el = ref && ref.deref();
    if (!el || !el.isConnected) return { error: "elementChanged", message: "The dropdown is no longer on the page." };
    const info = describe(el);
    if (!fingerprintMatches(el, request.expected || {})) return { error: "elementChanged", message: "The dropdown changed after approval." };
    if (!isSelectable(el, info)) return { error: "elementNotActionable", message: "The dropdown is not an enabled single-choice dropdown." };
    const index = Array.from(el.options).findIndex((o) => !o.disabled && (o.label || o.text || "").trim() === request.option);
    if (index < 0) return { error: "elementChanged", message: "The approved option is no longer offered." };
    el.selectedIndex = index;
    el.dispatchEvent(new Event("input", { bubbles: true }));
    el.dispatchEvent(new Event("change", { bubbles: true }));
    const selected = el.selectedOptions[0];
    return { matched: Boolean(selected) && (selected.label || selected.text || "").trim() === request.option };
  }

  // Scroll: report the wheel point for the page (viewport centre) or for one
  // approved scrollable region, after a hit test; then compare positions.
  let pendingScroll = null;

  function scrollPosition(el) {
    return el ? [el.scrollLeft, el.scrollTop] : [window.scrollX, window.scrollY];
  }

  async function prepareScroll(request) {
    let el = null;
    if (request.elementID) {
      const ref = elementsByID.get(request.elementID);
      el = ref && ref.deref();
      if (!el || !el.isConnected) return { error: "elementChanged", message: "The scrollable region is no longer on the page." };
      if (!fingerprintMatches(el, request.expected || {}) || !isScrollableElement(el)) {
        return { error: "elementChanged", message: "The scrollable region changed after approval." };
      }
      const rect = el.getBoundingClientRect();
      if (rect.bottom < 0 || rect.top > innerHeight || rect.right < 0 || rect.left > innerWidth) {
        el.scrollIntoView({ block: "center", behavior: "instant" });
      }
    }
    await nextFrame();
    await nextFrame();
    let x = innerWidth / 2, y = innerHeight / 2;
    if (el) {
      const rect = el.getBoundingClientRect();
      x = rect.left + rect.width / 2;
      y = rect.top + rect.height / 2;
      const hit = deepElementFromPoint(x, y);
      if (!hit || !el.contains(hit)) return { error: "elementChanged", message: "Another element covers the scrollable region." };
    }
    pendingScroll = { el, before: scrollPosition(el) };
    return { x, y };
  }

  async function scrollOutcome() {
    const pending = pendingScroll;
    pendingScroll = null;
    if (!pending) return { moved: false };
    for (let i = 0; i < 30; i++) {
      const now = scrollPosition(pending.el);
      if (now[0] !== pending.before[0] || now[1] !== pending.before[1]) return { moved: true };
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    return { moved: false };
  }

  // Chrome pauses requestAnimationFrame in background tabs, so never wait on
  // it alone: the next frame or 50 ms, whichever comes first.
  const nextFrame = () => new Promise((resolve) => {
    let done = false;
    const finish = () => { if (!done) { done = true; resolve(); } };
    requestAnimationFrame(finish);
    setTimeout(finish, 50);
  });

  // Armed for exactly one approved click: any click sequence that lands outside
  // the approved element is blocked, and whether the trusted click reached the
  // element is recorded for verification.
  let armedGuard = null;

  function disarm() {
    if (!armedGuard) return;
    for (const type of ["pointerdown", "mousedown", "pointerup", "mouseup", "click"]) {
      window.removeEventListener(type, armedGuard.listener, true);
    }
    if (armedGuard.submitListener && armedGuard.target.form) {
      armedGuard.target.form.removeEventListener("submit", armedGuard.submitListener, true);
    }
    clearTimeout(armedGuard.timer);
    armedGuard = null;
  }

  function arm(el) {
    disarm();
    const guard = { target: el, landed: false, misdirected: false, submitted: false, listener: null, submitListener: null, timer: 0 };
    if (el.form) {
      guard.submitListener = (event) => {
        if (event.target !== el.form || !event.isTrusted) return;
        guard.submitted = true;
        // The document may unload right after this; tell the worker first.
        chrome.runtime.sendMessage({ action: "haloSubmitted" }).catch(() => {});
      };
      // submit does not cross shadow boundaries; listen on the form itself.
      el.form.addEventListener("submit", guard.submitListener, true);
    }
    guard.listener = (event) => {
      if (!event.isTrusted) return;
      // Events from inside shadow roots are retargeted to the host at window
      // level; the composed path still contains the real target.
      if (event.composedPath().includes(el)) {
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
    const classification = classify(el, info);
    const expectedKind = expected.kind || "button";
    if (!classification.kind || classification.kind !== expectedKind ||
        (classification.destination || null) !== (expected.destination || null)) {
      return { error: classification.kind ? "elementChanged" : "elementNotActionable",
               message: classification.kind ? "What the element does changed after approval." : "The element is not clickable under the current policy." };
    }

    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    // Let layout settle (including the debugger infobar) before measuring.
    await nextFrame();
    await nextFrame();
    const rect = el.getBoundingClientRect();
    const x = rect.left + rect.width / 2;
    const y = rect.top + rect.height / 2;
    const hit = deepElementFromPoint(x, y);
    if (!hit || !el.contains(hit)) {
      return { error: "elementChanged", message: "Another element covers the approved element at its click point." };
    }
    arm(el);
    return { x, y };
  }

  // Text entry: focus and select the approved field, then let the trusted
  // Input.insertText replace the selection. Afterwards only a match/no-match
  // result is reported; the field's value never leaves the page.
  let pendingType = null;

  async function prepareType(request) {
    const ref = elementsByID.get(request.elementID);
    const el = ref && ref.deref();
    if (!el || !el.isConnected) return { error: "elementChanged", message: "The field is no longer on the page." };
    const info = describe(el);
    const expected = request.expected || {};
    if (info.tagName !== expected.tagName || info.role !== expected.role || info.label !== expected.label) {
      return { error: "elementChanged", message: "The field changed after approval." };
    }
    if (!isEditable(el, info)) return { error: "elementNotActionable", message: "The field is not an editable plain text field." };
    el.scrollIntoView({ block: "center", inline: "center", behavior: "instant" });
    el.focus({ preventScroll: true });
    await nextFrame();
    if (deepActiveElement() !== el) return { error: "elementChanged", message: "The field could not be focused." };
    el.select();
    pendingType = el;
    return { ready: true };
  }

  chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "applySelect") {
      sendResponse(applySelect(request));
      return false;
    }
    if (request.action === "prepareScroll") {
      prepareScroll(request).then(sendResponse, (err) => sendResponse({ error: "internalError", message: String(err && err.message) }));
      return true;
    }
    if (request.action === "scrollOutcome") {
      scrollOutcome().then(sendResponse);
      return true;
    }
    if (request.action === "prepareType") {
      prepareType(request).then(sendResponse, (err) => sendResponse({ error: "internalError", message: String(err && err.message) }));
      return true;
    }
    if (request.action === "typeFocusHeld") {
      sendResponse({ held: Boolean(pendingType) && deepActiveElement() === pendingType });
      return false;
    }
    if (request.action === "typeOutcome") {
      const el = pendingType;
      pendingType = null;
      sendResponse({ matched: Boolean(el) && el.isConnected && el.value === request.text });
      return false;
    }
    if (request.action === "observe") {
      sendResponse({ elements: observe(request.generationID || 1), text: visibleText() });
      return false;
    }
    if (request.action === "prepareClick") {
      prepareClick(request).then(sendResponse, (err) => sendResponse({ error: "internalError", message: String(err && err.message) }));
      return true;
    }
    if (request.action === "clickOutcome") {
      const guard = armedGuard;
      const outcome = guard ? { landed: guard.landed, misdirected: guard.misdirected, submitted: guard.submitted }
        : { landed: false, misdirected: false, submitted: false };
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
