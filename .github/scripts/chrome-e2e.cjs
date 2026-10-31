// Drives Chrome for Testing with the Toolbelt extension loaded; see chrome.sh.
const fs = require("fs");
const path = require("path");
const puppeteer = require("puppeteer");

const [extensionDir, extensionId, downloads, site, profile] = process.argv.slice(2);
let failed = 0;
const check = (ok, name, detail = "") => {
  console.log(`${ok ? "✓" : "✗"} ${name}${!ok && detail ? ` — ${detail}` : ""}`);
  if (!ok) failed += 1;
};
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
async function waitForFile(name, seconds) {
  for (let i = 0; i < seconds * 4; i += 1) {
    const file = path.join(downloads, name);
    if (fs.existsSync(file) && fs.statSync(file).size > 0) return fs.statSync(file).size;
    await sleep(250);
  }
  return 0;
}

(async () => {
  const browser = await puppeteer.launch({
    headless: false,
    userDataDir: profile,
    args: [`--disable-extensions-except=${extensionDir}`, `--load-extension=${extensionDir}`, "--no-first-run"],
    env: process.env,
  });
  try {
    const worker = await browser.waitForTarget(
      (t) => t.type() === "service_worker" && t.url().startsWith(`chrome-extension://${extensionId}/`), { timeout: 20000 });
    check(!!worker, "Chrome loads the Toolbelt extension with the expected ID");

    // The toolbar popup asks Toolbelt whether it's there.
    const popup = await browser.newPage();
    await popup.goto(`chrome-extension://${extensionId}/popup.html`);
    await popup.waitForFunction(() => !document.getElementById("status").textContent.includes("Checking"), { timeout: 15000 });
    const status = await popup.$eval("#status", (el) => el.textContent);
    check(status.includes("Connected"), "the toolbar popup says it's connected to Toolbelt", status);
    await popup.close();

    // A download started in Chrome goes to Toolbelt instead.
    const page = await browser.newPage();
    await page.goto(site);
    await page.click("#link");
    const report = await waitForFile("report.zip", 30);
    check(report === 1500000, "a download started in Chrome is handed to Toolbelt and finishes", `size ${report}`);

    // The Download button on a video.
    await page.evaluate(() => document.getElementById("video").dispatchEvent(new Event("play")));
    await page.hover("#video");
    await sleep(500);
    const clicked = await page.evaluate(() => {
      const button = [...document.querySelectorAll("button")].find((b) => b.title === "Download this video with Toolbelt");
      if (!button) return false;
      button.click();
      return true;
    });
    check(clicked, "videos get a Download button");
    const clip = await waitForFile("clip.mp4", 30);
    check(clip === 900000, "clicking it downloads the video with Toolbelt", `size ${clip}`);

    // Several files of different sizes: a menu of sizes, and the one picked is downloaded.
    const openMenu = async (target, id) => {
      await target.evaluate((videoId) => document.getElementById(videoId).dispatchEvent(new Event("play")), id);
      await target.hover(`#${id}`);
      await sleep(400);
      return target.evaluate((videoId) => {
        const box = document.getElementById(videoId).getBoundingClientRect();
        const buttons = [...document.querySelectorAll("button")].filter((b) => b.title === "Download this video with Toolbelt");
        const button = buttons.find((b) => Math.abs(parseFloat(b.style.top) - (window.scrollY + box.top + 10)) < 2) || buttons.pop();
        if (!button) return false;
        button.click();
        return true;
      }, id);
    };
    const menuItems = (target) => target.evaluate(() => [...document.querySelectorAll("[data-toolbelt-menu]")]
      .filter((m) => m.style.display === "block")
      .flatMap((m) => [...m.querySelectorAll("[data-quality]")].map((b) => ({ label: b.dataset.quality, text: b.textContent }))));
    const waitForMenu = async (target) => {
      for (let i = 0; i < 60; i += 1) {
        const items = await menuItems(target);
        if (items.length) return items;
        await sleep(250);
      }
      return [];
    };
    const pick = (target, label) => target.evaluate((wanted) => {
      const item = [...document.querySelectorAll("[data-quality]")].find((b) => b.dataset.quality === wanted && b.offsetParent);
      if (item) item.click();
      return !!item;
    }, label);

    check(await openMenu(page, "multi"), "a video with several files gets a Download button");
    const fileSizes = await waitForMenu(page);
    check(JSON.stringify(fileSizes.map((i) => i.label)) === JSON.stringify(["720p", "360p"]),
      "it lists each size, biggest first", JSON.stringify(fileSizes));
    check(await pick(page, "360p"), "a size can be picked");
    const small = await waitForFile("Toolbelt test page (360p).mp4", 30);
    check(small === 300000, "picking 360p downloads the 360p file", `size ${small}`);

    // A streamed video with no playlist on the page: the button says so instead of failing silently.
    const noStream = await page.evaluate(async () => {
      const video = document.createElement("video");
      video.id = "blob"; video.width = 400; video.height = 225;
      video.src = URL.createObjectURL(new Blob(["x"], { type: "video/mp4" }));
      document.body.appendChild(video);
      return true;
    });
    check(noStream && await openMenu(page, "blob"), "streamed videos get a Download button too");
    await sleep(1500);
    const said = await page.evaluate(() => [...document.querySelectorAll("button")].map((b) => b.textContent).join(" | "));
    check(said.includes("No downloadable stream found"), "and say so when there's nothing to download", said);

    // A streamed video (HLS), like on most video sites: the sizes come from its playlist.
    const stream = await browser.newPage();
    await stream.goto(`${site}stream.html`);
    await stream.waitForFunction(() => document.body.dataset.loaded === "yes", { timeout: 15000 });
    await sleep(500);
    check(await openMenu(stream, "stream"), "a streamed video gets a Download button");
    const sizes = await waitForMenu(stream);
    check(JSON.stringify(sizes.map((i) => i.label)) === JSON.stringify(["1080p", "720p", "360p"]),
      "it offers every resolution the site streams, biggest first", JSON.stringify(sizes));
    check(sizes.length === 3 && sizes.every((i) => /about \d/.test(i.text)), "each with roughly how big the file will be", JSON.stringify(sizes));
    check(await pick(stream, "720p"), "a resolution can be picked");
    await sleep(800);
    const confirmed = await stream.evaluate(() => [...document.querySelectorAll("button")].map((b) => b.textContent).join(" | "));
    check(confirmed.includes("Downloading in Toolbelt"), "the button confirms Toolbelt has it", confirmed);
    check((await menuItems(stream)).length === 0, "the menu of sizes closes once one is picked");
    const started = Date.now();
    const video720 = await waitForFile("Toolbelt stream test (720p).mp4", 90);
    check(video720 > 20000, "Toolbelt downloads the 720p stream and joins it into one file", `size ${video720}, ${Date.now() - started} ms`);
    if (video720) {
      const head = fs.readFileSync(path.join(downloads, "Toolbelt stream test (720p).mp4")).subarray(4, 8).toString("latin1");
      check(head === "ftyp", "the file is an MP4", head);
    }
    const leftover = fs.readdirSync(downloads).filter((name) => name.includes("1080p") || name.includes("Toolbelt stream test (360p)"));
    check(leftover.length === 0, "only the picked resolution is downloaded", leftover.join(", "));

    // Copy-protected streams are refused.
    const locked = await browser.newPage();
    await locked.goto(`${site}protected.html`);
    await locked.waitForFunction(() => document.body.dataset.loaded === "yes", { timeout: 15000 });
    await sleep(500);
    await openMenu(locked, "stream");
    await sleep(2000);
    const lockedText = await locked.evaluate(() => [...document.querySelectorAll("button")].map((b) => b.textContent).join(" | "));
    check(lockedText.includes("Copy-protected") && (await menuItems(locked)).length === 0,
      "copy-protected (DRM) streams offer no download", lockedText);
  } catch (error) {
    check(false, "the Chrome test ran", String(error));
  } finally {
    await browser.close();
  }
  console.log(failed ? `${failed} Chrome check(s) failed` : "Chrome extension checks passed");
  process.exit(failed ? 1 : 0);
})();
