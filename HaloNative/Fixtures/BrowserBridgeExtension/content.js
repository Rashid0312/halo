// Minimal read-only content script for DOM structure observation
// Enforces strict password/sensitive value redaction and opaque element tokens.
chrome.runtime.onMessage.addListener((request, sender, sendResponse) => {
  if (request.action === "observe") {
    const generationID = request.generationID || 1;
    const elements = [];
    const candidates = document.querySelectorAll(
      "button, input, select, textarea, a[href], h1, h2, h3, [role='button'], [role='textbox']"
    );

    let count = 0;
    for (const el of candidates) {
      if (count >= 200) break; // Strict upper bound of 200 elements per observation

      const tagName = (el.tagName || "").toLowerCase();
      const type = (el.getAttribute("type") || el.type || "").toLowerCase();
      const role = (el.getAttribute("role") || "").toLowerCase();
      const name = (el.getAttribute("name") || "").toLowerCase();
      const autocomplete = (el.getAttribute("autocomplete") || "").toLowerCase();

      // 1. Identify protected / credential fields BEFORE reading any values
      const isProtected = (
        type === "password" ||
        role === "password" ||
        el.hasAttribute("data-protected") ||
        autocomplete.includes("password") ||
        autocomplete.includes("current-password") ||
        autocomplete.includes("new-password") ||
        autocomplete.includes("one-time-code") ||
        name.includes("password") ||
        name.includes("passwd") ||
        name.includes("secret") ||
        name.includes("token")
      );

      // 2. Extract label safely: NEVER read .value from a protected element
      let label = "";
      if (isProtected) {
        // Only accessible descriptions allowed; value is NEVER read
        label = (el.getAttribute("aria-label") || el.getAttribute("placeholder") || "").trim();
      } else {
        // Form values are user data, not labels. Never read `.value`, even for
        // fields that do not look like credentials.
        const textContent = el.innerText || "";
        const ariaLabel = el.getAttribute("aria-label") || "";
        const placeholder = el.getAttribute("placeholder") || "";
        label = (textContent || ariaLabel || placeholder).trim();
      }

      // Bound label length to protocol limit
      if (label.length > 32768) {
        label = label.substring(0, 32768);
      }

      const rect = el.getBoundingClientRect();
      const isEnabled = !el.disabled;

      // 3. Generate opaque, generation-bound token for elementID (not predictable index)
      const randomSuffix = typeof crypto !== "undefined" && crypto.randomUUID
        ? crypto.randomUUID().slice(0, 8)
        : Math.random().toString(36).slice(2, 10);
      const elementID = "el_" + generationID + "_" + randomSuffix + "_" + count;

      elements.push({
        elementID: elementID,
        tagName: tagName.substring(0, 128),
        role: role.substring(0, 128),
        label: label,
        isProtected: isProtected,
        isEnabled: isEnabled,
        bounds: {
          x: Math.max(0, rect.x),
          y: Math.max(0, rect.y),
          width: Math.max(0, rect.width),
          height: Math.max(0, rect.height)
        }
      });
      count++;
    }

    sendResponse({ elements: elements });
  }
  return true;
});

// Wake the MV3 service worker when an eligible fixture document loads. Service
// workers are intentionally ephemeral and must not rely on install-time startup.
chrome.runtime.sendMessage({ action: "ensureNativeConnection" }).catch(() => {});
