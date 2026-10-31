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
          // The command "lands" in the terminal: a short glitch on that window.
          document.dispatchEvent(new CustomEvent("imic:glitch", { detail: { target: field.closest(".field-window"), level: "small" } }));
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
    // The whole video is the control; the label stays for keyboard and screen readers.
    button.textContent = video.paused ? button.dataset.playLabel : button.dataset.pauseLabel;
    button.dataset.state = video.paused ? "paused" : "playing";
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
      button.setAttribute("aria-label", on ? button.dataset.onLabel : button.dataset.offLabel);
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
   CSS glow is the whole effect. The real <h1> stays on top as a normal element with
   transparent text, so selection, cursor and double-click are native in every browser;
   the canvas underneath only paints a hidden copy with glow and scanlines. */
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
  canvas.setAttribute("aria-hidden", "true");
  const copy = title.cloneNode(true);
  copy.removeAttribute("id");
  copy.className = "crt-copy";
  canvas.append(copy);
  title.before(canvas);
  title.classList.add("crt-lit");
  const ctx = canvas.getContext("2d");
  const glow = document.createElement("canvas");
  const glowCtx = glow.getContext("2d");
  const pad = parseFloat(getComputedStyle(canvas).getPropertyValue("--crt-pad")) || 24;
  let dpr = 1, width = 0, height = 0, visible = true, frame = 0, band = 0, glitchUntil = 0;
  const buffer = document.createElement("canvas");
  const bufferCtx = buffer.getContext("2d");

  function resize() {
    dpr = Math.min(window.devicePixelRatio || 1, 2);
    width = title.offsetWidth + pad * 2;
    height = title.offsetHeight + pad * 2;
    Object.assign(canvas.style, { left: title.offsetLeft - pad + "px", top: title.offsetTop - pad + "px", width: width + "px", height: height + "px" });
    copy.style.width = title.offsetWidth + "px";
    canvas.width = glow.width = buffer.width = Math.round(width * dpr);
    canvas.height = glow.height = buffer.height = Math.round(height * dpr);
    paint();
  }

  function drawTitle(target) {
    // The copy is never hit-tested (the canvas ignores pointer events), so the DOMMatrix
    // returned before Chrome 155 can be ignored.
    target.drawElementImage(copy, pad, pad);
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
    if (performance.now() < glitchUntil) tear();
  }

  // Glitch: cut the lit headline into bands, shove them sideways and split the colour
  // channels into saturated cyan and magenta ghosts.
  function tint(color) {
    bufferCtx.setTransform(1, 0, 0, 1, 0, 0);
    bufferCtx.clearRect(0, 0, buffer.width, buffer.height);
    bufferCtx.globalCompositeOperation = "source-over";
    bufferCtx.drawImage(glow, 0, 0);
    bufferCtx.globalCompositeOperation = "source-in";
    bufferCtx.fillStyle = color;
    bufferCtx.fillRect(0, 0, buffer.width, buffer.height);
    return buffer;
  }
  function tear() {
    const w = canvas.width, h = canvas.height, shift = 18 * dpr;
    glowCtx.setTransform(1, 0, 0, 1, 0, 0);
    glowCtx.clearRect(0, 0, w, h);
    glowCtx.drawImage(canvas, 0, 0);
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, w, h);
    ctx.save();
    ctx.globalCompositeOperation = "lighter";
    ctx.drawImage(tint("rgba(0, 240, 255, 0.9)"), -shift * (0.3 + Math.random()), 0);
    ctx.drawImage(tint("rgba(255, 43, 214, 0.9)"), shift * (0.3 + Math.random()), 0);
    ctx.restore();
    let y = 0;
    while (y < h) {
      const band = Math.max(4 * dpr, Math.random() * h * 0.28);
      const dx = Math.random() < 0.55 ? (Math.random() - 0.5) * shift * 4 : 0;
      ctx.drawImage(glow, 0, y, w, band, dx, y, w, band);
      y += band;
    }
  }
  document.addEventListener("imic:glitch-title", (event) => {
    if (reducedMotion.matches) return;
    glitchUntil = performance.now() + (event.detail?.duration || 320);
    const loop = () => { if (canvas.requestPaint) canvas.requestPaint(); else paint(); if (performance.now() < glitchUntil + 60) setTimeout(loop, 55); };
    loop();
  });

  function tick(time) {
    frame = 0;
    if (!visible || document.hidden || reducedMotion.matches) return;
    band = time / 5200;
    if (canvas.requestPaint) canvas.requestPaint(); else paint();
    frame = requestAnimationFrame(tick);
  }
  function start() { if (!frame && !reducedMotion.matches) frame = requestAnimationFrame(tick); }

  canvas.addEventListener("paint", paint);
  new ResizeObserver(resize).observe(title);
  new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; if (visible) start(); }).observe(canvas);
  document.addEventListener("visibilitychange", () => { if (!document.hidden) start(); });
  reducedMotion.addEventListener("change", () => { paint(); start(); });
  document.documentElement.dataset.crt = "canvas";
  resize();
  start();
})();


