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
  // One-click account changes on buttons and forms (GitHub Star, LinkedIn
  // Connect, YouTube Like). Anchored to the start of the label so ordinary
  // links such as "Videos you might like" stay clickable.
  const SOCIAL_WORDS = /^\s*(un)?(star|follow|like|dislike|upvote|downvote|vote|fork|watch|connect|join|repost|retweet|bookmark|favou?rite|save|pin|endorse|apply|easy apply|accept|invite|block|report|mute)\b/i;
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
      if (SOCIAL_WORDS.test(info.label)) return { reason: "account" };
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
      // A POST form with nothing visible to fill in only changes state on the
      // account (star, follow, like, delete); searches and filters use GET.
      const visibleFields = fields.filter((f) => !["hidden", "submit", "button", "image", "reset"].includes((f.type || "").toLowerCase()));
      if (method.toLowerCase() === "post" && visibleFields.length === 0) return { reason: "account" };
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
    if (SOCIAL_WORDS.test(info.label)) return { reason: "account" };
    return { kind: "button" };
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

  const OBSERVED = "button, input, select, textarea, a[href], h1, h2, h3, [role='button'], [role='textbox']";

  // Rendered elements matching `selector`, those on screen first (top to
  // bottom), then the rest by distance from view.
  function rendered(selector) {
    return deepQueryAll(selector)
      .map((el) => ({ el, rect: el.getBoundingClientRect() }))
      .filter(({ el, rect }) => isRendered(el, rect))
      .map(({ el, rect }) => {
        const onScreen = rect.bottom > 0 && rect.top < innerHeight && rect.right > 0 && rect.left < innerWidth;
        const distance = onScreen ? 0 : rect.top >= innerHeight ? rect.top - innerHeight : -rect.bottom;
        return { el, rect, onScreen, distance };
      })
      .sort((a, b) => (a.onScreen === b.onScreen ? 0 : a.onScreen ? -1 : 1) ||
        (a.onScreen ? a.rect.top - b.rect.top : a.distance - b.distance));
  }

  // One element as Halo receives it. Never includes form values.
  function record(el, rect, generationID) {
    const info = describe(el);
    const c = classify(el, info);
    const selectable = isSelectable(el, info);
    return {
      elementID: referenceFor(el, generationID),
      tagName: info.tagName,
      role: info.role,
      label: info.label,
      isProtected: info.isProtected,
      isEnabled: !el.disabled,
      isActionable: c.kind === "button",
      actionKind: c.kind || undefined,
      blockedReason: c.reason || undefined,
      destinationURL: c.destination || undefined,
      formFields: c.kind === "submit" ? c.formFields : undefined,
      isEditable: isEditable(el, info),
      isSelectable: selectable,
      isScrollable: false,
      options: info.tagName === "select" && selectable ? optionLabels(el) : undefined,
      bounds: {
        x: Math.max(0, rect.x),
        y: Math.max(0, rect.y),
        width: Math.max(0, rect.width),
        height: Math.max(0, rect.height)
      }
    };
  }

  function observe(generationID) {
    currentGeneration = generationID;
    const elements = [];
    // Large pages have thousands of controls: list only rendered ones.
    for (const { el, rect } of rendered(OBSERVED)) {
      if (elements.length >= 200) break; // Strict upper bound per observation
      elements.push(record(el, rect, generationID));
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

  // --- Settle and change reports -------------------------------------------
  // After an approved action the page is watched until it settles: some DOM
  // change and then QUIET_MS without one, or no change at all within
  // FIRST_CHANGE_MS (a canvas-only or no-op action), capped at MAX_SETTLE_MS.
  // Then only what changed is reported. Style-only attribute changes
  // (animations, hover) do not keep the page "busy". Mutations inside shadow
  // roots are not observed; the before/after comparison still covers them.
  const QUIET_MS = 300, FIRST_CHANGE_MS = 1000, MAX_SETTLE_MS = 3000;
  const CHANGES_BUDGET = 12000, MAX_CHANGED_ELEMENTS = 200, MAX_TEXT_LINES = 60;
  let mutations = 0, lastMutationAt = performance.now(), addedDuringAction = null;
  const watcher = new MutationObserver((records) => {
    let counted = false;
    for (const r of records) {
      if (r.type === "attributes" && r.attributeName === "style") continue;
      counted = true;
      if (addedDuringAction && r.type === "childList") {
        for (const node of r.addedNodes) if (node.nodeType === 1 && addedDuringAction.size < 5000) addedDuringAction.add(node);
      }
    }
    if (counted) { mutations++; lastMutationAt = performance.now(); }
  });
  watcher.observe(document, { subtree: true, childList: true, characterData: true, attributes: true });

  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  // Waits until the page settles after an action at `since` (performance.now()).
  // `busyUntil` marks when the action's network requests finished, if any:
  // their results usually reach the DOM just after, so quiet counts from then.
  async function settle(since, mutationsBefore, busyUntil = 0) {
    for (;;) {
      const now = performance.now();
      const changed = mutations !== mutationsBefore || busyUntil > 0;
      if (changed && now - Math.max(lastMutationAt, busyUntil) >= QUIET_MS) return { settled: true, ms: now - since };
      if (!changed && now - since >= FIRST_CHANGE_MS) return { settled: true, ms: now - since };
      if (now - since >= MAX_SETTLE_MS) return { settled: false, ms: now - since };
      await sleep(25);
    }
  }

  // Waits (bounded) for QUIET_MS without a mutation. A document that just
  // loaded may still be building itself; the script counts from its own start.
  async function quiet(maxMs) {
    const since = performance.now();
    while (performance.now() - lastMutationAt < QUIET_MS && performance.now() - since < maxMs) await sleep(25);
  }

  // What an element looks like to Halo, for comparing before and after.
  function signature(r) {
    return [r.tagName, r.role, r.label, r.isEnabled, r.actionKind, r.blockedReason, r.destinationURL,
      r.isEditable, r.isSelectable, (r.options || []).join("\u0001")].join("\u0002");
  }

  function snapshot(generationID) {
    const elements = new Map();
    for (const { el, rect } of rendered(OBSERVED)) {
      if (elements.size >= 1000) break;
      const r = record(el, rect, generationID);
      elements.set(r.elementID, r);
    }
    return { elements, text: visibleText().split("\n").filter(Boolean) };
  }

  let changeLog = null;

  // Called just before an approved action is performed.
  function beginChanges() {
    changeLog = { before: snapshot(currentGeneration), mutations, since: performance.now() };
    addedDuringAction = new Set();
  }

  function byteLength(value) { return new TextEncoder().encode(JSON.stringify(value)).length; }

  async function settleChanges(afterRequests) {
    const log = changeLog;
    changeLog = null;
    if (!log) return { error: "internalError", message: "No action is being watched." };
    const waited = await settle(log.since, log.mutations, afterRequests ? performance.now() : 0);
    const added = addedDuringAction || new Set();
    addedDuringAction = null;
    const after = snapshot(currentGeneration);
    const report = {
      title: (document.title || "").substring(0, 32768), added: [], modified: [], removed: [],
      transient: Array.from(added).filter((node) => !node.isConnected).length,
      textAdded: [], textRemoved: 0, truncated: false, settled: waited.settled,
      settleMs: Math.min(10000, Math.round(waited.ms)), domChanged: mutations !== log.mutations
    };
    let budget = CHANGES_BUDGET;
    const take = (list, item) => {
      const size = byteLength(item);
      if (report.added.length + report.modified.length >= MAX_CHANGED_ELEMENTS || size > budget) { report.truncated = true; return; }
      budget -= size;
      list.push(item);
    };
    // Changed elements first (a button's new label), then new ones, in page order.
    for (const [id, r] of after.elements) {
      const previous = log.before.elements.get(id);
      if (previous && signature(previous) !== signature(r)) take(report.modified, r);
    }
    for (const [id, r] of after.elements) if (!log.before.elements.has(id)) take(report.added, r);
    for (const id of log.before.elements.keys()) {
      if (!after.elements.has(id) && report.removed.length < MAX_CHANGED_ELEMENTS) report.removed.push(id);
    }
    // Text lines are compared as multisets so a repeated line counts once per copy.
    const counts = new Map();
    for (const line of log.before.text) counts.set(line, (counts.get(line) || 0) + 1);
    for (const line of after.text) {
      const left = counts.get(line) || 0;
      if (left > 0) { counts.set(line, left - 1); continue; }
      const cut = line.substring(0, 300);
      if (report.textAdded.length >= MAX_TEXT_LINES || cut.length + 4 > budget) { report.truncated = true; continue; }
      budget -= cut.length + 4;
      report.textAdded.push(cut);
    }
    for (const left of counts.values()) report.textRemoved += left;
    return report;
  }

  // --- Find by text or role ------------------------------------------------
  const ROLE_SELECTORS = {
    button: "button, [role='button'], input[type='button'], input[type='submit'], input[type='reset'], summary",
    link: "a[href], [role='link']",
    textbox: "input:not([type]), input[type='text'], input[type='search'], input[type='email'], input[type='url'], input[type='tel'], input[type='number'], textarea, [role='textbox'], [role='searchbox']",
    combobox: "select, [role='combobox'], [role='listbox']",
    checkbox: "input[type='checkbox'], [role='checkbox'], [role='switch']",
    radio: "input[type='radio'], [role='radio']",
    tab: "[role='tab']",
    menuitem: "[role='menuitem'], [role='option'], [role='menuitemcheckbox'], [role='menuitemradio']",
    heading: "h1, h2, h3, h4, h5, h6, [role='heading']"
  };
  const INTERACTIVE = Object.values(ROLE_SELECTORS).join(", ");
  // Plain containers that hold text (has-text matching when no role is given).
  const TEXT_HOLDERS = "li, td, th, label, p, span, div, dt, dd, figcaption, legend, strong, em, b";

  const normalize = (text) => (text || "").replace(/\s+/g, " ").trim().toLowerCase();

  // The name a person (or a screen reader) would use for the element. Form
  // fields are named by their labels, never their values.
  function accessibleName(el) {
    const labelledBy = (el.getAttribute("aria-labelledby") || "").split(/\s+/).filter(Boolean)
      .map((id) => (el.getRootNode().getElementById ? el.getRootNode().getElementById(id) : document.getElementById(id)))
      .filter(Boolean).map((node) => node.textContent).join(" ");
    const tag = (el.tagName || "").toLowerCase();
    const isField = ["input", "select", "textarea"].includes(tag);
    const buttonValue = tag === "input" && ["button", "submit", "reset"].includes((el.getAttribute("type") || "").toLowerCase()) ? el.value : "";
    const own = isField ? "" : el.textContent;
    return [el.getAttribute("aria-label"), labelledBy, buttonValue, own, el.labels && el.labels[0] && el.labels[0].textContent,
      el.getAttribute("title"), el.getAttribute("placeholder"), el.getAttribute("alt")]
      .map(normalize).filter(Boolean);
  }

  function find(query, generationID) {
    currentGeneration = generationID;
    const wanted = normalize(query.text);
    if (!wanted) return [];
    const selector = query.role ? ROLE_SELECTORS[query.role] : INTERACTIVE + ", " + TEXT_HOLDERS;
    if (!selector) return [];
    const scored = [];
    for (const el of deepQueryAll(selector)) {
      let best = 0;
      for (const name of accessibleName(el)) {
        const score = name === wanted ? 3 : query.exact ? 0 : name.startsWith(wanted) ? 2 : name.includes(wanted) ? 1 : 0;
        if (score > best) best = score;
      }
      if (!best) continue;
      const rect = el.getBoundingClientRect();
      if (!isRendered(el, rect)) continue;
      scored.push({ el, rect, best, interactive: el.matches(INTERACTIVE) });
      if (scored.length >= 2000) break;
    }
    // :has-text semantics: a container matches only when no element inside it
    // does, so the most specific element wins (the link, not its list item).
    const kept = scored.filter((a) => !scored.some((b) => b !== a && a.el.contains(b.el) && b.best >= a.best));
    const onScreen = (r) => r.bottom > 0 && r.top < innerHeight && r.right > 0 && r.left < innerWidth;
    kept.sort((a, b) => b.best - a.best || Number(b.interactive) - Number(a.interactive) ||
      Number(onScreen(b.rect)) - Number(onScreen(a.rect)) || a.rect.top - b.rect.top);
    return kept.slice(0, 20).map(({ el, rect }) => record(el, rect, generationID));
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
    beginChanges();
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
    beginChanges();
    pendingScroll = { el, before: scrollPosition(el) };
    return { x, y };
  }

  async function scrollOutcome() {
    const pending = pendingScroll;
    pendingScroll = null;
    if (!pending) return { moved: false };
    // Up to 2 s: smooth scrolling on a busy Mac can start late. Returns as soon as it moves.
    for (let i = 0; i < 100; i++) {
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
    beginChanges();
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
    beginChanges();
    pendingType = el;
    return { ready: true };
  }

  // Media control: the page's main video or audio is the largest visible
  // video, preferring one that is playing; an audio element counts when the
  // page has no video. Uses this world's media API, which page scripts can't
  // override. Play and full screen may need a user gesture, which the
  // background grants through the debugger before `mediaAfterGesture`.
  let pendingMedia = null;

  function mainMedia() {
    let best = null, bestScore = -1;
    for (const el of deepQueryAll("video, audio")) {
      const rect = el.getBoundingClientRect();
      const video = el.tagName === "VIDEO";
      if (video && !isRendered(el, rect)) continue;
      const score = (video ? rect.width * rect.height + 1 : 0.5) * (el.paused ? 1 : 4);
      if (score > bestScore) { best = el; bestScore = score; }
    }
    return best;
  }

  function mediaState(el) {
    return {
      kind: el.tagName === "VIDEO" ? "video" : "audio",
      paused: el.paused,
      muted: el.muted,
      volume: Math.min(1, Math.max(0, el.volume)),
      currentTime: Math.max(0, el.currentTime || 0),
      duration: Number.isFinite(el.duration) ? el.duration : null,
      fullscreen: Boolean(document.fullscreenElement)
    };
  }

  // The player around a video (same size, so the site's controls come along),
  // or the video itself.
  function playerContainer(el) {
    const rect = el.getBoundingClientRect();
    let container = el;
    for (let node = el.parentElement; node && node !== document.body && node !== document.documentElement; node = node.parentElement) {
      const r = node.getBoundingClientRect();
      if (r.width > rect.width * 1.15 + 4 || r.height > rect.height * 1.15 + 4) break;
      container = node;
    }
    return container;
  }

  function mediaPerformed(command, before, after, value) {
    switch (command) {
      case "play": return !after.paused;
      case "pause": return after.paused;
      case "toggle": return after.paused !== before.paused;
      case "mute": return after.muted;
      case "unmute": return !after.muted;
      case "volume": return Math.abs(after.volume - value) < 0.02 && (value === 0 || !after.muted);
      case "seek": {
        const moved = after.currentTime - before.currentTime;
        const atEnd = value > 0 ? after.duration !== null && after.currentTime >= after.duration - 1 : after.currentTime <= 1;
        return Math.sign(moved) === Math.sign(value) || atEnd;
      }
      case "fullscreen": return after.fullscreen;
      case "exit_fullscreen": return !after.fullscreen;
      default: return true;
    }
  }

  function withDeadline(promise, ms) {
    return Promise.race([promise, new Promise((resolve) => setTimeout(resolve, ms))]);
  }

  async function mediaApply(request) {
    const el = mainMedia();
    if (!el) return { error: "elementChanged", message: "This page has no video or audio playing or visible." };
    const before = mediaState(el);
    pendingMedia = { el, before, command: request.command, value: request.value };
    const finish = () => {
      const after = mediaState(el);
      pendingMedia = null;
      return { done: true, performed: mediaPerformed(request.command, before, after, request.value), state: after };
    };
    const command = request.command === "toggle" ? (el.paused ? "play" : "pause") : request.command;
    switch (command) {
      case "status": return finish();
      case "play":
        await withDeadline(el.play().catch(() => {}), 1500);
        return el.paused ? { needs: "gesture" } : finish();
      case "pause": el.pause(); return finish();
      case "mute": el.muted = true; return finish();
      case "unmute": el.muted = false; return finish();
      case "volume":
        el.volume = request.value;
        if (request.value > 0) el.muted = false;
        return finish();
      case "seek":
        // Netflix's player fails when its video's time is set directly; it
        // seeks 10 s per arrow key instead.
        if (/(^|\.)netflix\.com$/.test(location.hostname)) {
          return { needs: "keys", key: request.value > 0 ? "ArrowRight" : "ArrowLeft", presses: Math.min(30, Math.max(1, Math.round(Math.abs(request.value) / 10))) };
        }
        el.currentTime = Math.max(0, Math.min(Number.isFinite(el.duration) ? el.duration : Infinity, el.currentTime + request.value));
        await new Promise((resolve) => setTimeout(resolve, 150));
        return finish();
      case "fullscreen":
        return document.fullscreenElement ? finish() : { needs: "gesture" };
      case "exit_fullscreen":
        if (document.fullscreenElement) await withDeadline(document.exitFullscreen().catch(() => {}), 1500);
        return finish();
      default:
        pendingMedia = null;
        return { error: "payloadMalformed", message: "Unknown media command." };
    }
  }

  // Runs right after the background granted a user gesture, or pressed keys.
  async function mediaAfterGesture() {
    const pending = pendingMedia;
    pendingMedia = null;
    if (!pending || !pending.el.isConnected) return { error: "elementChanged", message: "The video or audio left the page." };
    const { el, before, command, value } = pending;
    const wanted = command === "toggle" ? (before.paused ? "play" : "pause") : command;
    if (wanted === "play") await withDeadline(el.play().catch(() => {}), 1500);
    if (wanted === "fullscreen" && !document.fullscreenElement) {
      await withDeadline(playerContainer(el).requestFullscreen().catch(() => {}), 1500);
    }
    if (wanted === "seek") await new Promise((resolve) => setTimeout(resolve, 400));
    const after = mediaState(el);
    return { done: true, performed: mediaPerformed(command, before, after, value), state: after };
  }

  chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
    if (request.action === "mediaApply") {
      mediaApply(request).then(sendResponse, (err) => sendResponse({ error: "internalError", message: String(err && err.message) }));
      return true;
    }
    if (request.action === "mediaAfterGesture") {
      mediaAfterGesture().then(sendResponse, (err) => sendResponse({ error: "internalError", message: String(err && err.message) }));
      return true;
    }
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
      // A document that just loaded may still be building itself: wait out
      // activity already under way (bounded) before reading it.
      const ready = request.settle ? quiet(2000) : Promise.resolve();
      ready.then(() => sendResponse({ elements: observe(request.generationID || 1), text: visibleText() }),
        (err) => sendResponse({ error: "internalError", message: String(err && err.message) }));
      return true;
    }
    if (request.action === "settleChanges") {
      settleChanges(Boolean(request.afterRequests)).then(sendResponse, (err) => sendResponse({ error: "internalError", message: String(err && err.message) }));
      return true;
    }
    if (request.action === "find") {
      sendResponse({ elements: find(request.query || {}, request.generationID || 1) });
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
