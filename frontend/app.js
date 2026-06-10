/* County Narrator frontend */
"use strict";

const $ = (id) => document.getElementById(id);

const state = {
  selectedVoice: localStorage.getItem("narrator_voice") || "",  // "" = built-in
  pollTimer: null,
  previewOpen: null,
};

/* ── helpers ─────────────────────────────────────────────── */

async function api(path, options) {
  const res = await fetch(path, options);
  if (!res.ok) {
    let detail = `HTTP ${res.status}`;
    try { detail = (await res.json()).detail || detail; } catch { /* not json */ }
    throw new Error(detail);
  }
  return res.status === 204 ? null : res.json();
}

function escapeHtml(s) {
  const div = document.createElement("div");
  div.textContent = s;
  return div.innerHTML;
}

/* ── health/status ───────────────────────────────────────── */

async function refreshHealth() {
  const dot = $("status-dot"), txt = $("status-text");
  try {
    const h = await api("/api/health");
    if (h.model_error) {
      dot.className = "dot dot-err";
      txt.textContent = "Model failed to load — check logs";
    } else if (!h.model_loaded) {
      dot.className = "dot dot-warn";
      txt.textContent = "Warming up — loading model…";
      setTimeout(refreshHealth, 4000);
    } else {
      dot.className = "dot dot-ok";
      txt.textContent = `Online · ${h.device.toUpperCase()} · Turbo · v${h.version}`;
    }
    $("generate").disabled = !h.model_loaded;
  } catch {
    dot.className = "dot dot-err";
    txt.textContent = "Backend unreachable";
    setTimeout(refreshHealth, 5000);
  }
}

/* ── script editor ───────────────────────────────────────── */

function updateCounter() {
  const text = $("script").value;
  $("char-count").textContent = `${text.length} characters`;
  if (text.length) {
    const chunks = Math.max(1, Math.ceil(text.length / 280));
    const eta = chunks * 4;
    $("chunk-est").textContent =
      `~${chunks} chunk${chunks > 1 ? "s" : ""} · est. ${eta < 60 ? eta + "s" : Math.round(eta / 60) + "m"}`;
  } else {
    $("chunk-est").textContent = "";
  }
}

function insertTag(tag) {
  const ta = $("script");
  const { selectionStart: start, selectionEnd: end, value } = ta;
  const before = value.slice(0, start), after = value.slice(end);
  const space = before && !before.endsWith(" ") ? " " : "";
  ta.value = `${before}${space}${tag} ${after}`;
  ta.focus();
  ta.selectionStart = ta.selectionEnd = (before + space + tag + " ").length;
  updateCounter();
}

/* ── voices ──────────────────────────────────────────────── */

async function refreshVoices() {
  let voicesList = [];
  try { voicesList = await api("/api/voices"); } catch { /* shown via health */ }

  // If the saved selection no longer exists, fall back to built-in
  if (state.selectedVoice && !voicesList.some(v => v.id === state.selectedVoice)) {
    state.selectedVoice = "";
    localStorage.setItem("narrator_voice", "");
  }

  const container = $("voice-list");
  container.innerHTML = "";
  const entries = [{ id: "", name: "Built-in voice", duration_sec: null }, ...voicesList];

  for (const v of entries) {
    const item = document.createElement("div");
    item.className = "voice-item" + (state.selectedVoice === v.id ? " selected" : "");
    item.innerHTML = `
      <input type="radio" class="voice-radio" name="voice" ${state.selectedVoice === v.id ? "checked" : ""}>
      <div class="voice-info">
        <div class="voice-name">${escapeHtml(v.name)}</div>
        <div class="voice-sub">${v.id ? `${v.duration_sec}s reference clip` : "Ships with the model"}</div>
      </div>
      <div class="voice-actions">
        ${v.id ? `<button class="icon-btn" data-act="play" title="Preview">▶</button>
                  <button class="icon-btn" data-act="del" title="Delete">✕</button>` : ""}
      </div>`;

    item.addEventListener("click", (e) => {
      const act = e.target.dataset && e.target.dataset.act;
      if (act === "del") { e.stopPropagation(); deleteVoice(v); return; }
      if (act === "play") { e.stopPropagation(); togglePreview(item, v); return; }
      state.selectedVoice = v.id;
      localStorage.setItem("narrator_voice", v.id);
      refreshVoices();
    });
    container.appendChild(item);
  }
}

function togglePreview(item, voice) {
  const existing = document.querySelector(".voice-preview");
  if (existing) {
    existing.remove();
    if (state.previewOpen === voice.id) { state.previewOpen = null; return; }
  }
  const audio = document.createElement("audio");
  audio.controls = true;
  audio.className = "voice-preview";
  audio.src = `/api/voices/${voice.id}/audio`;
  item.insertAdjacentElement("afterend", audio);
  audio.play().catch(() => { /* autoplay blocked; user can press play */ });
  state.previewOpen = voice.id;
}

async function deleteVoice(voice) {
  if (!confirm(`Delete voice "${voice.name}"?`)) return;
  try {
    await api(`/api/voices/${voice.id}`, { method: "DELETE" });
    if (state.selectedVoice === voice.id) {
      state.selectedVoice = "";
      localStorage.setItem("narrator_voice", "");
    }
    refreshVoices();
  } catch (e) {
    alert(`Delete failed: ${e.message}`);
  }
}

