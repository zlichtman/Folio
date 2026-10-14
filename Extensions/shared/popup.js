"use strict";
const api = globalThis.browser ?? globalThis.chrome;
const status = document.getElementById("status"), saveButton = document.getElementById("save");
const select = document.getElementById("collection"), field = document.getElementById("new-collection");
const send = (message) => Promise.resolve(api.runtime.sendMessage(message)).catch((error) => ({ ok: false, error: error.message }));

Promise.resolve(api.storage.local.get("altClick")).then(({ altClick } = {}) => {
  document.getElementById("alt-hint").hidden = altClick === false;
}, () => {});
document.getElementById("settings").onclick = () => { api.runtime.openOptionsPage(); window.close(); };

function option(name) {
  const element = document.createElement("option");
  element.textContent = name;
  return element;
}
function newOption() {
  const element = option("New collection…");
  element.dataset.new = "1";
  return element;
}

const creating = () => select.selectedOptions[0]?.dataset.new === "1";
const chosen = () => creating() ? field.value.trim() : select.value;
function update() {
  field.hidden = !creating();
  saveButton.disabled = !chosen();
}

select.onchange = () => { update(); if (!field.hidden) field.focus(); };
field.oninput = update;
field.onkeydown = (event) => { if (event.key === "Enter" && !saveButton.disabled) saveButton.click(); };

(async () => {
  const result = await send({ type: "collections" });
  if (!result?.ok) { status.textContent = result?.error || "Open Folio on this Mac, then try again."; return; }
  const names = result.collections.includes(result.last) ? result.collections : [...result.collections, result.last];
  select.replaceChildren(...names.map(option), newOption());
  select.value = result.last;
  status.textContent = result.offline ? "Folio isn't open. Saves wait and go in when it is." : "Connected to Folio.";
  update();
})();

saveButton.onclick = async () => {
  const collection = chosen();
  if (!collection) return;
  saveButton.disabled = true; status.textContent = "Saving…";
  const result = await send({ type: "savePage", collection });
  status.textContent = result?.queued ? "Saved for later. It goes into " + collection + " when Folio opens."
    : result?.ok ? "Saved to " + (result.collection || collection) + "." : result?.error || "Folio could not save this page.";
  if (result?.ok && creating()) {
    if (![...select.options].some((o) => !o.dataset.new && o.value === collection)) select.insertBefore(option(collection), select.lastElementChild);
    select.value = collection; field.value = "";
  }
  update();
};
