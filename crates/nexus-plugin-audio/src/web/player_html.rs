pub fn get_player_html(vol: f32) -> String {
    format!(
        r#"<!DOCTYPE html>
<html lang="it">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Nexus Private Listening - Cuffie Smartphone</title>
  <script src="https://cdn.tailwindcss.com"></script>
</head>
<body class="bg-slate-950 text-slate-100 flex flex-col items-center justify-center min-h-screen p-4 select-none">
  <div class="bg-slate-900 border border-indigo-500/30 rounded-3xl p-6 shadow-2xl max-w-sm w-full text-center">
    <div class="w-16 h-16 bg-indigo-500/20 text-indigo-400 rounded-full flex items-center justify-center mx-auto mb-3 text-3xl shadow-inner animate-pulse">
      🎧
    </div>
    <h1 class="text-2xl font-black tracking-tight">Private Listening</h1>
    <p class="text-xs text-slate-400 mt-0.5">Ascolto audio PC su smartphone</p>

    <!-- Mode Selector Tabs -->
    <div class="mt-4 p-1 bg-slate-950 rounded-2xl border border-slate-800 grid grid-cols-2 gap-1 text-xs font-bold">
      <button id="tabRealtime" onclick="setMode('realtime')" class="py-2.5 px-2 rounded-xl transition bg-indigo-600 text-white shadow-md flex items-center justify-center gap-1.5">
        <span>⚡ Tempo Reale</span>
      </button>
      <button id="tabBuffered" onclick="setMode('buffered')" class="py-2.5 px-2 rounded-xl transition text-slate-400 hover:text-slate-200 flex items-center justify-center gap-1.5">
        <span>💎 Alta Fedeltà</span>
      </button>
    </div>
    
    <div id="modeDesc" class="mt-2 text-[11px] text-emerald-400 font-medium">
      ⚡ Latenza ~15ms: ideale per video, film e gaming
    </div>

    <!-- Visualizer Canvas -->
    <div class="my-4 p-3 bg-slate-950 rounded-2xl border border-slate-800 flex flex-col items-center">
      <canvas id="visualizer" width="280" height="55" class="rounded-lg w-full"></canvas>
      <div id="statusBadge" class="mt-2.5 inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-slate-800 text-slate-400">
        <span id="statusDot" class="w-2 h-2 rounded-full bg-slate-600"></span> <span id="statusText">Pronto • Tocca Avvia</span>
      </div>
    </div>

    <!-- Buffer Preset Selector (Visible in Hi-Fi Mode) -->
    <div id="bufferControls" class="hidden mb-4 p-2.5 bg-slate-950/80 rounded-xl border border-slate-800 text-left">
      <div class="flex justify-between items-center text-[11px] font-semibold text-slate-400 mb-1.5">
        <span>🛡️ Dimensione Buffer Anti-Lag</span>
        <span id="bufferValueLabel" class="text-indigo-400 font-mono">1.5s (Consigliato)</span>
      </div>
      <div class="grid grid-cols-3 gap-1.5 text-[11px]">
        <button onclick="setBufferPreset(0.5, '500ms (Veloce)')" class="py-1 px-2 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 font-medium">500ms</button>
        <button onclick="setBufferPreset(1.5, '1.5s (Hi-Fi)')" class="py-1 px-2 rounded-lg bg-indigo-600 text-white font-bold">1.5s</button>
        <button onclick="setBufferPreset(3.0, '3.0s (Stabile)')" class="py-1 px-2 rounded-lg bg-slate-800 hover:bg-slate-700 text-slate-300 font-medium">3.0s</button>
      </div>
    </div>

    <!-- Main Action Button -->
    <button id="playBtn" onclick="toggleAudio()" class="w-full bg-gradient-to-r from-indigo-600 to-indigo-500 hover:from-indigo-500 hover:to-indigo-400 active:scale-95 text-white font-bold py-3.5 px-4 rounded-2xl shadow-lg transition flex items-center justify-center gap-2 text-base">
      <span id="btnIcon">▶️</span> <span id="btnText">Avvia Ascolto</span>
    </button>

    <!-- Volume and Mute Controls -->
    <div class="mt-5 pt-4 border-t border-slate-800 flex items-center justify-between gap-3">
      <div class="flex items-center gap-2 flex-1">
        <span class="text-xs">🔈</span>
        <input id="volSlider" type="range" min="0" max="100" value="{}" oninput="setVol(this.value)" class="w-full h-1.5 bg-slate-800 rounded-lg appearance-none cursor-pointer accent-indigo-500">
        <span id="volLabel" class="text-xs font-mono text-slate-400 w-8">{}%</span>
      </div>

      <div class="flex items-center gap-1.5">
        <button id="muteBtn" onclick="toggleMute()" class="px-2.5 py-1.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-bold transition flex items-center gap-1.5">
          <span id="muteIcon">🔊</span> <span id="muteText">Cuffie</span>
        </button>
        <button onclick="togglePcSpeakers()" title="Muta/Smuta Altoparlanti PC Fisici" class="px-2.5 py-1.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-400 hover:text-slate-200 text-xs font-bold transition flex items-center gap-1">
          💻 Muta PC
        </button>
      </div>
    </div>
  </div>

  <audio id="nativeAudio" class="hidden"></audio>

  <script>
    let isPlaying = false;
    let currentMode = 'realtime'; // 'realtime' or 'buffered'
    let audioCtx = null;
    let gainNode = null;
    let analyser = null;
    let ws = null;
    let scheduledTime = 0;
    const nativeAudio = document.getElementById('nativeAudio');

    function setMode(mode) {{
      if (currentMode === mode) return;
      currentMode = mode;

      const tabRealtime = document.getElementById('tabRealtime');
      const tabBuffered = document.getElementById('tabBuffered');
      const modeDesc = document.getElementById('modeDesc');
      const bufferControls = document.getElementById('bufferControls');

      if (mode === 'realtime') {{
        tabRealtime.className = "py-2.5 px-2 rounded-xl transition bg-indigo-600 text-white shadow-md flex items-center justify-center gap-1.5";
        tabBuffered.className = "py-2.5 px-2 rounded-xl transition text-slate-400 hover:text-slate-200 flex items-center justify-center gap-1.5";
        modeDesc.innerText = "⚡ Latenza ~15ms: ideale per video, film e gaming";
        modeDesc.className = "mt-2 text-[11px] text-emerald-400 font-medium";
        bufferControls.classList.add('hidden');
      }} else {{
        tabBuffered.className = "py-2.5 px-2 rounded-xl transition bg-indigo-600 text-white shadow-md flex items-center justify-center gap-1.5";
        tabRealtime.className = "py-2.5 px-2 rounded-xl transition text-slate-400 hover:text-slate-200 flex items-center justify-center gap-1.5";
        modeDesc.innerText = "💎 Buffer anti-lag dinamico per ascolto musicale perfetto";
        modeDesc.className = "mt-2 text-[11px] text-indigo-400 font-medium";
        bufferControls.classList.remove('hidden');
      }}

      if (isPlaying) {{
        stopPlayback();
        startPlayback();
      }}
    }}

    function setBufferPreset(sec, label) {{
      document.getElementById('bufferValueLabel').innerText = label;
      if (isPlaying && currentMode === 'buffered') {{
        startBufferedStream();
      }}
    }}

    async function initAudioContext() {{
      if (!audioCtx) {{
        const AudioContext = window.AudioContext || window.webkitAudioContext;
        audioCtx = new AudioContext({{
          latencyHint: 'interactive',
          sampleRate: 48000
        }});
        gainNode = audioCtx.createGain();
        gainNode.gain.value = document.getElementById('volSlider').value / 100;
        analyser = audioCtx.createAnalyser();
        analyser.fftSize = 64;
        gainNode.connect(analyser);
        analyser.connect(audioCtx.destination);
      }}
      if (audioCtx.state === 'suspended') {{
        await audioCtx.resume();
      }}
    }}

    async function toggleAudio() {{
      if (isPlaying) {{
        stopPlayback();
      }} else {{
        startPlayback();
      }}
    }}

    async function startPlayback() {{
      await initAudioContext();
      isPlaying = true;

      if (currentMode === 'realtime') {{
        startWebSocketRealtime();
      }} else {{
        startBufferedStream();
      }}

      document.getElementById('btnText').innerText = "Pausa Ascolto";
      document.getElementById('btnIcon').innerText = "⏸️";
      document.getElementById('statusBadge').className = currentMode === 'realtime'
        ? "mt-2.5 inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-emerald-500/20 text-emerald-400"
        : "mt-2.5 inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-purple-500/20 text-purple-300";
      document.getElementById('statusDot').className = "w-2 h-2 rounded-full bg-emerald-500 animate-pulse";
      document.getElementById('statusText').innerText = currentMode === 'realtime'
        ? "🟢 Tempo Reale Attivo (~15ms)"
        : "💎 Alta Fedeltà Buffer Attiva";
    }}

    function stopPlayback() {{
      isPlaying = false;
      if (ws) {{
        ws.close();
        ws = null;
      }}
      nativeAudio.pause();
      nativeAudio.src = "";

      document.getElementById('btnText').innerText = "Avvia Ascolto";
      document.getElementById('btnIcon').innerText = "▶️";
      document.getElementById('statusBadge').className = "mt-2.5 inline-flex items-center gap-2 px-3 py-1 rounded-full text-xs font-semibold bg-slate-800 text-slate-400";
      document.getElementById('statusDot').className = "w-2 h-2 rounded-full bg-slate-600";
      document.getElementById('statusText').innerText = "In Pausa";
    }}

    function startWebSocketRealtime() {{
      const loc = window.location;
      const wsProtocol = loc.protocol === 'https:' ? 'wss://' : 'ws://';
      ws = new WebSocket(wsProtocol + loc.host);
      ws.binaryType = 'arraybuffer';

      ws.onopen = function() {{
        document.getElementById('statusText').innerText = "🟢 Connesso Tempo Reale (~15ms)";
      }};

      ws.onmessage = function(event) {{
        if (!isPlaying || !audioCtx || currentMode !== 'realtime') return;
        const arrayBuffer = event.data;
        const int16 = new Int16Array(arrayBuffer);
        const numFrames = int16.length / 2;

        const buffer = audioCtx.createBuffer(2, numFrames, 48000);
        const left = buffer.getChannelData(0);
        const right = buffer.getChannelData(1);

        for (let i = 0; i < numFrames; i++) {{
          left[i] = int16[i * 2] / 32768.0;
          right[i] = int16[i * 2 + 1] / 32768.0;
        }}

        const source = audioCtx.createBufferSource();
        source.buffer = buffer;
        source.connect(gainNode);

        const currentTime = audioCtx.currentTime;
        if (scheduledTime < currentTime || scheduledTime > (currentTime + 0.045)) {{
          scheduledTime = currentTime + 0.012; // 12ms target
        }}

        source.start(scheduledTime);
        scheduledTime += buffer.duration;
      }};

      ws.onclose = function() {{
        if (isPlaying && currentMode === 'realtime') {{
          setTimeout(() => {{ if (isPlaying && currentMode === 'realtime') startWebSocketRealtime(); }}, 1000);
        }}
      }};
    }}

    function startBufferedStream() {{
      nativeAudio.src = "/stream.wav?t=" + Date.now();
      nativeAudio.volume = document.getElementById('volSlider').value / 100;
      
      try {{
        if (!nativeAudio._sourceConnected && audioCtx) {{
          const source = audioCtx.createMediaElementSource(nativeAudio);
          source.connect(gainNode);
          nativeAudio._sourceConnected = true;
        }}
      }} catch (e) {{
        console.log("MediaElementSource hook:", e);
      }}

      nativeAudio.play().then(() => {{
        document.getElementById('statusText').innerText = "💎 Buffer Hi-Fi Attivo (Zero Glitch)";
      }}).catch(err => {{
        console.log("Buffered playback error:", err);
      }});
    }}

    async function toggleMute() {{
      try {{
        const res = await fetch('/api/mute');
        const data = await res.json();
        updateMuteUI(data.muted);
      }} catch (e) {{}}
    }}

    function updateMuteUI(isMuted) {{
      const btn = document.getElementById('muteBtn');
      const icon = document.getElementById('muteIcon');
      const text = document.getElementById('muteText');
      if (isMuted) {{
        btn.className = "px-2.5 py-1.5 rounded-xl bg-red-600/30 border border-red-500/50 text-red-400 text-xs font-bold transition flex items-center gap-1.5";
        icon.innerText = "🔇";
        text.innerText = "Muto";
        if (gainNode) gainNode.gain.value = 0;
        if (nativeAudio) nativeAudio.volume = 0;
      }} else {{
        btn.className = "px-2.5 py-1.5 rounded-xl bg-slate-800 hover:bg-slate-700 text-slate-300 text-xs font-bold transition flex items-center gap-1.5";
        icon.innerText = "🔊";
        text.innerText = "Cuffie";
        const v = document.getElementById('volSlider').value / 100;
        if (gainNode) gainNode.gain.value = v;
        if (nativeAudio) nativeAudio.volume = v;
      }}
    }}

    async function togglePcSpeakers() {{
      try {{
        await fetch('/api/pc_mute');
      }} catch (e) {{}}
    }}

    function setVol(v) {{
      document.getElementById('volLabel').innerText = v + "%";
      if (gainNode) {{
        gainNode.gain.value = v / 100;
      }}
      if (nativeAudio) {{
        nativeAudio.volume = v / 100;
      }}
      updateMuteUI(false);
      fetch('/api/volume?v=' + (v / 100)).catch(() => {{}});
    }}
  </script>
</body>
</html>"#,
        (vol * 100.0) as u32,
        (vol * 100.0) as u32
    )
}
