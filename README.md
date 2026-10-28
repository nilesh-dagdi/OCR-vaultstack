# IndicOCR — PDF to text UI

Local, dependency-free web page that turns a PDF into Markdown using the `indic-ocr` service
running on the GPU host.

- PDF pages are rendered in **your browser** (pdf.js) to PNG.
- Each page is POSTed to the OCR API and the returned Markdown is shown next to the page image.
- No build step, no Node, no extra server process — just a static folder and the existing API.

## What is in this folder

| file | purpose |
| --- | --- |
| `index.html` | the whole UI (HTML + CSS + JS, no build) |
| `vendor/pdf.min.mjs`, `vendor/pdf.worker.min.mjs` | pdf.js 4.10.38, vendored so the page works offline |
| `start.ps1` | opens the SSH tunnel, starts the static server, opens the browser, prints OCR status |
| `stop.ps1` | kills the tunnel and the static server |
| `.run/ssh.pid`, `.run/web.pid` | PIDs written by `start.ps1` (safe to delete) |

## One-time start

```powershell
cd D:\ocrmodel
.\start.ps1
```

That opens:

1. an SSH tunnel `127.0.0.1:8094 -> 100.105.243.101:8094` (needed because the tailnet ACL for
   your peer only permits port 22),
2. a static file server on <http://localhost:5500> (pdf.js uses a module worker, which browsers
   refuse to load from `file://`),
3. your browser at <http://localhost:5500>.

Stop both with:

```powershell
.\stop.ps1
```

## Use

1. **Choose PDF** or drop a file on the page.
2. **Extract text** — pages run in order, ~17 s each, results appear as they finish.
3. **Cancel** stops after the current page.
4. Copy all, or download `.md` / `.json` (JSON includes per-block `bbox_xyxy`, `label`, `type`, `conf`).

The API field defaults to `http://127.0.0.1:8094` and is remembered. The dot beside it is re-tested
every 15 s (and when you edit the URL); hover it for the reason — green `ready`, amber
`engine warming up` (cold start after a restart takes ~2 min), red `unreachable: …`.

## Where everything lives on the server

Host: `nilesh@vaultstackai` (`100.105.243.101`). No sudo was needed; the service is a **systemd user unit**.

| what | path |
| --- | --- |
| **model weights** (layout 133 MB + OCR 1.73 GB) | `/srv/ai/models/indic-ocr/weights/{layout,ocr}` |
| model files from the Hub, sample pages | `/srv/ai/models/indic-ocr/` (`assets/` = test pages) |
| detailed deployment notes (download, versions, pitfalls) | `/srv/ai/models/indic-ocr/README.local.md` |
| Hugging Face token (mode 600) | `/srv/ai/models/.hf-token` |
| **Python venv** (~13 GB: torch, vllm, flashinfer) | `/srv/ai/run_scripts/venvs/indic-ocr` (Python 3.12.3) |
| upstream source repo (constraints, install.sh) | `/srv/ai/run_scripts/bodhan_genai-src` |
| FastAPI app that serves the model | `/srv/ai/run_scripts/server_indic_ocr_8094.py` (backup: `.bak`) |
| start/stop/status helper for the API | `/srv/ai/run_scripts/run_indic_ocr_8094.sh` |
| systemd unit (enabled at boot, linger on) | `~/.config/systemd/user/indic-ocr-api.service` |
| service log | `/srv/ai/model_logs/indic-ocr-8094.log` |
| flashinfer kernel cache (makes restarts faster) | `/srv/ai/models/flashinfer-cache` |
| env vars for interactive shells | `~/.bashrc` (`INDIC_OCR_*`, `BODHAN_GENAI_DEPLOYMENT=1`) |

The weights are a **plain local folder**, not the Hugging Face cache — nothing is downloaded at runtime
(`HF_HUB_OFFLINE=1` is set in the unit).

## Commands

### On your Windows machine (this UI)

```powershell
cd D:\ocrmodel
.\start.ps1                       # tunnel + static server + browser
.\stop.ps1                        # stop both

# health through the tunnel
curl.exe -s http://127.0.0.1:8094/health

# OCR a single image (same call the UI makes, one page)
curl.exe -F "file=@C:\scans\page.png" http://127.0.0.1:8094/ocr -o page.json
```

