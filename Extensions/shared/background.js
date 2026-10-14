// Runs as the Firefox background script and the Chrome service worker.
"use strict";
const api = globalThis.browser ?? globalThis.chrome;
const action = api.action ?? api.browserAction;
const ENDPOINT = "http://127.0.0.1:53187";
const KEY = /^[a-f0-9]{64}$/;
let badgeTimer;

async function callApp(path, payload) {
  const { key } = await api.storage.local.get("key");
  if (!KEY.test(key || "")) throw new Error("Connect the extension first: copy the key from Folio and paste it in the extension settings.");
  const timeout = new AbortController();
  const timer = setTimeout(() => timeout.abort(), 150000);
  let response;
  try {
    response = await fetch(ENDPOINT + path, {
      method: payload ? "POST" : "GET",
      headers: { Authorization: "Bearer " + key, ...(payload ? { "Content-Type": "application/json" } : {}) },
      ...(payload ? { body: JSON.stringify(payload) } : {}),
      signal: timeout.signal, cache: "no-store", credentials: "omit"
    });
  } catch (error) {
    if (error?.name === "AbortError") throw new Error("Folio took too long to respond.");
    const closed = new Error("Open Folio on this Mac, then try again.");
    closed.offline = true; // Folio isn't running: saves can wait for it.
    throw closed;
  } finally { clearTimeout(timer); }
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(result.error || "Folio could not save this item.");
  return result;
}

async function flash(ok) {
  clearTimeout(badgeTimer);
  try {
    await action.setBadgeBackgroundColor({ color: ok ? "#1f7a4d" : "#c0392b" });
    await action.setBadgeText({ text: ok ? "✓" : "!" });
  } catch (_) { /* Badges are optional, for example on Android. */ }
  badgeTimer = setTimeout(() => { Promise.resolve(action.setBadgeText({ text: "" })).catch(() => {}); }, 3000);
}

function notify(message) {
  if (!api.notifications) return;
  Promise.resolve(api.notifications.create("folio-" + Date.now(), {
    type: "basic", iconUrl: api.runtime.getURL("icons/icon-128.png"), title: "Not saved to Folio", message
  })).catch(() => {});
}

// Saves made while Folio is closed wait here and go in the next time it answers.
const QUEUE_LIMIT = 50;
async function enqueue(payload) {
  const { queue = [] } = await api.storage.local.get("queue");
  // A big page screenshot is left behind so the queue fits in the extension's storage; the page is still saved.
  const item = payload.snapshot && payload.snapshot.length > 1500000 ? { ...payload, snapshot: undefined } : payload;
  await api.storage.local.set({ queue: [...queue, item].slice(-QUEUE_LIMIT) });
}
let flushing = false;
async function flushQueue() {
  if (flushing) return;
  flushing = true;
  try {
    let { queue = [] } = await api.storage.local.get("queue");
    while (queue.length) {
      try { await callApp("/save", queue[0]); } catch (error) { if (error.offline) break; }
      queue = queue.slice(1);
      await api.storage.local.set({ queue });
    }
  } finally { flushing = false; }
}

async function save(payload, { quiet = false } = {}) {
  try {
    const result = await callApp("/save", payload);
    await flash(true);
    flushQueue();
    return result;
  } catch (error) {
    if (error.offline) {
      await enqueue(payload);
      await flash(true);
      if (!quiet && api.notifications) {
        Promise.resolve(api.notifications.create("folio-" + Date.now(), {
          type: "basic", iconUrl: api.runtime.getURL("icons/icon-128.png"), title: "Saved for later",
          message: "Folio isn't open. This goes into your library the next time it is."
        })).catch(() => {});
      }
      return { queued: true };
    }
    await flash(false);
    if (!quiet) notify(error.message);
    throw error;
  }
}

async function lastCollection() {
  const { collection } = await api.storage.local.get("collection");
  return typeof collection === "string" && collection.trim() ? collection : "Inbox";
}

async function savePage(tab, collection, options) {
  if (!tab || !/^https?:\/\//i.test(tab.url || "")) {
    const error = new Error("Only web pages can be saved.");
    if (!options?.quiet) notify(error.message);
    await flash(false);
    throw error;
  }
  let snapshot;
  try {
    const data = await api.tabs.captureVisibleTab(tab.windowId, { format: "jpeg", quality: 80 });
    if (typeof data === "string" && data.length < 11 * 1024 * 1024) snapshot = data.split(",")[1];
  } catch (_) { /* Without a screenshot the page is saved as a link. */ }
  return save({ kind: "page", url: tab.url, source: tab.url, title: tab.title || "", collection, snapshot }, options);
}

async function saveMedia(kind, url, page, title, options, collection) {
  if (!/^https?:\/\//i.test(url || "")) {
    const error = new Error("This " + kind + " has no web address Folio can download.");
    if (!options?.quiet) notify(error.message);
    await flash(false);
    throw error;
  }
  return save({ kind, url, source: page || "", title: title || "", collection: collection || await lastCollection() }, options);
}

