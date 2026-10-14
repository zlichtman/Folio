"use strict";
const api = globalThis.browser ?? globalThis.chrome;
const input = document.getElementById("key"), status = document.getElementById("status"), altClick = document.getElementById("alt-click");

Promise.resolve(api.storage.local.get(["key", "altClick"])).then(({ key, altClick: enabled }) => {
  input.value = key || ""; altClick.checked = enabled !== false;
});
altClick.onchange = () => api.storage.local.set({ altClick: altClick.checked });
const dragPanel = document.getElementById("drag-panel");
Promise.resolve(api.storage.local.get("dragPanel")).then(({ dragPanel: enabled } = {}) => { dragPanel.checked = enabled !== false; });
dragPanel.onchange = () => api.storage.local.set({ dragPanel: dragPanel.checked });

document.getElementById("connect").onclick = async () => {
  const key = input.value.trim().toLowerCase();
  if (!/^[a-f0-9]{64}$/.test(key)) { status.textContent = "Paste the complete 64-character key copied from Folio."; return; }
  await api.storage.local.set({ key });
  status.textContent = "Testing…";
  const result = await Promise.resolve(api.runtime.sendMessage({ type: "health" })).catch((error) => ({ ok: false, error: error.message }));
  status.textContent = result?.ok ? "Connected. Your library has " + result.items + (result.items === 1 ? " item." : " items.") : result?.error || "Open Folio on this Mac, then try again.";
};
