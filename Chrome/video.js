// Adds a small "Download" button over videos that can be downloaded: videos played straight from
// a file on the web. It never appears on streamed videos (blob: addresses, used by YouTube,
// Netflix and similar), on copy-protected (DRM) videos, or when the page asks browsers not to
// offer downloading (controlsList="nodownload").
// It does no work until a video plays or the pointer is over one, so it costs nothing on other pages.

(() => {
  const seen = new WeakSet();

  function downloadableSource(video) {
    const src = video.currentSrc || video.src || "";
    if (!/^https?:/i.test(src)) return null;
    if (video.mediaKeys) return null;
    const list = (video.getAttribute("controlslist") || "").toLowerCase();
    if (list.includes("nodownload")) return null;
    return src;
  }

  function nameFor(video, src) {
    try {
      const last = decodeURIComponent(new URL(src).pathname.split("/").pop() || "");
      if (/\.[a-z0-9]{2,4}$/i.test(last)) return last;
    } catch {}
    const title = (document.title || "video").replace(/[\/:]/g, "-").trim().slice(0, 80);
    return `${title}.mp4`;
  }

  function attach(video) {
    if (seen.has(video) || !downloadableSource(video)) return;
    seen.add(video);
    const button = document.createElement("button");
    button.textContent = "⬇ Download";
    button.title = "Download this video with Toolbelt";
    Object.assign(button.style, {
      position: "absolute", zIndex: 2147483647, display: "none", padding: "5px 10px",
      font: "600 12px -apple-system, BlinkMacSystemFont, sans-serif", color: "#fff",
      background: "rgba(20, 20, 20, 0.78)", border: "1px solid rgba(255, 255, 255, 0.35)",
      borderRadius: "7px", cursor: "pointer", backdropFilter: "blur(6px)",
    });
    let hideTimer = 0;
    const show = () => {
      if (!downloadableSource(video)) return;
      clearTimeout(hideTimer);
      const box = video.getBoundingClientRect();
      if (box.width < 160 || box.height < 90) return;
      button.style.left = `${window.scrollX + box.right - 118}px`;
      button.style.top = `${window.scrollY + box.top + 10}px`;
      button.style.display = "block";
    };
    const hide = () => {
      clearTimeout(hideTimer);
      hideTimer = setTimeout(() => (button.style.display = "none"), 1500);
    };
    button.addEventListener("mouseenter", () => clearTimeout(hideTimer));
    button.addEventListener("mouseleave", hide);
    button.addEventListener("click", (event) => {
      event.preventDefault();
      event.stopPropagation();
      const src = downloadableSource(video);
      if (!src) return;
      button.textContent = "Sending…";
      chrome.runtime.sendMessage({ type: "video", url: src, referrer: location.href, name: nameFor(video, src) }, (reply) => {
        button.textContent = reply && reply.ok ? "✓ In Toolbelt" : "Toolbelt isn't set up";
        setTimeout(() => (button.textContent = "⬇ Download"), 2500);
      });
    });
    document.body.appendChild(button);
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
