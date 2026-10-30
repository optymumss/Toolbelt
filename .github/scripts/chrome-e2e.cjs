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

    // Streamed videos (blob: addresses) don't get one.
    const streamed = await page.evaluate(async () => {
      const video = document.createElement("video");
      video.width = 400; video.height = 225;
      video.src = URL.createObjectURL(new Blob(["x"], { type: "video/mp4" }));
      document.body.appendChild(video);
      const before = document.querySelectorAll("button").length;
      video.dispatchEvent(new Event("play"));
      await new Promise((r) => setTimeout(r, 300));
      return document.querySelectorAll("button").length === before;
    });
    check(streamed, "streamed videos don't get a Download button");
  } catch (error) {
    check(false, "the Chrome test ran", String(error));
  } finally {
    await browser.close();
  }
  console.log(failed ? `${failed} Chrome check(s) failed` : "Chrome extension checks passed");
  process.exit(failed ? 1 : 0);
})();
