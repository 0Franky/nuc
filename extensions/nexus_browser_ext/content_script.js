// Nexus Universal Continuity - Browser Content Script (Manifest V3)
(function () {
  let activeVideo = null;
  let lastReportedTime = 0;
  let lastIsPlaying = null;
  let lastReportedUrl = "";
  let keepAlivePort = null;
  let isContextInvalidated = false;

  // -------------------------------------------------------------
  // Safe Messaging, Logging & Runtime Guard
  // -------------------------------------------------------------
  function isExtensionValid() {
    if (isContextInvalidated) return false;
    try {
      return (
        typeof chrome !== "undefined" &&
        Boolean(chrome.runtime) &&
        typeof chrome.runtime.sendMessage === "function" &&
        Boolean(chrome.runtime.id)
      );
    } catch (_) {
      isContextInvalidated = true;
      return false;
    }
  }

  function logToEcosystem(msg) {
    console.log("[Nexus]", msg);
    if (!isExtensionValid()) return;
    try {
      chrome.runtime.sendMessage({
        type: "EXTENSION_LOG",
        log: `[ContentScript @ ${window.location.hostname}] ${msg}`,
      }, () => {
        const _ = chrome.runtime.lastError;
      });
    } catch (_) {}
  }

  function safeSendMessage(payload) {
    if (!isExtensionValid()) return;
    try {
      const p = chrome.runtime.sendMessage(payload, () => {
        if (chrome.runtime && chrome.runtime.lastError) {
          // Expected when service worker is temporarily cycling
        }
      });
      if (p && typeof p.catch === "function") {
        p.catch(() => {});
      }
    } catch (err) {
      if (err && err.message && err.message.includes("Extension context invalidated")) {
        isContextInvalidated = true;
      }
    }
  }

  // -------------------------------------------------------------
  // Keep-Alive Connection to prevent Service Worker sleep in MV3
  // -------------------------------------------------------------
  function establishKeepAlive() {
    if (!isExtensionValid()) return;
    try {
      keepAlivePort = chrome.runtime.connect({ name: "nexus_keepalive" });
      keepAlivePort.onDisconnect.addListener(() => {
        keepAlivePort = null;
        if (isExtensionValid()) {
          setTimeout(establishKeepAlive, 3000);
        }
      });
    } catch (_) {}
  }
  establishKeepAlive();
  logToEcosystem(`Injected and active on: ${window.location.href}`);

  // -------------------------------------------------------------
  // Video Discovery & YouTube Internal API Metadata Extractors
  // -------------------------------------------------------------
  function findPrimaryVideo() {
    // 1. YouTube specific player selection
    if (window.location.hostname.includes("youtube.com")) {
      // If user is on home/feed/channel page and not on a watch or shorts page,
      // ignore hover preview videos!
      const isWatchPage = window.location.pathname.startsWith("/watch");
      const isShortsPage = window.location.pathname.startsWith("/shorts");

      if (!isWatchPage && !isShortsPage) {
        // Only consider if there is an active fullscreen or prominent player
        const main = document.querySelector("#movie_player video.html5-main-video");
        if (main && !main.paused && main.duration > 30) return main;
        return null;
      }

      // Priority: watch page main video
      const ytMain = document.querySelector(
        "ytd-watch-flexy video.html5-main-video, #movie_player video.html5-main-video, ytd-player video"
      );
      if (ytMain) return ytMain;

      // Shorts video
      const shortsVideo = document.querySelector("ytd-shorts video, #shorts-player video");
      if (shortsVideo) return shortsVideo;
    }

    // 2. Generic HTML5 video: ignore tiny elements (like tracking pixels or ads < 150px)
    const allVideos = Array.from(document.querySelectorAll("video")).filter((v) => {
      try {
        const rect = v.getBoundingClientRect();
        return (rect.width > 120 && rect.height > 80) || v.duration > 0;
      } catch (_) {
        return true;
      }
    });

    if (allVideos.length === 0) return null;

    return (
      allVideos.find((v) => !v.paused && v.currentTime > 0) ||
      allVideos.find((v) => !v.paused) ||
      allVideos.find((v) => v.duration > 0) ||
      allVideos[0]
    );
  }

  function getMediaTitle() {
    // 1. YouTube internal movie_player API (Most reliable on modern YouTube)
    try {
      const moviePlayer = document.getElementById("movie_player");
      if (moviePlayer && typeof moviePlayer.getVideoData === "function") {
        const data = moviePlayer.getVideoData();
        if (data && data.title && data.title.trim()) {
          return data.title.trim();
        }
      }
    } catch (_) {}

    // 2. Modern YouTube watch page title elements
    const selectors = [
      "h1.ytd-watch-metadata yt-formatted-string",
      "#title h1 yt-formatted-string",
      "ytd-watch-metadata #title",
      "h1.title.style-scope.ytd-video-primary-info-renderer",
      "h2.title.ytd-reel-player-header-renderer",
      "#video-title",
    ];

    for (const sel of selectors) {
      const el = document.querySelector(sel);
      if (el && el.innerText && el.innerText.trim().length > 0) {
        return el.innerText.trim();
      }
    }

    // 3. Meta Tags
    const metaTitle = document.querySelector('meta[name="title"], meta[property="og:title"]');
    if (metaTitle && metaTitle.content && metaTitle.content.trim()) {
      return metaTitle.content.trim();
    }

    // 4. Document title fallback
    const docTitle = document.title
      .replace(/ - YouTube$/, "")
      .replace(/ - Google Chrome$/, "")
      .trim();

    return docTitle || "Video in Riproduzione";
  }

  function getMediaUrl() {
    // 1. YouTube player API
    try {
      const moviePlayer = document.getElementById("movie_player");
      if (moviePlayer && typeof moviePlayer.getVideoUrl === "function") {
        const url = moviePlayer.getVideoUrl();
        if (url && url.startsWith("http")) return url;
      }
    } catch (_) {}

    // 2. YouTube canonical watch URL extraction
    if (window.location.hostname.includes("youtube.com")) {
      if (window.location.pathname.startsWith("/watch")) {
        const params = new URLSearchParams(window.location.search);
        const v = params.get("v");
        if (v) return `https://www.youtube.com/watch?v=${v}`;
      } else if (window.location.pathname.startsWith("/shorts/")) {
        const parts = window.location.pathname.split("/");
        const shortId = parts[2];
        if (shortId) return `https://www.youtube.com/shorts/${shortId}`;
      }
    }

    return window.location.href;
  }

  function reportMediaState(video, force = false) {
    if (!video || isContextInvalidated) return;

    const rawCurrentTime = Number.isFinite(video.currentTime) ? video.currentTime : 0;
    const rawDuration = Number.isFinite(video.duration) && video.duration > 0 ? video.duration : 1800;

    const currentTimeMs = Math.floor(rawCurrentTime * 1000);
    const durationMs = Math.floor(rawDuration * 1000);
    const isPlaying = !video.paused && !video.ended;
    const currentUrl = getMediaUrl();
    const title = getMediaTitle();

    const timeDelta = Math.abs(currentTimeMs - lastReportedTime);
    const urlChanged = currentUrl !== lastReportedUrl;
    const playStateChanged = isPlaying !== lastIsPlaying;

    if (!force && !urlChanged && !playStateChanged && timeDelta < 1500) {
      return;
    }

    lastReportedTime = currentTimeMs;
    lastIsPlaying = isPlaying;
    lastReportedUrl = currentUrl;

    const payload = {
      type: "NEXUS_MEDIA_STATE_UPDATE",
      source_app: "YouTube (" + (window.location.hostname || "Browser") + ")",
      media_title: title,
      media_url: currentUrl,
      position_ms: currentTimeMs,
      duration_ms: durationMs,
      is_playing: isPlaying,
      is_visible: !document.hidden,
      is_audible: !video.muted && video.volume > 0 && isPlaying,
    };

    logToEcosystem(
      `Reporting: "${title}" @ ${Math.floor(currentTimeMs / 1000)}s (playing: ${isPlaying}, visible: ${!document.hidden})`
    );

    safeSendMessage(payload);
  }

  function attachVideoListeners(video) {
    if (!video || video.dataset.nexusAttached) return;
    video.dataset.nexusAttached = "true";
    activeVideo = video;

    const events = [
      "play",
      "playing",
      "pause",
      "seeking",
      "seeked",
      "timeupdate",
      "ended",
      "ratechange",
      "loadedmetadata",
    ];
    events.forEach((evt) => {
      video.addEventListener(evt, () => reportMediaState(video));
    });

    logToEcosystem(`Attached listeners to HTML5 video element (duration: ${video.duration}s)`);
    reportMediaState(video, true);
  }

  // Hook YouTube SPA navigation events
  window.addEventListener("yt-navigate-finish", () => {
    logToEcosystem("Event 'yt-navigate-finish' detected");
    setTimeout(() => {
      const v = findPrimaryVideo();
      if (v) attachVideoListeners(v);
      reportMediaState(v, true);
    }, 500);
  });

  window.addEventListener("yt-page-data-updated", () => {
    logToEcosystem("Event 'yt-page-data-updated' detected");
    const v = findPrimaryVideo();
    if (v) reportMediaState(v, true);
  });

  window.addEventListener("popstate", () => {
    setTimeout(() => {
      const v = findPrimaryVideo();
      if (v) reportMediaState(v, true);
    }, 500);
  });

  // Continuous scanner (Checks every 1000ms for video playback)
  const scanInterval = setInterval(() => {
    if (isContextInvalidated) {
      clearInterval(scanInterval);
      return;
    }
    const video = findPrimaryVideo();
    if (video) {
      if (video !== activeVideo || !video.dataset.nexusAttached) {
        attachVideoListeners(video);
      }
      if (!video.paused) {
        reportMediaState(video, false);
      }
    }
  }, 1000);

  // Initial immediate check
  setTimeout(() => {
    const v = findPrimaryVideo();
    if (v) attachVideoListeners(v);
  }, 500);

  // Remote commands listener (PAUSE / PLAY / SEEK)
  if (isExtensionValid() && chrome.runtime.onMessage) {
    try {
      chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
        if (!message) return;
        const v = findPrimaryVideo();
        const moviePlayer = document.getElementById("movie_player");

        if (message.action === "PAUSE") {
          if (moviePlayer && typeof moviePlayer.pauseVideo === "function") {
            moviePlayer.pauseVideo();
          } else if (v) {
            v.pause();
          }
          if (v) reportMediaState(v, true);
          logToEcosystem("Received and executed PAUSE command on YouTube player");
          sendResponse({ status: "paused" });
        } else if (message.action === "PLAY") {
          if (moviePlayer && typeof moviePlayer.playVideo === "function") {
            moviePlayer.playVideo();
          } else if (v) {
            v.play().catch(() => {});
          }
          if (v) reportMediaState(v, true);
          logToEcosystem("Received and executed PLAY command on YouTube player");
          sendResponse({ status: "playing" });
        } else if (message.action === "SEEK" && typeof message.position_ms === "number") {
          const targetSec = message.position_ms / 1000;
          if (moviePlayer && typeof moviePlayer.seekTo === "function") {
            moviePlayer.seekTo(targetSec, true);
          } else if (v) {
            v.currentTime = targetSec;
          }
          if (v) reportMediaState(v, true);
          logToEcosystem(`Received and executed SEEK to ${targetSec}s`);
          sendResponse({ status: "seeked" });
        }
      });
    } catch (_) {}
  }
})();