### On the server (SSH)

```bash
ssh nilesh@vaultstackai

# service
systemctl --user status  indic-ocr-api
systemctl --user restart indic-ocr-api          # ~2 min cold start
systemctl --user stop    indic-ocr-api
/srv/ai/run_scripts/run_indic_ocr_8094.sh status   # same, plus a live /health call

# logs / GPU
tail -f /srv/ai/model_logs/indic-ocr-8094.log
nvidia-smi

# direct OCR from the CLI on the server (no service needed)
V=/srv/ai/run_scripts/venvs/indic-ocr
$V/bin/python -m bodhan_genai.ocr.inference.cli parse page.png -o out \
  --layout-ckpt /srv/ai/models/indic-ocr/weights/layout \
  --ocr-ckpt    /srv/ai/models/indic-ocr/weights/ocr \
  --gpu-memory-utilization 0.35 --save-layout

# smoke test on the bundled sample page
$V/bin/python -m bodhan_genai.ocr.inference.cli parse \
  /srv/ai/models/indic-ocr/assets/gallery-1-english-math-ramanujan.png -o /tmp/t \
  --layout-ckpt /srv/ai/models/indic-ocr/weights/layout \
  --ocr-ckpt    /srv/ai/models/indic-ocr/weights/ocr --gpu-memory-utilization 0.35

# prove it is offline
HF_HUB_OFFLINE=1 TRANSFORMERS_OFFLINE=1 $V/bin/python -m bodhan_genai.ocr.inference.cli --help
```

### Re-download / update the weights

```bash
ssh nilesh@vaultstackai
export HF_TOKEN=$(cat /srv/ai/models/.hf-token)
/srv/ai/run_scripts/venvs/indic-ocr/bin/hf download bodhan-ai/indic-ocr \
  --local-dir /srv/ai/models/indic-ocr
chmod -R a+rX /srv/ai/models/indic-ocr
```

Afterwards: `systemctl --user restart indic-ocr-api` and check `/health` is `ready`.

### Rebuild the venv from scratch (only if it breaks)

```bash
python3.12 -m venv /srv/ai/run_scripts/venvs/indic-ocr
cd /srv/ai/run_scripts/bodhan_genai-src
PATH=/srv/ai/run_scripts/venvs/indic-ocr/bin:$PATH ./install.sh --extras ocr-infer --no-venv --no-flash-attn
/srv/ai/run_scripts/venvs/indic-ocr/bin/pip install transformers==5.15.0 tokenizers==0.22.2 httpx
systemctl --user restart indic-ocr-api
```

**Do not** reinstall `transformers==5.13.1` from `constraints.txt` (unimportable with hub 1.x) and do not use
`tokenizers 0.23.x` (it drops spaces in the `qwen3_5` tokenizer — output comes out as `helloworld` with `▁`
markers). Installed and working: `transformers 5.15.0`, `tokenizers 0.22.2`, `huggingface-hub 1.33.0`,
`httpx 0.28.1`, `vllm 0.26.0+cu129`, `torch 2.11.0+cu129`, `pydantic 2.14.1 / pydantic-core 2.50.1`.

## Troubleshooting

| symptom | cause |
| --- | --- |
| red dot, `unreachable` | tunnel not running → `.\start.ps1` |
| amber dot, `warming` | engine still loading (~2 min); it turns green by itself |
| `HTTP 503 — model is still loading` | same, wait and retry |
| `HTTP 422` | page image was empty (corrupt PDF page) |
| page renders but OCR text is empty | blank page, or the model found no text |
| `Cannot open PDF` | password-protected / DRM PDF |

## Notes

- Nothing is written to disk except your downloads; page images are kept in the tab only.
- Rendering is capped at 200 DPI / 4200 px longest edge, which is what the service expects.
- The service serialises requests, so parallel tabs will just queue.
- `vendor/` holds pdf.js 4.10.38 (Apache-2.0) so the page works offline.



<!-- so ssh -N -o BatchMode=yes -o ServerAliveInterval=30 -L 8094:100.105.243.101:8094 nilesh@vaultstackai 
and
 python -m http.server 5500 --bind 127.0.0.1  are required to start? --># OCR-vaultstack
