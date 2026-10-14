// Option-click (Alt-click) an image or video to save it, or drag it onto a collection in the panel that appears.
// Reads nothing else on the page.
"use strict";
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  let enabled = true;
  Promise.resolve(api.storage.local.get("altClick")).then(({ altClick } = {}) => { enabled = altClick !== false; }, () => {});
  api.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.altClick) enabled = changes.altClick.newValue !== false;
  });

  // Overlays often sit on top of images, so look through everything under the pointer.
  function mediaAt(event) {
    const stack = typeof document.elementsFromPoint === "function" ? document.elementsFromPoint(event.clientX, event.clientY) : [];
    for (const element of [event.target, ...stack]) {
      const tag = element?.tagName;
      if (tag === "IMG" || tag === "VIDEO") return element;
      if (tag === "PICTURE") { const img = element.querySelector("img"); if (img) return img; }
    }
    return null;
  }

  function source(element) {
    if (element.tagName === "IMG") return element.currentSrc || element.src;
    return element.currentSrc || element.src || element.querySelector("source[src]")?.src || element.poster || "";
  }

  function acknowledge(element) {
    const { outline, outlineOffset } = element.style;
    element.style.outline = "3px solid #1f7a4d"; element.style.outlineOffset = "-3px";
    setTimeout(() => { element.style.outline = outline; element.style.outlineOffset = outlineOffset; }, 600);
  }

  // Dragging a picture or video shows your collections at the side of the page; dropping on one saves it there.
  // The panel lives in a closed shadow root, so the page's own scripts can't read the collection names.
  let dropping = true, panel = null, dragged = null;
  Promise.resolve(api.storage.local.get("dragPanel")).then(({ dragPanel } = {}) => { dropping = dragPanel !== false; }, () => {});
  api.storage.onChanged.addListener((changes, area) => {
    if (area === "local" && changes.dragPanel) dropping = changes.dragPanel.newValue !== false;
  });
  const css = `
    :host { all: initial; }
    .panel { position: fixed; top: 50%; right: 16px; transform: translateY(-50%); z-index: 2147483647; width: 220px;
      padding: 10px; border-radius: 14px; background: rgba(28,28,30,.92); color: #f2f2f2; box-shadow: 0 12px 40px rgba(0,0,0,.35);
      font: 13px -apple-system, system-ui, sans-serif; -webkit-backdrop-filter: blur(20px); backdrop-filter: blur(20px); }
    .title { font-weight: 600; font-size: 11px; color: rgba(242,242,242,.6); margin: 2px 6px 8px; letter-spacing: .02em; }
    .target { padding: 10px 12px; border-radius: 9px; margin-top: 4px; background: rgba(255,255,255,.06); white-space: nowrap;
      overflow: hidden; text-overflow: ellipsis; transition: background .12s; }
    .target.over { background: #2f6fde; color: white; }
    .done { padding: 10px 12px; color: #7ad39b; }`;
  function hidePanel() { panel?.host.remove(); panel = null; dragged = null; }
  async function showPanel() {
    const host = document.createElement("div"), root = host.attachShadow({ mode: "closed" });
    const style = document.createElement("style"); style.textContent = css;
    const box = document.createElement("div"); box.className = "panel";
    const title = document.createElement("div"); title.className = "title"; title.textContent = "Drop on a collection to save to Folio";
    box.append(title); root.append(style, box);
    document.documentElement.append(host); panel = { host, box };
    const result = await Promise.resolve(api.runtime.sendMessage({ type: "dropTargets" })).catch(() => null);
    if (!panel || panel.box !== box) return;
    for (const name of result?.collections || ["Inbox"]) {
      const target = document.createElement("div"); target.className = "target"; target.textContent = name;
      target.addEventListener("dragenter", (e) => { e.preventDefault(); target.classList.add("over"); });
      target.addEventListener("dragover", (e) => { e.preventDefault(); e.dataTransfer.dropEffect = "copy"; });
      target.addEventListener("dragleave", () => target.classList.remove("over"));
      target.addEventListener("drop", (e) => {
        e.preventDefault(); e.stopPropagation();
        const media = dragged;
        if (media) Promise.resolve(api.runtime.sendMessage({ type: "saveMedia", ...media, collection: name })).catch(() => {});
        box.replaceChildren(Object.assign(document.createElement("div"), { className: "done", textContent: "Saved to " + name }));
        setTimeout(hidePanel, 700);
      });
      box.append(target);
    }
  }
  addEventListener("dragstart", (event) => {
    if (!dropping || !event.isTrusted) return;
    const element = event.target?.tagName === "IMG" || event.target?.tagName === "VIDEO" ? event.target : null;
    const url = element ? source(element) : "";
    if (!element || !/^https?:\/\//i.test(url)) return;
    hidePanel();
    dragged = { kind: element.tagName === "VIDEO" ? "video" : "image", url, title: (element.getAttribute("alt") || element.getAttribute("title") || "").trim() };
    showPanel();
  }, true);
  addEventListener("dragend", () => setTimeout(() => { if (panel && !panel.box.querySelector(".done")) hidePanel(); }, 50), true);

  addEventListener("click", (event) => {
    if (!enabled || !event.isTrusted || !event.altKey || event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey) return;
    const element = mediaAt(event);
    if (!element) return;
    event.preventDefault(); event.stopImmediatePropagation();
    acknowledge(element);
    const video = element.tagName === "VIDEO" && !!(element.currentSrc || element.src || element.querySelector("source[src]"));
    Promise.resolve(api.runtime.sendMessage({
      type: "saveMedia", kind: video ? "video" : "image", url: source(element),
      title: (element.getAttribute("alt") || element.getAttribute("title") || "").trim()
    })).catch(() => {});
  }, true);
})();