/* Glitch: rare, short and loud. One scheduler, one glitch at a time, nothing at all for
   reduced motion. Colour changes stay under three per second (WCAG 2.3.1). */
(() => {
  "use strict";
  const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)");
  const STEP = 55;                       // ms per glitch frame
  let busy = false, signalDone = false, interacting = false;
  const allowed = () => !reducedMotion.matches && !document.hidden && !busy;
  const random = (min, max) => min + Math.random() * (max - min);

  // CSS path: two coloured clones of the element tear across it, then everything snaps back.
  function glitch(element, level = "small") {
    if (!element || !allowed() || interacting) return false;
    if (element.closest(".crt-title") || (element.id === "hero-title" && document.documentElement.dataset.crt === "canvas")) {
      busy = true;
      const duration = level === "large" ? 420 : 320;
      document.dispatchEvent(new CustomEvent("imic:glitch-title", { detail: { duration } }));
      setTimeout(() => { busy = false; }, duration + 80);
      return true;
    }
    busy = true;
    const duration = level === "small" ? random(120, 200) : random(250, 400);
    const strength = level === "small" ? 6 : 16;
    const host = element.offsetParent || document.body;
    const layer = document.createElement("div");
    layer.className = "glitch-layer";
    layer.setAttribute("aria-hidden", "true");
    Object.assign(layer.style, { left: element.offsetLeft + "px", top: element.offsetTop + "px", width: element.offsetWidth + "px", height: element.offsetHeight + "px" });
    const ghosts = ["cyan", "magenta"].map((tone) => {
      const ghost = element.cloneNode(true);
      ghost.removeAttribute("id");
      ghost.querySelectorAll("[id]").forEach((node) => node.removeAttribute("id"));
      ghost.classList.add("glitch-ghost", "glitch-" + tone);
      layer.append(ghost);
      return ghost;
    });
    if (getComputedStyle(host).position === "static") host.style.position = "relative";
    host.append(layer);
    element.classList.add("is-glitching");
    const started = performance.now();
    (function frame() {
      const t = performance.now() - started;
      if (t >= duration) {
        layer.remove();
        element.classList.remove("is-glitching");
        element.style.removeProperty("clip-path");
        element.style.removeProperty("transform");
        busy = false;
        return;
      }
      ghosts.forEach((ghost, i) => {
        const top = random(0, 70), bottom = random(0, 100 - top - 8);
        ghost.style.clipPath = `inset(${top}% 0 ${bottom}% 0)`;
        ghost.style.transform = `translateX(${(i ? 1 : -1) * random(strength * 0.4, strength)}px)`;
      });
      const cut = random(10, 80);
      element.style.clipPath = Math.random() < 0.5 ? `polygon(0 0, 100% 0, 100% ${cut}%, 0 ${cut}%, 0 ${cut + 6}%, 100% ${cut + 6}%, 100% 100%, 0 100%)` : "";
      element.style.transform = Math.random() < 0.4 ? `translateX(${random(-strength, strength) * 0.5}px)` : "";
      setTimeout(frame, STEP);
    })();
    return true;
  }

  // Full-viewport signal drop, at most once per visit.
  function signalDrop() {
    if (signalDone || !allowed() || interacting) return;
    signalDone = true;
    busy = true;
    const overlay = document.createElement("div");
    overlay.className = "signal-drop";
    overlay.setAttribute("aria-hidden", "true");
    const colors = ["#00f0ff", "#ff2bd6", "#ff4a00", "#f2f0e6"];
    for (let i = 0; i < 7; i++) {
      const bar = document.createElement("i");
      Object.assign(bar.style, { top: random(0, 96) + "vh", height: random(0.6, 7) + "vh", background: colors[i % colors.length], transform: `translateX(${random(-30, 30)}vw)` });
      overlay.append(bar);
    }
    document.body.append(overlay);
    document.documentElement.classList.add("is-signal-drop");
    const main = document.querySelector("main");
    let frames = 0;
    (function frame() {
      if (++frames > 4) {
        overlay.remove();
        document.documentElement.classList.remove("is-signal-drop");
        if (main) main.style.removeProperty("transform");
        busy = false;
        return;
      }
      overlay.querySelectorAll("i").forEach((bar) => { bar.style.transform = `translateX(${random(-40, 40)}vw) scaleY(${random(0.4, 1.6)})`; });
      if (main) main.style.transform = `translateX(${random(-14, 14)}px)`;
      setTimeout(frame, STEP);
    })();
  }

  // Never glitch what the user is working with.
  ["pointerdown", "keydown", "selectionchange"].forEach((type) => document.addEventListener(type, () => {
    interacting = true;
    clearTimeout(signalDrop.idle);
    signalDrop.idle = setTimeout(() => { interacting = false; }, 1500);
  }));

  document.addEventListener("imic:glitch", (event) => event.detail?.level === "signal" ? signalDrop() : glitch(event.detail?.target, event.detail?.level));

  // MEDIUM: the headline, shortly after load, then every 25–50 s while it is on screen.
  const title = document.querySelector("#hero-title");
  let titleVisible = true;
  if (title && "IntersectionObserver" in window) {
    new IntersectionObserver(([entry]) => { titleVisible = entry.isIntersecting; }).observe(title.closest(".hero") || title);
    const schedule = (delay) => setTimeout(() => {
      if (titleVisible) glitch(document.querySelector("#hero-title"), "medium");
      schedule(random(25000, 50000));
    }, delay);
    schedule(random(2000, 4000));
  }

  // SMALL: pixel labels, once each as they scroll in, about a third of the time.
  if ("IntersectionObserver" in window) {
    const labels = new IntersectionObserver((entries) => {
      entries.forEach(({ target, isIntersecting }) => {
        if (!isIntersecting) return;
        labels.unobserve(target);
        if (Math.random() < 0.3) setTimeout(() => glitch(target, "small"), random(150, 600));
      });
    }, { threshold: 0.8 });
    document.querySelectorAll("main .pixel").forEach((label) => labels.observe(label));
  }

  // Download button: once per visit on first hover.
  const download = document.querySelector(".hero .button.primary");
  if (download) download.addEventListener("pointerenter", () => glitch(download, "small"), { once: true });

  // LARGE: one signal drop per visit, somewhere after the first minute on the page.
  setTimeout(() => {
    const attempt = () => { if (!signalDone) { if (allowed() && !interacting) signalDrop(); else setTimeout(attempt, 5000); } };
    attempt();
  }, random(60000, 90000));
})();

/* Selection halo: CSS cannot light up the selection box itself, so glowing boxes are laid
   exactly behind each selected line. Unselected text is untouched; the halo follows the
   selection and disappears with it. */
(() => {
  "use strict";
  const layer = document.createElement("div");
  layer.className = "selection-glow";
  layer.setAttribute("aria-hidden", "true");
  document.body.append(layer);
  let queued = false;
  function draw() {
    queued = false;
    const selection = getSelection();
    layer.replaceChildren();
    if (!selection || selection.isCollapsed || !selection.rangeCount) return;
    const rects = [];
    for (let i = 0; i < selection.rangeCount; i++) rects.push(...selection.getRangeAt(i).getClientRects());
    const x = scrollX, y = scrollY;
    rects.filter((r) => r.width > 1 && r.height > 1).slice(0, 240).forEach((r) => {
      const box = document.createElement("i");
      Object.assign(box.style, { left: r.left + x + "px", top: r.top + y + "px", width: r.width + "px", height: r.height + "px" });
      layer.append(box);
    });
  }
  const queue = () => { if (!queued) { queued = true; requestAnimationFrame(draw); } };
  document.addEventListener("selectionchange", queue);
  addEventListener("resize", queue);
})();
