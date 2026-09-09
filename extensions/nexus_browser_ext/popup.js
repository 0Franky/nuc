// Nexus Universal Continuity - Popup Controller Script

document.addEventListener("DOMContentLoaded", () => {
  const statusCard = document.getElementById("statusCard");
  const statusDot = document.getElementById("statusDot");
  const statusLabel = document.getElementById("statusLabel");
  const statusDesc = document.getElementById("statusDesc");
  const reconnectBtn = document.getElementById("reconnectBtn");
  const btnIcon = document.getElementById("btnIcon");
  const btnText = document.getElementById("btnText");
  const mediaTitle = document.getElementById("mediaTitle");
  const mediaMeta = document.getElementById("mediaMeta");
  const mediaLiveIndicator = document.getElementById("mediaLiveIndicator");

  function renderStatus(state, retryCount = 0, maxRetries = 5, errorMsg = "", activeMedia = null) {
    statusCard.className = "status-card";
    statusDot.className = "dot";

    switch (state) {
      case "CONNECTED":
        statusCard.classList.add("connected");
        statusDot.classList.add("connected");
        statusLabel.textContent = "Core Connesso";
        statusLabel.style.color = "#10B981";
        statusDesc.textContent = "Connesso al Demone Nexus su ws://127.0.0.1:28471/media. Flusso sincronizzato.";
        reconnectBtn.style.display = "none";
        break;

      case "CONNECTING":
        statusDot.classList.add("connecting");
        statusLabel.textContent = "In Connessione...";
        statusLabel.style.color = "#818CF8";
        statusDesc.textContent = "Tentativo di connessione con il Core locale...";
        reconnectBtn.style.display = "flex";
        btnText.textContent = "In Connessione...";
        btnIcon.className = "spin";
        break;

      case "RETRYING":
        statusCard.classList.add("retrying");
        statusDot.classList.add("retrying");
        statusLabel.textContent = `Riconnessione (${retryCount}/${maxRetries})`;
        statusLabel.style.color = "#F59E0B";
        statusDesc.textContent = `Demone non ancora raggiungibile. Nuovo tentativo automatico in corso (${retryCount}/${maxRetries})...`;
        reconnectBtn.style.display = "flex";
        btnText.textContent = "Riconnetti Subito";
        btnIcon.className = "";
        break;

      case "FAILED":
        statusCard.classList.add("failed");
        statusDot.classList.add("failed");
        statusLabel.textContent = "Demone Offline (5/5 Falliti)";
        statusLabel.style.color = "#EF4444";
        statusDesc.textContent = "Nessun servizio in ascolto su 127.0.0.1:28471. Avvia 'nexus-daemon.exe' o 'nexus_ui.exe' sul PC e clicca Riconnetti.";
        reconnectBtn.style.display = "flex";
        btnText.textContent = "Riconnetti Ora";
        btnIcon.className = "";
        break;

      default:
        statusLabel.textContent = "Inizializzazione...";
        statusDesc.textContent = "Ricerca del demone Nexus in background...";
        reconnectBtn.style.display = "flex";
    }

    // Media info rendering
    if (activeMedia && activeMedia.media_title) {
      mediaTitle.textContent = activeMedia.media_title;
      const curSec = Math.floor((activeMedia.position_ms || 0) / 1000);
      const min = Math.floor(curSec / 60);
      const sec = curSec % 60;
      const timeStr = `${String(min).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
      const stateStr = activeMedia.is_playing ? "In riproduzione" : "In pausa";
      
      mediaMeta.textContent = `${activeMedia.source_app || "Browser"} • Posizione ${timeStr} • ${stateStr}`;
      mediaLiveIndicator.style.display = "inline";
    } else {
      mediaTitle.textContent = "Nessun video rilevato";
      mediaMeta.textContent = "Apri un video su YouTube per la sincronizzazione continua.";
      mediaLiveIndicator.style.display = "none";
    }
  }

  // Refresh status from service worker
  function updateUI() {
    chrome.runtime.sendMessage({ type: "GET_STATUS" }, (response) => {
      if (chrome.runtime.lastError || !response) {
        // Fallback to storage
        chrome.storage.local.get(
          ["connectionState", "retryCount", "maxRetries", "lastError", "activeMedia"],
          (data) => {
            renderStatus(
              data.connectionState || "FAILED",
              data.retryCount || 5,
              data.maxRetries || 5,
              data.lastError || "",
              data.activeMedia || null
            );
          }
        );
      } else {
        renderStatus(
          response.connectionState,
          response.retryCount,
          response.maxRetries,
          response.lastError,
          response.activeMedia
        );
      }
    });
  }

  // Listen for storage changes
  chrome.storage.onChanged.addListener(() => {
    updateUI();
  });

  // Reconnect button click listener
  reconnectBtn.addEventListener("click", () => {
    btnText.textContent = "Connessione...";
    btnIcon.className = "spin";
    reconnectBtn.classList.add("loading");

    chrome.runtime.sendMessage({ type: "NEXUS_RECONNECT_NOW" }, () => {
      setTimeout(() => {
        reconnectBtn.classList.remove("loading");
        updateUI();
      }, 600);
    });
  });

  // Initial load
  updateUI();
  setInterval(updateUI, 1500);
});
