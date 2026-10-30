// Toolbelt Downloads: hands Chrome's downloads to Toolbelt on this Mac.
// Messages go to ToolbeltBridge (a small program inside Toolbelt.app) through Chrome's
// "native messaging", which only this extension is allowed to use.

const HOST = "local.personal.toolbelt";
const DEFAULTS = { enabled: true, minSizeMB: 0 };

async function settings() {
  return { ...DEFAULTS, ...(await chrome.storage.local.get(Object.keys(DEFAULTS))) };
}

function canHandOver(url) {
  // blob: and data: links only exist inside the page, so Chrome has to download those itself.
  return /^(https?|ftp):/i.test(url || "");
}

async function cookiesFor(url) {
  try {
    const cookies = await chrome.cookies.getAll({ url });
    return cookies.map((c) => `${c.name}=${c.value}`).join("; ");
  } catch {
    return "";
  }
}

// Sends one link to Toolbelt. Resolves to true when Toolbelt has it.
async function sendToToolbelt(url, { referrer = "", name = "" } = {}) {
  const message = {
    type: "download",
    url,
    name,
    referrer,
    cookies: await cookiesFor(url),
    userAgent: navigator.userAgent,
  };
  return new Promise((resolve) => {
    chrome.runtime.sendNativeMessage(HOST, message, (reply) => {
      resolve(!chrome.runtime.lastError && !!reply && reply.ok === true);
    });
  });
}

// Every download Chrome starts goes to Toolbelt instead, unless it's switched off, too small,
// or Toolbelt can't be reached (then Chrome carries on as usual).
chrome.downloads.onCreated.addListener(async (item) => {
  const url = item.finalUrl || item.url;
  if (!canHandOver(url) || item.byExtensionId === chrome.runtime.id) return;
  const { enabled, minSizeMB } = await settings();
  if (!enabled) return;
  if (minSizeMB > 0 && item.totalBytes > 0 && item.totalBytes < minSizeMB * 1024 * 1024) return;
  if (await sendToToolbelt(url, { referrer: item.referrer })) {
    chrome.downloads.cancel(item.id, () => {
      void chrome.runtime.lastError;
      chrome.downloads.erase({ id: item.id });
    });
  }
});

// Right-click a link, picture, video or sound: "Download with Toolbelt".
chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: "toolbelt-download",
    title: "Download with Toolbelt",
    contexts: ["link", "image", "video", "audio"],
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  const url = info.linkUrl || info.srcUrl;
  if (canHandOver(url)) sendToToolbelt(url, { referrer: info.pageUrl || (tab && tab.url) || "" });
});

// From the video button (video.js) and the popup (popup.js).
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message && message.type === "video" && canHandOver(message.url)) {
    sendToToolbelt(message.url, { referrer: message.referrer, name: message.name }).then((ok) => reply({ ok }));
    return true;
  }
  if (message && message.type === "ping") {
    chrome.runtime.sendNativeMessage(HOST, { type: "ping" }, (answer) => {
      reply({ ok: !chrome.runtime.lastError && !!answer && answer.ok === true });
    });
    return true;
  }
  return false;
});
