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
// `kind: "hls"` marks a streamed video's playlist; `quiet` keeps Toolbelt's list hidden (progress shows in the menu bar).
async function sendToToolbelt(url, { referrer = "", name = "", kind = "", audioUrl = "", quiet = false } = {}) {
  const message = {
    type: "download",
    url,
    name,
    referrer,
    cookies: await cookiesFor(url),
    userAgent: navigator.userAgent,
  };
  if (kind) message.kind = kind;
  if (audioUrl) message.audioUrl = audioUrl;
  if (quiet) message.quiet = true;
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

// ── Streamed videos ──────────────────────────────────────────────────────────────────────────
// Most video sites stream: the page fetches a playlist (.m3u8) listing the video at several sizes,
// then plays it piece by piece. Chrome tells us only about requests for playlists (the filter below),
// so this costs nothing on other pages. The latest few per tab are kept for the video button.
const STREAM_LIMIT = 12;

chrome.webRequest.onBeforeRequest.addListener((details) => {
  if (details.tabId < 0 || !/^https?:/i.test(details.url)) return;
  const key = `streams:${details.tabId}`;
  chrome.storage.session.get(key).then((stored) => {
    const list = (stored[key] || []).filter((entry) => entry.url !== details.url);
    list.unshift({ url: details.url, time: Date.now() });
    chrome.storage.session.set({ [key]: list.slice(0, STREAM_LIMIT) });
  });
}, { urls: ["*://*/*.m3u8*"] });

chrome.tabs.onRemoved.addListener((tabId) => chrome.storage.session.remove(`streams:${tabId}`));

// Video sites whose terms forbid downloading and that scramble their streams to stop it.
const NEVER = /(^|\.)(youtube\.com|youtu\.be|youtube-nocookie\.com|googlevideo\.com)$/i;

function attributes(line) {
  const result = {};
  const re = /([A-Z0-9-]+)=("[^"]*"|[^,]*)/g;
  let match;
  while ((match = re.exec(line.slice(line.indexOf(":") + 1)))) result[match[1]] = match[2].replace(/^"|"$/g, "");
  return result;
}

// Reads a playlist: the sizes of a master playlist, or the length and protection of a media playlist.
function parsePlaylist(text, base) {
  const lines = text.replace(/\r/g, "").split("\n").map((l) => l.trim());
  if (!lines[0] || !lines[0].startsWith("#EXTM3U")) return null;
  if (lines.some((l) => l.startsWith("#EXT-X-STREAM-INF"))) {
    const audio = {};
    for (const line of lines.filter((l) => l.startsWith("#EXT-X-MEDIA:"))) {
      const a = attributes(line);
      if (a.TYPE === "AUDIO" && a.URI && (!audio[a["GROUP-ID"]] || a.DEFAULT === "YES")) audio[a["GROUP-ID"]] = new URL(a.URI, base).href;
    }
    const variants = [];
    let pending = null;
    for (const line of lines) {
      if (line.startsWith("#EXT-X-STREAM-INF:")) pending = attributes(line);
      else if (pending && line && !line.startsWith("#")) {
        const size = (pending.RESOLUTION || "").split("x").map(Number);
        variants.push({
          url: new URL(line, base).href,
          bandwidth: Number(pending["AVERAGE-BANDWIDTH"] || pending.BANDWIDTH || 0),
          height: size.length === 2 && size[1] ? size[1] : 0,
          audioUrl: pending.AUDIO ? audio[pending.AUDIO] || "" : "",
          protected: /SAMPLE-AES|com\.apple\.streamingkeydelivery|widevine|playready/i.test(text),
        });
        pending = null;
      }
    }
    return { master: true, variants };
  }
  let duration = 0;
  for (const line of lines) if (line.startsWith("#EXTINF:")) duration += parseFloat(line.slice(8)) || 0;
  const keys = lines.filter((l) => l.startsWith("#EXT-X-KEY:")).map(attributes);
  const isProtected = keys.some((k) => k.METHOD && k.METHOD !== "NONE" && (k.METHOD !== "AES-128" || (k.KEYFORMAT && k.KEYFORMAT !== "identity")));
  return { master: false, duration, protected: isProtected };
}

async function fetchPlaylist(url) {
  const response = await fetch(url, { credentials: "include" });
  if (!response.ok) throw new Error(`HTTP ${response.status}`);
  return parsePlaylist(await response.text(), url);
}

// The sizes a streamed video can be downloaded at, biggest first, with a rough file size each.
async function streamOptions(tabId, pageStart, foundInPage) {
  const stored = (await chrome.storage.session.get(`streams:${tabId}`))[`streams:${tabId}`] || [];
  const candidates = [...new Set([
    ...(foundInPage || []),
    ...stored.filter((entry) => !pageStart || entry.time >= pageStart - 1000).map((entry) => entry.url),
  ])];
  let single = null;
  for (const url of candidates) {
    try {
      if (NEVER.test(new URL(url).hostname)) continue;
      const playlist = await fetchPlaylist(url);
      if (!playlist) continue;
      if (playlist.master && playlist.variants.length) {
        if (playlist.variants.some((v) => v.protected)) return { protected: true, options: [] };
        // The length comes from one size's playlist (they're all the same video).
        let duration = 0;
        try {
          const media = await fetchPlaylist(playlist.variants[0].url);
          if (media && media.protected) return { protected: true, options: [] };
          duration = (media && media.duration) || 0;
        } catch {}
        const seen = new Set();
        const options = playlist.variants
          .sort((a, b) => b.height - a.height || b.bandwidth - a.bandwidth)
          .filter((v) => {
            const label = v.height ? `${v.height}p` : `${Math.round(v.bandwidth / 1000)} kb/s`;
            if (seen.has(label)) return false;
            seen.add(label);
            v.label = label;
            return true;
          })
          .map((v) => ({ label: v.label, url: v.url, audioUrl: v.audioUrl, kind: "hls",
                         bytes: duration && v.bandwidth ? Math.round((v.bandwidth * duration) / 8) : 0 }));
        return { options };
      }
      if (!playlist.master && !single) {
        if (playlist.protected) return { protected: true, options: [] };
        single = { label: "Best available", url, audioUrl: "", kind: "hls", bytes: 0 };
      }
    } catch {}
  }
  return { options: single ? [single] : [] };
}

// From the video button (video.js) and the popup (popup.js).
chrome.runtime.onMessage.addListener((message, sender, reply) => {
  if (message && message.type === "video" && canHandOver(message.url)) {
    sendToToolbelt(message.url, {
      referrer: message.referrer, name: message.name, kind: message.kind === "hls" ? "hls" : "",
      audioUrl: canHandOver(message.audioUrl) ? message.audioUrl : "", quiet: message.quiet === true,
    }).then((ok) => reply({ ok }));
    return true;
  }
  if (message && message.type === "streams" && sender.tab) {
    streamOptions(sender.tab.id, message.pageStart, message.found).then(reply, () => reply({ options: [] }));
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
