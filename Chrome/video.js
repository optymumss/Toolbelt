// Adds a "Download" button over videos, with a choice of sizes when the site offers several:
// - videos played straight from a file (one size, or several <source> files of different sizes);
// - streamed videos (most video sites: the page fetches a playlist listing the video at several
//   sizes). The sizes are read from that playlist when you click the button.
// It never appears on copy-protected (DRM) videos, on YouTube (its terms forbid downloading), or when
// the page asks browsers not to offer downloading (controlsList="nodownload").
// It does no work until a video plays or the pointer is over one, so it costs nothing on other pages.

// "Download All Links with Toolbelt": the page's links, pictures, videos and sounds (only those in the
// selected text when some is selected). Answers the extension's background script; only the top frame does.
if (window === window.top) {
  chrome.runtime.onMessage.addListener((message, sender, reply) => {
    if (!message || message.type !== "collect-links") return false;
    const selection = window.getSelection();
    const inSelection = !!selection && !selection.isCollapsed && selection.rangeCount > 0;
    const within = (el) => {
      if (!inSelection) return true;
      for (let i = 0; i < selection.rangeCount; i += 1) if (selection.getRangeAt(i).intersectsNode(el)) return true;
      return false;
    };
    const links = [];
    const add = (url, text, media) => {
      if (!/^(https?|ftp):/i.test(url || "")) return;
      const link = { url, text: (text || "").replace(/\s+/g, " ").trim().slice(0, 200) };
      if (media) link.media = media;
      links.push(link);
    };
    document.querySelectorAll("a[href], area[href]").forEach((a) => {
      if (within(a)) add(a.href, a.innerText || a.title || a.getAttribute("aria-label"));
    });
    document.querySelectorAll("img").forEach((img) => {
      if (within(img)) add(img.currentSrc || img.src, img.alt || img.title, "picture");
    });
    document.querySelectorAll("video, audio").forEach((media) => {
      if (!within(media)) return;
      const kind = media.tagName === "AUDIO" ? "sound" : "video";
      add(media.currentSrc || media.src, media.title, kind);
      media.querySelectorAll("source").forEach((source) => add(source.src, source.getAttribute("label") || "", kind));
    });
    reply({ url: location.href, title: document.title, selection: inSelection, links: links.slice(0, 5000) });
    return false;
  });
}

