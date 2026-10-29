/* Public installation link: set after TestFlight public testing opens. */
const IOS_TESTFLIGHT_URL = "";
const RELEASE_API = "https://api.github.com/repos/Drafffffff/iMic/releases/latest";
const RELEASE_FALLBACK = "https://github.com/Drafffffff/iMic/releases/latest";
const SHARE_URL = "https://drafffffff.github.io/iMic/?from=ios#download";

(() => {
  "use strict";
  const query = new URLSearchParams(location.search);
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const card = document.querySelector("#mac-download");
  const meta = document.querySelector("#release-meta");
  // Keep user-facing strings in the HTML, including dynamic templates.
  const initialMeta = meta.textContent;
  const versionTemplate = meta.dataset.template;
  const safeDownload = (value) => {
    try {
      const url = new URL(value);
      return url.protocol === "https:" && url.hostname === "github.com"
        && url.pathname.startsWith("/Drafffffff/iMic/releases/download/") ? url.href : null;
    } catch { return null; }
  };
  async function updateRelease() {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 4000);
    try {
      if (query.get("release-api") === "fail") throw new Error("Preview fallback");
      const response = await fetch(RELEASE_API, { signal: controller.signal, credentials: "omit" });
      if (!response.ok) throw new Error(`GitHub ${response.status}`);
      const release = await response.json();
      const assets = Array.isArray(release.assets) ? release.assets : [];
      const dmg = assets.find((asset) => /macOS-universal\.dmg$/.test(asset.name));
      const url = dmg && safeDownload(dmg.browser_download_url);
      if (!url || !Number.isFinite(dmg.size) || dmg.size <= 0 || typeof release.tag_name !== "string" || !release.tag_name.trim()) {
        throw new Error("Incomplete release");
      }
      document.querySelectorAll("[data-dmg-link]").forEach((link) => { link.href = url; });
      const version = release.tag_name.replace(/^v/, "");
      meta.textContent = versionTemplate.replace("{version}", version).replace("{size}", (dmg.size / 1e6).toFixed(1));
      document.querySelector("[data-hero-version]").textContent = version;
      const checksum = assets.find((asset) => asset.name === "SHA256SUMS.txt");
      document.querySelector("#checksum-link").href = (checksum && safeDownload(checksum.browser_download_url)) || RELEASE_FALLBACK;
    } catch {
      meta.textContent = initialMeta;
      document.querySelectorAll("[data-dmg-link]").forEach((link) => { link.href = RELEASE_FALLBACK; });
      document.querySelector("#checksum-link").href = RELEASE_FALLBACK;
    } finally {
      clearTimeout(timeout);
      document.documentElement.dataset.releaseReady = "true";
    }
  }
  void updateRelease();

  if (IOS_TESTFLIGHT_URL) {
    const link = document.querySelector("#testflight-link");
    link.href = IOS_TESTFLIGHT_URL;
    link.hidden = false;
    document.querySelector("#testflight-pending").hidden = true;
  }

  const mobile = /iPhone|iPod|Android/i.test(navigator.userAgent)
    || (navigator.platform === "MacIntel" && navigator.maxTouchPoints > 1);
  if (mobile) {
    document.querySelector("#mac-download-link").hidden = true;
    document.querySelector("#mobile-download-note").hidden = false;
    const button = document.querySelector("#share-link");
    const status = document.querySelector("#share-status");
    button.hidden = false;
    button.addEventListener("click", async () => {
      try {
        if (navigator.share) {
          await navigator.share({ title: button.dataset.shareTitle, url: SHARE_URL });
        } else {
          await navigator.clipboard.writeText(SHARE_URL);
          status.textContent = button.dataset.success;
        }
      } catch (error) {
        if (error.name === "AbortError") return; // Dismissing a share sheet is expected.
        // A share API can exist but be denied. Try clipboard before offering a manual link.
        try {
          await navigator.clipboard.writeText(SHARE_URL);
          status.textContent = button.dataset.success;
        } catch {
          status.textContent = button.dataset.failure;
          document.querySelector("#share-manual").hidden = false;
        }
      }
    });
  }

  function highlightDownload() {
    card.classList.remove("highlight");
    card.classList.add("highlight");
    setTimeout(() => card.classList.remove("highlight"), 1500);
  }
  if (query.get("from") === "ios" || location.hash === "#download") {
    document.querySelector("#origin-banner").hidden = false;
    // Wait for first layout, then honor the device's motion setting.
    requestAnimationFrame(() => {
      document.querySelector("#download").scrollIntoView({ behavior: reducedMotion.matches ? "instant" : "smooth" });
      // Highlight after smooth scrolling has brought the card into view.
      if (reducedMotion.matches) highlightDownload();
      else {
        const observer = new IntersectionObserver((entries) => {
          if (entries.some((entry) => entry.isIntersecting)) {
            highlightDownload(); observer.disconnect();
          }
        }, { threshold: 0.3 });
        observer.observe(card);
      }
    });
  }
  addEventListener("hashchange", () => {
    if (location.hash === "#download") highlightDownload();
  });

  const videos = [...document.querySelectorAll("video[data-src]")];
  const manuallyPaused = new WeakSet();
  const visible = new WeakSet();
  function load(video) {
    if (!video.getAttribute("src")) video.src = video.dataset.src;
  }
  function setButton(video) {
    const button = video.parentElement.querySelector(".video-toggle");
    button.textContent = video.paused ? button.dataset.playLabel : button.dataset.pauseLabel;
    button.setAttribute("aria-label", `${button.textContent}：${video.getAttribute("aria-label")}`);
  }
  function play(video) {
    load(video);
    video.play().catch(() => setButton(video));
  }
  videos.forEach((video) => {
    video.muted = true;
    const button = video.parentElement.querySelector(".video-toggle");
    button.addEventListener("click", () => {
      if (video.paused) { manuallyPaused.delete(video); play(video); }
      else { manuallyPaused.add(video); video.pause(); }
    });
    video.addEventListener("play", () => setButton(video));
    video.addEventListener("pause", () => setButton(video));
    video.addEventListener("error", () => { video.style.visibility = "hidden"; setButton(video); });
  });
  if ("IntersectionObserver" in window) {
    const observer = new IntersectionObserver((entries) => {
      entries.forEach(({ target: video, isIntersecting }) => {
        if (isIntersecting) visible.add(video); else visible.delete(video);
        if (isIntersecting && !reducedMotion.matches && !manuallyPaused.has(video) && !document.hidden) play(video);
        else video.pause();
      });
    }, { threshold: 0.2 });
    videos.forEach((video) => observer.observe(video));
  }
  reducedMotion.addEventListener("change", () => {
    videos.forEach((video) => {
      if (reducedMotion.matches) { video.pause(); video.removeAttribute("src"); video.load(); }
      else if (visible.has(video) && !manuallyPaused.has(video) && !document.hidden) play(video);
    });
  });
  document.addEventListener("visibilitychange", () => {
    videos.forEach((video) => {
      if (document.hidden) video.pause();
      else if (visible.has(video) && !reducedMotion.matches && !manuallyPaused.has(video)) play(video);
    });
  });
})();
