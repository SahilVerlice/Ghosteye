# ghosteye.sh

**A recon → exploit pipeline in one script — subdomains, live hosts, endpoints, fuzzing, vuln scan, screenshots, and ranked candidates.**

`ghosteye.sh` chains the standard recon toolchain (subfinder, httpx, gau, katana,
ffuf, nuclei, gowitness …) into a single ordered run with organized output —
instead of a folder full of scattered one-liners. It is the smaller, focused
sibling of [bbhunt](../bbhunt/): where bbhunt runs 40 standalone stages you
compose by hand, ghosteye runs one opinionated end-to-end pass.

![Bash](https://img.shields.io/badge/bash-5.x-4EAA25?logo=gnubash&logoColor=white)
![Platform](https://img.shields.io/badge/platform-linux-informational)
![License](https://img.shields.io/badge/license-MIT-blue)

> ⚠️ **Authorized targets only.** You are responsible for scope compliance.
> Run this only against systems you own or have explicit written permission to test.

---

## Features

- **10 stages** (11 with `--deep`) — subdomains → live → endpoints → fuzz →
  vuln scan → screenshots → ranked candidates, in order
- **One command** — `./ghosteye.sh target.com` runs the whole pipeline
- **`--deep` mode** — bigger wordlist, recursive fuzzing, and a port scan
- **Ranked output** — high-signal paths (api/auth/admin/token/…) pulled out of
  the URL corpus, plus IDOR-candidate and JS-file lists
- **Screenshots** — gowitness pass over every live host
- **Clean aesthetics** — 256-colour, banner, aligned summary table; colour is
  tty-gated and opt-out, so piped output stays grep/jq-safe
- **Graceful degradation** — a missing optional tool warns and skips, it never
  crashes the run

---

## Install

### 1. Dependencies

Required (preflight aborts if any are absent):

```bash
# ProjectDiscovery
go install github.com/projectdiscovery/subfinder/v2/cmd/subfinder@latest
go install github.com/projectdiscovery/httpx/cmd/httpx@latest
go install github.com/projectdiscovery/katana/cmd/katana@latest
go install github.com/projectdiscovery/nuclei/v3/cmd/nuclei@latest

# others
go install github.com/lc/gau/v2/cmd/gau@latest
go install github.com/ffuf/ffuf/v2@latest
```

Optional (their stages skip cleanly when absent):

```bash
go install github.com/tomnomnom/assetfinder@latest     # thinner subdomain pass without it
go install github.com/hakluke/hakrawler@latest         # thinner crawl without it
go install github.com/projectdiscovery/naabu/v2/cmd/naabu@latest   # --deep port scan
go install github.com/sensepost/gowitness@latest       # screenshots
```

Wordlists come from [seclists](https://github.com/danielmiessler/SecLists) —
install to `/usr/share/seclists` or edit `WL_DIR` at the top of the script.
`common.txt` is used by default; `--deep` switches to
`raft-medium-directories.txt`.

> **Chromium** is needed for screenshots. `ghosteye.sh` auto-detects
> `chromium`, `chromium-browser`, or `google-chrome`; override with
> `GHOSTEYE_CHROME=/path/to/chrome`.

### 2. The script

```bash
chmod +x ghosteye.sh
./ghosteye.sh target.com
```

---

## Usage

```
./ghosteye.sh <target> [--deep]
```

```bash
# standard pass
./ghosteye.sh example.com

# deep: bigger wordlist, recursive fuzzing, port scan
./ghosteye.sh example.com --deep

# piped output stays clean (no ANSI)
NO_COLOR=1 ./ghosteye.sh example.com | tee run.log
```

`target` may be a bare domain or a URL — the scheme and path are stripped.

### Stages

| # | Stage | What it does |
|---|-------|--------------|
| — | `preflight` | verify required tooling + wordlist; warn on optional gaps |
| 1 | subdomain discovery | `subfinder` + `assetfinder`, deduped, apex included |
| 2 | live host probing | `httpx` — bare list for piping, full list with status/title/tech |
| 3 | endpoint discovery | `gau` (archives) + `katana` + `hakrawler` |
| 3b | port scan | `naabu` connect scan over the curated port list — **`--deep` only** |
| 4 | ranking interesting endpoints | high-signal paths: api/auth/admin/user/token/oauth/debug/… |
| 5 | content fuzzing | `ffuf` per live host (`-recursion` in `--deep`) |
| 6 | vulnerability scan | `nuclei` — exposures, misconfiguration, default-logins, takeovers, cves, vulnerabilities |
| 7 | screenshots | `gowitness` over every live host |
| 8 | javascript analysis | harvest `.js` files from the URL corpus |
| 9 | idor candidates | parameterized URLs carrying id-like params |

---

## Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `GHOSTEYE_THREADS` | `50` | concurrency (httpx, ffuf) |
| `GHOSTEYE_RATE` | `150` | req/sec for ffuf |
| `GHOSTEYE_TIMEOUT` | `10` | per-request timeout (secs) |
| `GHOSTEYE_CHROME` | auto-detected | Chrome/Chromium binary for gowitness |
| `NO_COLOR` | — | disable all colour (set to any value) |

---

## Output

Everything lands under `ghostyjoe_<target>/` in the current directory:

```
ghostyjoe_example.com/
├── subs.txt              # unique hosts (subfinder + assetfinder + apex)
├── live.txt              # live hosts, bare URLs (for piping)
├── live_full.txt         # live hosts with status / title / tech
├── urls.txt              # harvested endpoints
├── hosts.txt             # bare hostnames (--deep, for naabu)
├── ports.txt             # open ports (--deep)
├── interesting.txt       # high-signal paths
├── ffuf_<host>.json      # per-host ffuf results
├── ffuf.json             # merged ffuf results
├── nuclei.txt            # vulnerability findings
├── screenshots/          # gowitness .jpeg shots
├── gowitness.jsonl       # screenshot metadata
├── js.txt                # JavaScript file URLs
└── idor_candidates.txt   # parameterized id-like URLs
```

The run ends with an aligned summary table: one row per artifact with its count,
plus elapsed time.

---

## Design notes

- **`run` wrapper.** Every external tool is launched through `run`, which logs a
  label and swallows the tool's own noise while keeping the pipeline alive on
  failure — a single failing stage never aborts the run.
- **Colour is tty-gated.** ANSI escapes are only emitted when stdout is a tty
  and `NO_COLOR` is unset. Piping or redirecting to a file keeps it clean, which
  matters because escapes break downstream `grep`/`jq`.
- **`row` count guard.** `grep -c .` prints `0` *and* exits non-zero on an empty
  file; a naive `|| echo 0` appends a second `0` and the summary row wraps onto
  two lines. `row` uses `|| true` plus an emptiness check instead.
- **Tool-specific invocations** are pinned to what actually works here:
  - `gau` reads a **domain argument**, not stdin.
  - `ffuf` has **no `-l` flag** and no multi-host mode — the script loops over
    live hosts and counts hits from `.results[]` (its JSON has no `url` key).
  - `nuclei -t` needs **real template paths** (`http/misconfiguration`, not
    `misconfig`); one bad entry aborts the entire scan.
  - `naabu` uses `-s connect` with an **explicit port list** — the default SYN
    scan and `-top-ports` silently return nothing on a restricted VM.
  - `gowitness` uses `--driver gorod` (the default chromedp driver times out
    here) and writes `.jpeg`, not `.png`.

---

## Legal

This tool is for **authorized security testing and educational use only**.
Using it against systems without explicit permission is illegal in most
jurisdictions. The author assumes no liability for misuse or for any damage
caused. Always confirm the target is in scope before running.

---

## License

Released under the MIT License. Add a `LICENSE` file to the repository if you
plan to publish it publicly.

---

## Related

- **[bbhunt](../bbhunt/)** — the larger companion pipeline: 40 standalone,
  resumable stages, run individually or via `all` / `deep`.