(() => {
  const NEVER = /(^|\.)(youtube\.com|youtu\.be|youtube-nocookie\.com)$/i;
  if (NEVER.test(location.hostname)) return;
  const seen = new WeakSet();

  function allowed(video) {
    if (video.mediaKeys) return false;
    const list = (video.getAttribute("controlslist") || "").toLowerCase();
    return !list.includes("nodownload");
  }

  // A video played straight from a file on the web.
  function downloadableSource(video) {
    const src = video.currentSrc || video.src || "";
    if (!/^https?:/i.test(src) || !allowed(video)) return null;
    return src;
  }

  // A streamed video: the page feeds it pieces, so its address is a blob: one.
  function isStreamed(video) {
    const src = video.currentSrc || video.src || "";
    return /^blob:/i.test(src) && allowed(video);
  }

  function title() {
    return (document.title || "video").replace(/[\/:\\]/g, "-").replace(/\s+/g, " ").trim().slice(0, 80) || "video";
  }

  function nameFor(src, label) {
    try {
      const last = decodeURIComponent(new URL(src).pathname.split("/").pop() || "");
      if (!label && /\.[a-z0-9]{2,4}$/i.test(last)) return last;
    } catch {}
    return label ? `${title()} (${label}).mp4` : `${title()}.mp4`;
  }

  // "720p" from a <source>'s label, size or address, if it has one.
  function sourceLabel(source) {
    for (const name of ["label", "res", "size", "data-res", "data-quality", "data-label", "title"]) {
      const value = (source.getAttribute(name) || "").trim();
      if (value) return /^\d{3,4}$/.test(value) ? `${value}p` : value.slice(0, 20);
    }
    const match = (source.src || "").match(/(?:^|[^\d])(2160|1440|1080|720|540|480|360|240|144)p?(?:[^\d]|$)/);
    return match ? `${match[1]}p` : "";
  }

  // Several files of different sizes, from the video's <source> elements.
  function fileOptions(video) {
    const options = [];
    const urls = new Set();
    for (const source of video.querySelectorAll("source")) {
      const src = source.src;
      if (!/^https?:/i.test(src) || urls.has(src)) continue;
      urls.add(src);
      options.push({ label: sourceLabel(source) || `Size ${options.length + 1}`, url: src, kind: "", bytes: 0 });
    }
    const height = (label) => parseInt(label, 10) || 0;
    return options.length > 1 ? options.sort((a, b) => height(b.label) - height(a.label)) : [];
  }

  // Playlists this page fetched, as the browser recorded them (the background page also watches for them).
  function playlistsInPage() {
    try {
      return performance.getEntriesByType("resource").map((entry) => entry.name)
        .filter((name) => /^https?:.*\.m3u8(\?|#|$)/i.test(name)).reverse().slice(0, 12);
    } catch {
      return [];
    }
  }

  function size(bytes) {
    if (!bytes) return "";
    if (bytes >= 1e9) return `about ${(bytes / 1e9).toFixed(1)} GB`;
    if (bytes >= 1e6) return `about ${Math.max(1, Math.round(bytes / 1e6))} MB`;
    return `about ${Math.max(1, Math.round(bytes / 1e3))} KB`;
  }

  const style = (element, values) => Object.assign(element.style, values);
  const FONT = "600 12px -apple-system, BlinkMacSystemFont, sans-serif";

  function attach(video) {
    if (seen.has(video) || (!downloadableSource(video) && !isStreamed(video))) return;
    seen.add(video);
    const button = document.createElement("button");
    button.textContent = "⬇ Download";
    button.title = "Download this video with Toolbelt";
    style(button, {
      position: "absolute", zIndex: 2147483647, display: "none", padding: "5px 10px", font: FONT, color: "#fff",
      background: "rgba(20, 20, 20, 0.78)", border: "1px solid rgba(255, 255, 255, 0.35)",
      borderRadius: "7px", cursor: "pointer", backdropFilter: "blur(6px)",
    });
    const menu = document.createElement("div");
    menu.setAttribute("data-toolbelt-menu", "");
    style(menu, {
      position: "absolute", zIndex: 2147483647, display: "none", minWidth: "170px", padding: "4px",
      font: FONT, color: "#fff", background: "rgba(24, 24, 24, 0.94)", border: "1px solid rgba(255, 255, 255, 0.25)",
      borderRadius: "9px", boxShadow: "0 6px 24px rgba(0, 0, 0, 0.35)", backdropFilter: "blur(8px)",
    });

    let hideTimer = 0;
    const usable = () => downloadableSource(video) || isStreamed(video);
    const place = () => {
      const box = video.getBoundingClientRect();
      button.style.left = `${window.scrollX + box.right - 118}px`;
      button.style.top = `${window.scrollY + box.top + 10}px`;
      menu.style.left = `${window.scrollX + Math.max(box.left + 4, box.right - 186)}px`;
      menu.style.top = `${window.scrollY + box.top + 40}px`;
    };
    const show = () => {
      if (!usable()) return;
      clearTimeout(hideTimer);
      const box = video.getBoundingClientRect();
      if (box.width < 160 || box.height < 90) return;
      place();
      button.style.display = "block";
    };
    const hide = () => {
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => {
        button.style.display = "none";
        menu.style.display = "none";
      }, 1500);
    };
    const reset = (text, after = 2500) => {
      button.textContent = text;
      setTimeout(() => (button.textContent = "⬇ Download"), after);
    };

    // Hands one choice to Toolbelt, which downloads it quietly (progress shows by its menu bar icon).
    const download = (option) => {
      menu.style.display = "none";
      button.textContent = "Sending…";
      chrome.runtime.sendMessage({
        type: "video", url: option.url, kind: option.kind, audioUrl: option.audioUrl || "", quiet: true,
        referrer: location.href, name: nameFor(option.url, option.label),
      }, (reply) => reset(reply && reply.ok ? "✓ Downloading in Toolbelt" : "Toolbelt isn't set up", 3000));
    };

    const showMenu = (options, note) => {
      menu.textContent = "";
      const heading = document.createElement("div");
      heading.textContent = note || "Download at…";
      style(heading, { padding: "5px 8px 4px", opacity: "0.65", fontWeight: "500" });
      menu.appendChild(heading);
      for (const option of options) {
        const item = document.createElement("button");
        item.setAttribute("data-quality", option.label);
        style(item, {
          display: "flex", justifyContent: "space-between", gap: "14px", width: "100%", padding: "6px 8px",
          font: FONT, color: "#fff", background: "transparent", border: "0", borderRadius: "6px",
          cursor: "pointer", textAlign: "left",
        });
        const label = document.createElement("span");
        label.textContent = option.label;
        const detail = document.createElement("span");
        detail.textContent = size(option.bytes);
        style(detail, { opacity: "0.6", fontWeight: "500" });
        item.append(label, detail);
        item.addEventListener("mouseenter", () => (item.style.background = "rgba(255, 255, 255, 0.14)"));
        item.addEventListener("mouseleave", () => (item.style.background = "transparent"));
        item.addEventListener("click", (event) => {
          event.preventDefault();
          event.stopPropagation();
          download(option);
        });
        menu.appendChild(item);
      }
      place();
      menu.style.display = "block";
    };

    button.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    button.addEventListener("mouseleave", hide);
    menu.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    menu.addEventListener("mouseleave", hide);
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      if (menu.style.display === "block") {
        menu.style.display = "none";
        return;
      }
      const src = downloadableSource(video);
      if (src) {
        const options = fileOptions(video);
        if (options.length > 1) showMenu(options);
        else download({ url: src, label: "", kind: "" });
        return;
      }
      if (!isStreamed(video)) return;
      button.textContent = "Finding sizes…";
      chrome.runtime.sendMessage({ type: "streams", pageStart: Math.round(performance.timeOrigin), found: playlistsInPage() }, (reply) => {
        button.textContent = "⬇ Download";
        const options = (reply && reply.options) || [];
        if (reply && reply.protected) reset("Copy-protected: can't download", 3500);
        else if (!options.length) reset("No downloadable stream found", 3500);
        else showMenu(options);
      });
    });
    document.body.append(button, menu);
    // Players often cover the video with their own controls, so watch the player as a whole.
    const area = video.parentElement || video;
    area.addEventListener("mouseenter", show, { passive: true });
    area.addEventListener("mouseleave", hide, { passive: true });
    show();
    hide();
  }

  document.addEventListener("play", (event) => {
    if (event.target instanceof HTMLVideoElement) attach(event.target);
  }, { capture: true, passive: true });
  document.addEventListener("mouseover", (event) => {
    if (event.target instanceof HTMLVideoElement) attach(event.target);
  }, { capture: true, passive: true });
  for (const video of document.querySelectorAll("video")) {
    if (video.controls || !video.paused) attach(video);
  }
})();