async function uploadVoice() {
  const name = $("voice-name").value.trim();
  const file = $("voice-file").files[0];
  const msg = $("voice-upload-msg");
  if (!name) { msg.textContent = "Give the voice a name first."; return; }
  if (!file) { msg.textContent = "Choose an audio file."; return; }

  const form = new FormData();
  form.append("name", name);
  form.append("file", file);
  msg.textContent = "Uploading…";
  try {
    const voice = await api("/api/voices", { method: "POST", body: form });
    msg.textContent = `Added "${voice.name}" (${voice.duration_sec}s).`;
    $("voice-name").value = "";
    $("voice-file").value = "";
    state.selectedVoice = voice.id;
    localStorage.setItem("narrator_voice", voice.id);
    refreshVoices();
  } catch (e) {
    msg.textContent = `✕ ${e.message}`;
  }
}

/* ── generation ──────────────────────────────────────────── */

function showOutput(section) {
  for (const id of ["output-idle", "output-progress", "output-done", "output-error"]) {
    $(id).classList.toggle("hidden", id !== section);
  }
}

async function generate() {
  const text = $("script").value.trim();
  if (!text) { showError("Enter some text before generating."); return; }

  $("generate").disabled = true;
  showOutput("output-progress");
  $("progress-text").textContent = "Submitting…";
  $("progress-fill").style.width = "0%";

  try {
    const job = await api("/api/jobs", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ text, voice_id: state.selectedVoice || null }),
    });
    pollJob(job.id);
  } catch (e) {
    showError(e.message);
    $("generate").disabled = false;
  }
}

function pollJob(jobId) {
  clearInterval(state.pollTimer);
  state.pollTimer = setInterval(async () => {
    let job;
    try {
      job = await api(`/api/jobs/${jobId}`);
    } catch (e) {
      clearInterval(state.pollTimer);
      showError(`Lost contact with the job: ${e.message}`);
      $("generate").disabled = false;
      return;
    }

    if (job.status === "queued") {
      $("progress-text").textContent = job.queue_ahead > 0
        ? `Queued — ${job.queue_ahead} job(s) ahead`
        : "Queued…";
    } else if (job.status === "running") {
      const pct = job.chunks_total ? Math.round((job.chunks_done / job.chunks_total) * 100) : 0;
      $("progress-text").textContent = `Synthesizing — chunk ${Math.min(job.chunks_done + 1, job.chunks_total)} of ${job.chunks_total}`;
      $("progress-fill").style.width = `${Math.max(pct, 4)}%`;
    } else if (job.status === "done") {
      clearInterval(state.pollTimer);
      $("progress-fill").style.width = "100%";
      showResult(job);
      $("generate").disabled = false;
      refreshHistory();
    } else if (job.status === "error") {
      clearInterval(state.pollTimer);
      showError(job.error || "Generation failed.");
      $("generate").disabled = false;
    }
  }, 900);
}

function showResult(job) {
  showOutput("output-done");
  $("audio-meta").textContent = `· ${job.duration_sec}s · ${job.voice_name}`;
  $("player").src = `/api/jobs/${job.id}/audio?format=studio`;
  $("dl-pbx").href = `/api/jobs/${job.id}/audio?format=pbx`;
  $("dl-studio").href = `/api/jobs/${job.id}/audio?format=studio`;
}

function showError(message) {
  showOutput("output-error");
  $("output-error").textContent = message;
}

/* ── history ─────────────────────────────────────────────── */

async function refreshHistory() {
  let items = [];
  try { items = await api("/api/history"); } catch { return; }
  const container = $("history");
  if (!items.length) {
    container.innerHTML = '<p class="hint">Nothing yet.</p>';
    return;
  }
  container.innerHTML = "";
  for (const item of items) {
    const row = document.createElement("div");
    row.className = "history-item";
    row.innerHTML = `
      <div style="flex:1;min-width:0;">
        <div class="history-text">${escapeHtml(item.text_preview)}</div>
        <div class="history-sub">${escapeHtml(item.voice_name)} · ${item.duration_sec}s · ${item.created}</div>
      </div>
      <div class="history-actions">
        <a href="/api/jobs/${item.id}/audio?format=pbx">3CX</a>
        <a href="/api/jobs/${item.id}/audio?format=studio">WAV</a>
        <button class="icon-btn" data-act="play" title="Play">▶</button>
        <button class="icon-btn" data-act="del" title="Delete">✕</button>
      </div>`;
    row.querySelector('[data-act="play"]').addEventListener("click", () => {
      showOutput("output-done");
      $("audio-meta").textContent = `· ${item.duration_sec}s · ${item.voice_name}`;
      $("player").src = `/api/jobs/${item.id}/audio?format=studio`;
      $("dl-pbx").href = `/api/jobs/${item.id}/audio?format=pbx`;
      $("dl-studio").href = `/api/jobs/${item.id}/audio?format=studio`;
      $("player").play().catch(() => {});
    });
    row.querySelector('[data-act="del"]').addEventListener("click", async () => {
      try { await api(`/api/history/${item.id}`, { method: "DELETE" }); } catch { /* gone already */ }
      refreshHistory();
    });
    container.appendChild(row);
  }
}

/* ── wire-up ─────────────────────────────────────────────── */

$("script").addEventListener("input", updateCounter);
$("generate").addEventListener("click", generate);
$("clear").addEventListener("click", () => {
  $("script").value = "";
  updateCounter();
  showOutput("output-idle");
});
$("voice-upload").addEventListener("click", uploadVoice);
document.querySelectorAll(".tag-btn").forEach((btn) =>
  btn.addEventListener("click", () => insertTag(btn.dataset.tag)));

refreshHealth();
refreshVoices();
refreshHistory();
updateCounter();
