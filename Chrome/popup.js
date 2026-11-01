// The toolbar button's small window: on/off switch, a minimum size, whether Toolbelt answers,
// and "Download All Links on This Page…".
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

const allLinks = document.getElementById("allLinks");
const linksStatus = document.getElementById("linksStatus");
allLinks.addEventListener("click", async () => {
  const [tab] = await chrome.tabs.query({ active: true, currentWindow: true });
  if (!tab) return;
  allLinks.disabled = true;
  chrome.runtime.sendMessage({ type: "page-links", tabId: tab.id }, (reply) => {
    allLinks.disabled = false;
    if (reply && reply.ok) {
      linksStatus.textContent = `${reply.count} links sent to Toolbelt: tick the ones you want there.`;
      linksStatus.className = "ok";
    } else {
      linksStatus.textContent = (reply && reply.error) || "Toolbelt isn't answering.";
      linksStatus.className = "bad";
    }
  });
});