let menus = Promise.resolve();
function setupMenus() {
  // Serialized so overlapping install and startup events cannot create duplicate items.
  menus = menus.then(async () => {
    if (!api.contextMenus) return; // Firefox for Android has no context menus.
    await api.contextMenus.removeAll();
    // Each kind saves to the last collection in one click, or to any collection from "Save … to".
    // The list comes from Folio when it's open; without it, only the one-click items show.
    let names = [];
    try { names = (await callApp("/collections")).collections || []; } catch (_) {}
    names = ["Inbox", ...names.filter((name) => name !== "Inbox")].slice(0, 30);
    for (const [id, noun, contexts] of [
      ["image", "image", ["image"]],
      ["video", "video", ["video"]],
      ["link", "link", ["link"]],
      ["page", "page", ["page"]]
    ]) {
      api.contextMenus.create({ id, title: "Save " + noun + " to Folio", contexts }, () => void api.runtime.lastError);
      if (names.length < 2) continue;
      api.contextMenus.create({ id: id + "-to", title: "Save " + noun + " to", contexts }, () => void api.runtime.lastError);
      for (const name of names) {
        api.contextMenus.create({ id: id + "@" + name, parentId: id + "-to", title: name, contexts }, () => void api.runtime.lastError);
      }
    }
  }).catch(() => {});
  return menus;
}

async function onMenu(info, tab) {
  const page = info.pageUrl || tab?.url || "";
  const [kind, chosen] = String(info.menuItemId).split("@");
  // A collection picked from "Save … to" becomes the one the next quick save uses.
  if (chosen) await api.storage.local.set({ collection: chosen });
  const collection = chosen || await lastCollection();
  if (kind === "page") return savePage(tab, collection);
  if (kind === "link") {
    return save({ kind: "link", url: info.linkUrl, source: page, title: info.linkText || "", collection });
  }
  return saveMedia(kind === "video" ? "video" : "image", info.srcUrl, page, "", undefined, collection);
}

async function onMessage(message, sender) {
  if (sender.id !== api.runtime.id) throw new Error("Unknown request");
  const fromExtensionPage = (sender.url || "").startsWith(api.runtime.getURL(""));
  // Content scripts may only ask to save the image or video the person Option-clicked or dropped on a collection,
  // and for the collection names to drop onto.
  if (!fromExtensionPage && sender.tab && message?.type === "saveMedia") {
    const collection = typeof message.collection === "string" && message.collection.trim() ? message.collection.trim().slice(0, 200) : undefined;
    if (collection) await api.storage.local.set({ collection });
    return saveMedia(message.kind === "video" ? "video" : "image", String(message.url || ""), sender.tab.url || sender.url, String(message.title || "").slice(0, 500), undefined, collection);
  }
  if (!fromExtensionPage && sender.tab && message?.type === "dropTargets") {
    let names = [];
    try { names = (await callApp("/collections")).collections || []; } catch (_) {}
    const last = await lastCollection();
    return { collections: [last, ...["Inbox", ...names].filter((name) => name !== last)].slice(0, 12) };
  }
  if (!fromExtensionPage) throw new Error("Unknown request");
  switch (message?.type) {
    case "health": { const result = await callApp("/health"); flushQueue(); return result; }
    case "collections": {
      let collections;
      try { collections = await callApp("/collections"); }
      catch (error) {
        // With Folio closed the popup can still save, for later, to the collection used last.
        if (error.offline) return { offline: true, collections: [], last: await lastCollection() };
        throw error;
      }
      const result = { ...collections, last: await lastCollection() };
      setupMenus(); // keep the right-click list in step with Folio's collections
      return result;
    }
    case "savePage": {
      const collection = String(message.collection || "").trim() || "Inbox";
      await api.storage.local.set({ collection });
      const [tab] = await api.tabs.query({ active: true, currentWindow: true });
      return savePage(tab, collection, { quiet: true });
    }
    default: throw new Error("Unknown request");
  }
}

api.runtime.onInstalled.addListener(setupMenus);
api.runtime.onStartup.addListener(setupMenus);
api.runtime.onStartup.addListener(() => { flushQueue().catch(() => {}); });
// Firefox background pages are not service workers and do not keep menus across restarts on their own.
if (typeof ServiceWorkerGlobalScope === "undefined") setupMenus();
api.contextMenus?.onClicked.addListener((info, tab) => { onMenu(info, tab).catch(() => {}); });
api.commands?.onCommand.addListener(async (command) => {
  if (command !== "save-page") return;
  try {
    const [tab] = await api.tabs.query({ active: true, currentWindow: true });
    await savePage(tab, await lastCollection());
  } catch (_) { /* Already reported with a badge and notification. */ }
});
api.runtime.onMessage.addListener((message, sender, sendResponse) => {
  onMessage(message, sender).then(
    (result) => sendResponse({ ok: true, ...result }),
    (error) => sendResponse({ ok: false, error: error.message })
  );
  return true;
});
