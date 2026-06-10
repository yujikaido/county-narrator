# 🎙️ County Narrator

**Self-hosted text-to-speech for auto-attendant and voicemail greetings.**

Type a greeting script, pick a voice (or clone one from a short clip), and download a WAV that's **ready to upload straight into the PBX** (NEC 3C Host / 3C Administrator) — plain 16-bit PCM, mono, no conversion step needed. Runs entirely on-premises on a single NVIDIA GPU; no cloud, no per-character fees, no county audio leaving the building.

Built on [Chatterbox Turbo](https://github.com/resemble-ai/chatterbox) (MIT) by Resemble AI — a 350M-parameter model that runs ~6× realtime on a modest GPU and embeds an imperceptible [Perth watermark](https://github.com/resemble-ai/perth) marking the audio as AI-generated.

## Features

- **PBX-ready output** — every generation is exported twice: the 3C Host file (24 kHz / 16-bit PCM / mono — the format proven to upload cleanly into NEC 3C Host / 3C Administrator 10.4.x) and an 8 kHz telephony-rate fallback for prompt slots that demand it.
- **Voice library** — save multiple named reference voices (6–30 s of clean speech: wav/mp3/m4a/flac/ogg) and switch between them per generation. A built-in voice works out of the box.
- **Paralinguistic tags** — drop `[chuckle]`, `[sigh]`, `[gasp]`, `[cough]` into the script for natural touches.
- **Delivery slider** — temperature control from Consistent (0.5) to Lively (1.1). Higher values also vary more between takes, so regenerating the same script gives genuinely different reads — generate a couple and keep the best.
- **Job queue with live progress** — long scripts synthesize chunk by chunk with a progress bar; concurrent users queue instead of colliding on the GPU.
- **Generation history** — the last 50 generations stay downloadable from the UI.
- **Operator console** — `sudo update` opens a whiptail menu: deploy the latest release tag, tail logs, health/GPU checks, backups, disk usage, Docker prune.

## Requirements

- Debian 12/13 LXC or VM with Docker-capable kernel (built for Proxmox LXC).
- NVIDIA GPU with working drivers in the container (`nvidia-smi` works). ~6 GB VRAM is plenty; CPU-only also works, just slow.
- ~10 GB disk for the image + ~2 GB for model weights (cached in `data/hf-cache`).

## Install

### Option A — from GitHub (recommended)

```bash
# inside the LXC, as root
git clone https://github.com/yujikaido/county-narrator.git /opt/county-narrator
bash /opt/county-narrator/install.sh
```

### Option B — copied folder (WinSCP etc.)

Copy this folder anywhere on the box and run `bash install.sh` — it copies itself to `/opt/county-narrator` and continues there. Link git later to enable menu-driven updates:

```bash
cd /opt/county-narrator
git init && git remote add origin https://github.com/yujikaido/county-narrator.git
git fetch && git reset --hard origin/main
```

The installer is idempotent: it installs Docker and the NVIDIA Container Toolkit if missing, enables the GPU compose override when `nvidia-smi` works, installs the `update` command, builds, and starts the stack. First startup downloads ~2 GB of model weights — the UI shows **Warming up** until the model is loaded.

Open `http://<lxc-ip>:8001`.

## Updating

Releases are deployed by git tag — push a tag from your dev machine, then run the update on the LXC:

```bash
# dev machine
git commit -am "..." && git tag v1.1.0 && git push && git push --tags

# LXC
sudo update apply        # or: sudo update → "Apply update"
```

`update apply --hard` additionally pulls a fresh base image (CVE refresh). `sudo update` with no arguments opens the full menu.

## Using the output in the PBX (NEC 3C Host / 3C Administrator)

Download the **“Download for 3C Host”** file and upload it directly as an auto-attendant prompt or voicemail greeting. It is already **WAV, plain 16-bit PCM, mono** — the format 3C Administrator 10.4.x accepts without complaint (float/24-bit/stereo WAVs get rejected). If a particular prompt slot insists on telephony rate, use the **8 kHz** download instead; same audio, resampled with proper anti-aliasing.

## API

The UI is a thin client over a small JSON API:

```text
GET    /api/health                    status, device, model_loaded
GET    /api/voices                    voice library
POST   /api/voices                    multipart: name, file
DELETE /api/voices/{id}
GET    /api/voices/{id}/audio         reference clip playback
POST   /api/jobs                      {"text": "...", "voice_id": null|"<id>", "temperature": 0.8}
GET    /api/jobs/{id}                 status / chunk progress
GET    /api/jobs/{id}/audio?format=pbx|studio
GET    /api/history                   recent generations
DELETE /api/history/{id}
```

Example — generate and fetch a greeting from a script:

```bash
JOB=$(curl -s -X POST http://lxc:8001/api/jobs -H 'Content-Type: application/json' \
  -d '{"text":"Thank you for calling the county offices."}' | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')
# poll until done, then (studio = the 3C Host format; format=pbx for 8 kHz):
curl -o greeting-3c-host.wav "http://lxc:8001/api/jobs/$JOB/audio?format=studio"
```

## Data layout & backups

```
/opt/county-narrator/data/
├── voices/      reference clips + voices.json index
├── outputs/     generated audio (last 50 jobs) + metadata
└── hf-cache/    model weights (re-downloadable, excluded from backups)
```

`sudo update backup` writes `voices/` + `outputs/` to `/var/backups/county-narrator/`.

## Security notes

- The app has **no authentication** — run it on a trusted internal network / VLAN, optionally behind your reverse proxy with auth.
- Generated audio is watermarked (Perth) as AI-generated; this survives MP3 compression and editing.

## License

MIT — see [LICENSE](LICENSE). Chatterbox Turbo is MIT-licensed by Resemble AI.
