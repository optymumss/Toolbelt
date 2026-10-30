// The toolbar button's small window: on/off switch, a minimum size, and whether Toolbelt answers.
const enabled = document.getElementById("enabled");
const minSize = document.getElementById("minSizeMB");
const status = document.getElementById("status");

chrome.storage.local.get({ enabled: true, minSizeMB: 0 }, (saved) => {
  enabled.checked = saved.enabled;
  minSize.value = saved.minSizeMB;
});
enabled.addEventListener("change", () => chrome.storage.local.set({ enabled: enabled.checked }));
minSize.addEventListener("change", () => chrome.storage.local.set({ minSizeMB: Math.max(0, Number(minSize.value) || 0) }));

chrome.runtime.sendMessage({ type: "ping" }, (reply) => {
  if (reply && reply.ok) {
    status.textContent = "✓ Connected to Toolbelt";
    status.className = "ok";
  } else {
    status.textContent = "Toolbelt isn't answering. In Toolbelt, open Settings › Downloads and click Set Up Chrome.";
    status.className = "bad";
  }
});
