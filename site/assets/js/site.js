/* Public installation link: set after TestFlight public testing opens. */
const IOS_TESTFLIGHT_URL = "";
const RELEASE_API = "https://api.github.com/repos/Drafffffff/iMic/releases/latest";
const RELEASE_FALLBACK = "https://github.com/Drafffffff/iMic/releases/latest";
const SHARE_URL = document.querySelector("#share-manual").href;

(() => {
  "use strict";
  const query = new URLSearchParams(location.search);
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  // Static, complete HTML is also the no-JS / reduced-motion fallback.
  const demo = document.querySelector(".field-demo");
  if (demo && "IntersectionObserver" in window) {
    const fields = [...demo.querySelectorAll(".field-text")];
    const toggle = document.querySelector("[data-demo-toggle]");
    let timer, inView = false, paused = false, index = 0, count = 0, complete = false;
    function stop() {
      clearTimeout(timer);
      timer = null;
      demo.dataset.state = "paused";
    }
    function reset() {
      fields.forEach((field) => { field.textContent = ""; });
      index = 0; count = 0; complete = false;
      demo.dataset.phase = "typing";
    }
    function step() {
      timer = null;
      if (complete) reset();
      const field = fields[index];
      fields.forEach((item, i) => item.closest(".field-scene").classList.toggle("is-active", i === index));
      field.textContent = [...field.dataset.text].slice(0, ++count).join("");
      let wait = 65;
      if (count >= [...field.dataset.text].length) {
        count = 0;
        index++;
        wait = 450;
        if (index === fields.length) {
          complete = true;
          demo.dataset.phase = "complete";
          field.closest(".field-scene").classList.remove("is-active");
          wait = 2600;
        }
      }
      timer = setTimeout(step, wait);
    }
    function sync() {
      stop();
      toggle.hidden = reducedMotion.matches;
      if (reducedMotion.matches) {
        fields.forEach((field) => {
          field.textContent = field.dataset.text;
          field.closest(".field-scene").classList.remove("is-active");
        });
        complete = true;
        demo.dataset.phase = "complete";
        demo.dataset.state = "static";
      } else if (inView && !document.hidden && !paused) {
        demo.dataset.state = "running";
        timer = setTimeout(step, 65);
      }
    }
    // Pause the clock entirely outside the viewport or in a background tab.
    new IntersectionObserver(([entry]) => {
      inView = entry.isIntersecting;
      sync();
    }).observe(demo);
    toggle.addEventListener("click", () => {
      paused = !paused;
      toggle.setAttribute("aria-pressed", String(paused));
      toggle.textContent = paused ? toggle.dataset.playLabel : toggle.dataset.pauseLabel;
      sync();
    });
    reducedMotion.addEventListener("change", sync);
    document.addEventListener("visibilitychange", sync);
    if (!reducedMotion.matches) reset();
    sync();
  }
  // Storage-free suggestion: dismiss for this page only, with no automatic redirect.
  const languageBanner = document.querySelector("#language-banner");
  if (languageBanner && !(navigator.language || "en").toLowerCase().startsWith("zh")) {
    languageBanner.hidden = false;
    languageBanner.querySelector("button").addEventListener("click", () => { languageBanner.hidden = true; });
  }
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
      const target = mobile && document.documentElement.lang === "en" ? card : document.querySelector("#download");
      target.scrollIntoView({ behavior: reducedMotion.matches ? "instant" : "smooth" });
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
  const compactVideo = matchMedia("(max-width: 759px)");
  const sourceFor = (video) => compactVideo.matches && video.dataset.mobileSrc ? video.dataset.mobileSrc : video.dataset.src;
  function load(video) {
    const source = sourceFor(video);
    if (video.getAttribute("src") !== source) video.src = source;
  }
  function updateResponsivePosters() {
    videos.filter((video) => video.dataset.mobilePoster).forEach((video) => {
      video.dataset.desktopPoster ||= video.getAttribute("poster");
      video.poster = compactVideo.matches ? video.dataset.mobilePoster : video.dataset.desktopPoster;
      if (video.getAttribute("src") && video.getAttribute("src") !== sourceFor(video)) {
        video.pause(); video.removeAttribute("src"); video.load();
        if (!reducedMotion.matches && visible.has(video) && !manuallyPaused.has(video) && !document.hidden) play(video);
      }
    });
  }
  updateResponsivePosters();
  compactVideo.addEventListener("change", updateResponsivePosters);
  function setButton(video) {
    const button = video.parentElement.querySelector(".video-toggle");
    button.textContent = video.paused ? button.dataset.playLabel : button.dataset.pauseLabel;
    button.setAttribute("aria-label", `${button.textContent}：${video.getAttribute("aria-label")}`);
  }
  function play(video) {
    load(video);
    video.play().catch(() => setButton(video));
  }
  document.querySelectorAll(".sound-toggle").forEach((button) => {
    const video = button.parentElement.querySelector("video");
    button.addEventListener("click", () => {
      const on = video.muted;
      video.muted = !on;
      button.setAttribute("aria-pressed", String(on));
      button.textContent = on ? button.dataset.onLabel : button.dataset.offLabel;
      if (on) { manuallyPaused.delete(video); video.currentTime = 0; play(video); }
    });
  });
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

/* HTML-in-Canvas CRT headline. Only runs where the browser can draw DOM into a canvas
   (Chrome origin trial or chrome://flags/#canvas-draw-element); everywhere else the
   CSS glow is the whole effect. The <h1> stays a real, selectable, accessible element. */
(() => {
  "use strict";
  const title = document.querySelector("#hero-title");
  const ctx2d = window.CanvasRenderingContext2D && CanvasRenderingContext2D.prototype;
  if (!title || !ctx2d || !("drawElementImage" in ctx2d)) return;
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const canvas = document.createElement("canvas");
  canvas.className = "crt-title";
  if ("content" in HTMLCanvasElement.prototype) canvas.setAttribute("content", "drawable");
  else canvas.setAttribute("layoutsubtree", "");
  title.before(canvas);
  canvas.append(title);
  const ctx = canvas.getContext("2d");
  const glow = document.createElement("canvas");
  const glowCtx = glow.getContext("2d");
  const pad = parseFloat(getComputedStyle(canvas).getPropertyValue("--crt-pad")) || 24;
  let dpr = 1, width = 0, height = 0, visible = true, frame = 0, band = 0;

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    width = canvas.clientWidth;
    height = title.offsetHeight + pad * 2;
    canvas.style.height = height + "px";
    canvas.width = glow.width = Math.round(width * dpr);
    canvas.height = glow.height = Math.round(height * dpr);
    paint();
  }

  function drawTitle(target) {
    const result = target.drawElementImage(title, pad, pad);
    // Before Chrome 155 the call returned a DOMMatrix that had to be applied by hand.
    if (result && typeof result.toString === "function") title.style.transform = result.toString();
  }

  function paint() {
    if (!width) return;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, canvas.width, canvas.height);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    drawTitle(ctx);
    // Bloom: blur a copy of the drawn text and add it back as light.
    glowCtx.setTransform(1, 0, 0, 1, 0, 0);
    glowCtx.clearRect(0, 0, glow.width, glow.height);
    glowCtx.drawImage(canvas, 0, 0);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    ctx.filter = `blur(${10 * dpr}px)`;
    ctx.globalAlpha = 0.5;
    ctx.drawImage(glow, 0, 0);
    ctx.filter = `blur(${28 * dpr}px)`;
    ctx.globalAlpha = 0.35;
    ctx.drawImage(glow, 0, 0);
    ctx.restore();
    // Scanlines and a rolling bright band, applied only where text was drawn.
    ctx.save();
    ctx.globalCompositeOperation = "source-atop";
    ctx.fillStyle = "rgba(0, 0, 0, 0.34)";
    const step = Math.max(2, Math.round(3 * dpr));
    for (let y = 0; y < canvas.height; y += step) ctx.fillRect(0, y, canvas.width, Math.max(1, Math.round(dpr)));
    if (!reducedMotion.matches) {
      const y = (band % 1) * (canvas.height + 120 * dpr) - 60 * dpr;
      const gradient = ctx.createLinearGradient(0, y - 40 * dpr, 0, y + 40 * dpr);
      gradient.addColorStop(0, "rgba(255, 120, 60, 0)");
      gradient.addColorStop(0.5, "rgba(255, 150, 90, 0.28)");
      gradient.addColorStop(1, "rgba(255, 120, 60, 0)");
      ctx.fillStyle = gradient;
      ctx.fillRect(0, y - 40 * dpr, canvas.width, 80 * dpr);
    }
    ctx.restore();
  }

  function tick(time) {
    frame = 0;
    if (!visible || document.hidden || reducedMotion.matches) return;
    band = time / 5200;
    if (canvas.requestPaint) canvas.requestPaint(); else paint();
    frame = requestAnimationFrame(tick);
  }
  function start() { if (!frame && !reducedMotion.matches) frame = requestAnimationFrame(tick); }

  canvas.addEventListener("paint", paint);
  new ResizeObserver(resize).observe(canvas);
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; if (visible) start(); }).observe(canvas);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) start(); });
  reducedMotion.addEventListener("change", () => { paint(); start(); });
  document.documentElement.dataset.crt = "canvas";
  resize();
  start();
})();
