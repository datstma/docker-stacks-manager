<h1 align="center">🐳 Docker Stack Manager</h1>

<p align="center">
  <strong>See and control every Docker Compose stack on a host from one terminal UI.</strong><br>
  A single Bash script. No daemon, no web server, no database.
</p>

<p align="center">
  <a href="https://github.com/datstma/docker-stacks-manager/actions/workflows/ci.yml"><img src="https://github.com/datstma/docker-stacks-manager/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/datstma/docker-stacks-manager/releases/latest"><img src="https://img.shields.io/github/v/release/datstma/docker-stacks-manager?sort=semver" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/bash-4.0+-4EAA25?logo=gnubash&logoColor=white" alt="Bash 4.0+">
  <img src="https://img.shields.io/badge/docker-compose%20v2-2496ED?logo=docker&logoColor=white" alt="Docker Compose v2">
  <img src="https://img.shields.io/badge/platform-linux%20%7C%20macOS%20%7C%20windows-lightgrey" alt="Linux | macOS | Windows">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue" alt="MIT License"></a>
</p>

<p align="center">
  <a href="#-install">Install</a> •
  <a href="#-usage">Usage</a> •
  <a href="#-interactive-mode">Interactive mode</a> •
  <a href="#-updating">Updating</a> •
  <a href="#-faq--troubleshooting">FAQ</a> •
  <a href="#-contributing">Contributing</a>
</p>

<p align="center">
  <img src="docs/images/demo.gif" alt="Docker Stack Manager: status overview, then the interactive TUI drilling into a stack and filtering" width="880">
</p>

If your homelab or server is a directory full of `docker-compose.yaml` files, this is the tool for
the moment you SSH in and want to know *what's running, what isn't, and why*, then restart or
tail the thing that broke, without opening a browser. Think [Dockge](https://github.com/louislam/dockge)
or Portainer's stack view, but in your terminal, with vim keys.

## ✨ Features

- **Every stack at a glance**: running, partly running, unhealthy or stopped, with uptime, health
  and restart counts. Crash-looping containers stand out (`↻3`)
- **Knows the difference** between a crashed service and a one-shot job (a migration, a backup)
  that finished cleanly: the job shows as `✓ done`, not as a problem
- **Interactive TUI**: `j`/`k` or arrows, `Enter` to drill into a stack, `/` to filter. Live logs,
  restart, stop, up, down, a shell in a container, `top`, stats. Anything destructive asks first
- **Live and flicker-free**: refreshes itself every few seconds while you watch, on the terminal's
  alternate screen, so your scrollback is untouched when you quit
- **Fast**: three `docker` calls in total, however many stacks you have. 20+ stacks load in about
  half a second
- **Network view**: networks, subnets and IPs, and which containers share another container's
  network (an app routed through a VPN container, a sidecar)
- **Watchtower aware**: when Watchtower last ran, what it updated or couldn't check, when it
  runs next, and which containers have opted in to auto-updates (`[auto]`)
- **Runs anywhere Bash does**: Linux, macOS, Windows (WSL2 or Git Bash). Needs bash 4+, Docker
  and the Compose v2 plugin, nothing else

## 📸 Screenshots

<table>
<tr>
<td width="50%"><img src="docs/images/status.png" alt="Status overview: four stacks, one partly running, one stopped, with Watchtower's next check"></td>
<td width="50%"><img src="docs/images/network.png" alt="Network view: networks with subnets, container IPs, and a sidecar routed via another container"></td>
</tr>
<tr>
<td align="center"><b>Status overview</b> (<code>dsm</code>)</td>
<td align="center"><b>Network view</b> (<code>dsm -n</code>)</td>
</tr>
<tr>
<td width="50%"><img src="docs/images/tui.png" alt="Interactive TUI: the stack list with status badges"></td>
<td width="50%"><img src="docs/images/containers.png" alt="Interactive TUI: the containers of one stack, with details for the selected one"></td>
</tr>
<tr>
<td align="center"><b>Interactive TUI</b> (<code>dsm -I</code>)</td>
<td align="center"><b>Inside a stack</b> (<code>Enter</code>)</td>
</tr>
</table>

All screenshots are real output from the bundled [demo stacks](#-try-it-on-the-demo-stacks),
recorded with [`demo/screenshots/screenshots.sh`](demo/screenshots/screenshots.sh).

## 🚀 Install

**One line** (Linux, macOS, WSL2, Git Bash):

```bash
curl -fsSL https://raw.githubusercontent.com/datstma/docker-stacks-manager/main/install.sh | bash
```

This installs the latest release as `docker-stacks-manager` in `~/.local/bin` (or `/usr/local/bin`
when run as root) with a short `dsm` alias next to it, and tells you if that directory isn't on
your `PATH` yet. Prefer to read it before running it? It's [short](install.sh):

```bash
curl -fsSLO https://raw.githubusercontent.com/datstma/docker-stacks-manager/main/install.sh
less install.sh
bash install.sh
```

<details>
<summary><strong>Installer options</strong></summary>

| Option | Environment | Meaning |
|---|---|---|
| `--prefix DIR` | `DSM_PREFIX` | Install into `DIR/bin`. Default `~/.local`, or `/usr/local` as root |
| `--ref REF` | `DSM_REF` | Install a specific release tag or branch, e.g. `v1.0.0` or `main` |
| `--uninstall` | | Remove an installed copy (use the same `--prefix`) |

Pass options through the pipe with `bash -s --`:

```bash
curl -fsSL https://raw.githubusercontent.com/datstma/docker-stacks-manager/main/install.sh | sudo bash -s -- --prefix /usr/local
```
</details>

<details>
<summary><strong>From a git clone</strong> (to hack on it, or to update with <code>git pull</code>)</summary>

```bash
git clone https://github.com/datstma/docker-stacks-manager.git
cd docker-stacks-manager
./install.sh             # installs this clone's script; or just run ./docker-stacks-manager.sh
make install             # the same, for those who prefer make (PREFIX=/usr/local to change)
```
</details>

<details>
<summary><strong>Manually</strong> (it's one file)</summary>

```bash
curl -fsSL -o ~/.local/bin/dsm \
  https://raw.githubusercontent.com/datstma/docker-stacks-manager/main/docker-stacks-manager.sh
chmod +x ~/.local/bin/dsm
```
</details>

### Requirements

| | |
|---|---|
| **Bash** | 4.0 or newer. macOS ships 3.2: `brew install bash` |
| **Docker** | With the Compose v2 plugin (`docker compose`). The old standalone `docker-compose` v1 is not supported |
| **Tools** | `awk`, `sed`, `grep`, `find`, `sort` and friends, present on any normal system. `bc` is optional |
| **Install/update** | `curl` or `wget` |

## 📖 Usage

Run it from the directory that holds your stacks, or point it there with `-d`:

```bash
cd ~/docker-stacks && dsm -I     # interactive TUI
dsm -d ~/docker-stacks           # status overview of a given directory
export DSM_DIR=~/docker-stacks   # ...or set it once in your shell profile
```

A **stack** is any directory containing `compose.yaml`, `compose.yml`, `docker-compose.yaml` or
`docker-compose.yml`: the base directory itself and its direct subdirectories. If a directory has
more than one, the file `docker compose` itself would pick wins.

```
~/docker-stacks/          ← run dsm here
├── media/
│   └── compose.yaml
├── monitoring/
│   └── docker-compose.yml
└── proxy/
    └── docker-compose.yaml
```

```
Views:
  -I, --interactive  Interactive TUI (recommended)
  -v, --verbose      Status with CPU/memory, ports and images
  -s, --stats        Status with CPU/memory
  -p, --ports        Status with port mappings
  -i, --images       Status with image versions
  -w, --watch        Redraw the status every 5 seconds
  -n, --network      Networks and the containers on them

Options:
  -d, --dir DIR      Directory holding your stacks (default: current directory)
  -U, --update       Update this script to the latest release
  -V, --version      Print the version
  -h, --help         Show this help

Environment:
  DSM_DIR            Default for --dir
  DSM_REFRESH        TUI refresh interval in seconds (default 5)
```

With `-v`, each container also gets its CPU/memory, ports and image:

```
✓ web-app (3 containers)
  ├─ frontend ● 12m [auto]
  │  CPU: 0.00%  MEM: 488KiB
  │  Ports: 8080/tcp -> 18080
  │  Image: busybox:1.36
  ├─ migrate ✓ done (Exited (0) 12 minutes ago)
  │  Image: busybox:1.36
  └─ worker ● 12m
     CPU: 0.00%  MEM: 488KiB
     Image: busybox:1.36
```

## 🎮 Interactive mode

`dsm -I` opens the TUI. It refreshes itself every 5 seconds while idle (`DSM_REFRESH` to change).

| Key | Stack list | Inside a stack |
|---|---|---|
| `↑` `↓` / `j` `k` | Move | Move |
| `Enter` | Open the stack's containers | Action menu for the container |
| `/` | Filter stacks by name, `Enter` to apply (`Esc` clears) | |
| `L` | Live logs of the whole stack | Container logs |
| `R` | Restart the stack ✋ | Restart the container ✋ |
| `S` | Stop the stack ✋ | Stop the container ✋ |
| `U` | Start it (`docker compose up -d`) | |
| `D` | Down: remove its containers ✋ | |
| `T` | Live traffic per container | `top` inside the container |
| `N` | Network view | Network and ports |
| `F` | | Live stats (CPU, memory, network) |
| `q` | Quit | Back |
| `Ctrl+C` | Quit | Leave a live view (logs, stats) and return to the menu |

✋ asks for confirmation first: only `y` goes ahead.

The container action menu (`Enter` on a container) adds both log modes (live and last 100 lines),
start, a shell (`bash` or `sh`), `top` and live stats.

**Status symbols**

| | |
|---|---|
| `●` green | Running (and healthy, if it has a healthcheck) |
| `●` yellow | Healthcheck still starting |
| `●` red | Unhealthy or stopped |
| `◐` | Stack partly running: something that should run doesn't |
| `○` | Stack stopped |
| `✓ done` | One-shot job that exited with code 0 and isn't meant to restart |
| `↻N` | Restarted N times: probably crash-looping |
| `[auto]` | Opted in to Watchtower auto-updates |

## 🔄 Updating

```bash
dsm --update
```

downloads the latest release and replaces the installed script in place, after checking that the
download is a valid script. If you run it from a git clone of this repository, it does a
`git pull --ff-only` instead. Running the installer again also updates. To get a specific
version, use `DSM_UPDATE_REF=v1.0.0 dsm --update` or the installer's `--ref`.

If the script lives somewhere only root can write (`/usr/local/bin`), use `sudo dsm --update`.

To uninstall:

```bash
curl -fsSL https://raw.githubusercontent.com/datstma/docker-stacks-manager/main/install.sh | bash -s -- --uninstall
```

## 🧪 Try it on the demo stacks

`demo/` has three throwaway stacks (busybox only, ports 18080 and 18081) that between them show
every state: running, partly running, stopped, a finished one-shot job and a sidecar sharing
another container's network.

```bash
git clone https://github.com/datstma/docker-stacks-manager.git && cd docker-stacks-manager
./demo/demo.sh up       # start the demo stacks (backup is created but left stopped)
./demo/demo.sh run -I   # run dsm on them, with any options
./demo/demo.sh down     # remove them again
```

## 🖥️ Platforms

| Platform | Notes |
|---|---|
| **Linux** | Any distro with bash 4+ (Alpine: `apk add bash`). Used daily on Debian |
| **macOS** | Docker Desktop, OrbStack or Colima, plus `brew install bash`. Run it as `dsm` or `./docker-stacks-manager.sh`, not `bash docker-stacks-manager.sh`, so it picks up Homebrew's bash rather than `/bin/bash` 3.2 |
| **Windows, WSL2** | Recommended. With Docker Desktop's WSL integration it behaves exactly like Linux |
| **Windows, Git Bash** | Best effort, with Docker Desktop. Container shells use `winpty` automatically in mintty |

CI runs the test suite on Linux, macOS and Windows (Git Bash) on every push.

## ❓ FAQ & troubleshooting

<details>
<summary><strong>"No stacks found"</strong></summary>

dsm looks in the current directory (or `-d DIR` / `$DSM_DIR`) and its direct subdirectories for
`compose.yaml`, `compose.yml`, `docker-compose.yaml` or `docker-compose.yml`. Stacks nested deeper
than one level aren't picked up.
</details>

<details>
<summary><strong>A stack I started from elsewhere doesn't show its containers</strong></summary>

Containers are matched to stacks by the working directory Compose records on them, then by
project name. If you started a stack with `-p someothername` from another directory, neither
matches. Start it from its own directory with `docker compose up -d`.
</details>

<details>
<summary><strong>"This script requires bash 4.0 or higher" (macOS)</strong></summary>

macOS ships bash 3.2. `brew install bash`, then run `dsm` directly (not `bash dsm`), so the
`#!/usr/bin/env bash` line finds the new one on your `PATH`.
</details>

<details>
<summary><strong>Windows: <code>$'\r': command not found</code></strong></summary>

The script was saved with Windows line endings. The repository's `.gitattributes` prevents this
for fresh clones and the installer downloads it as-is; to fix an existing copy:
`sed -i 's/\r$//' docker-stacks-manager.sh`.
</details>

<details>
<summary><strong>"Missing required commands: docker compose (v2 plugin)"</strong></summary>

You have Docker but not the Compose plugin, or only the legacy `docker-compose` v1. Install the
plugin: on Debian/Ubuntu `sudo apt install docker-compose-plugin`; Docker Desktop includes it.
</details>

<details>
<summary><strong>Permission denied talking to Docker</strong></summary>

Add yourself to the `docker` group, then log out and back in:
`sudo usermod -aG docker $USER`.
</details>

<details>
<summary><strong>Traffic view shows "--"</strong></summary>

Normal for the first few seconds: a rate needs two samples.
</details>

<details>
<summary><strong>Does it send anything anywhere?</strong></summary>

No. It only talks to your local Docker. The one exception is `--update`, which asks GitHub for
the latest release when you run it.
</details>

## 🤝 Contributing

Issues and pull requests are welcome. The whole tool is [one Bash script](docker-stacks-manager.sh),
and it has to keep working with both GNU and BSD tools (Linux and macOS), so:

```bash
./tests/run.sh          # the test suite: no Docker needed, it replays recorded docker output
make lint               # shellcheck (errors only), if you have shellcheck installed
./tests/record.sh       # re-record the fixtures when you change which docker commands are called
```

- Avoid GNU-only flags: no `sed -r`, `grep "a\|b"` (use `grep -E`), `sort -h`, `readlink -f`, or
  `date -d` without a BSD fallback
- New views read the snapshot (`load_snapshot`) rather than calling `docker` per stack or per
  container: that's what keeps it fast
- On macOS or Windows? Running `./tests/run.sh` and reporting the result is a real help

See [CHANGELOG.md](CHANGELOG.md) for what changed between releases.

## 📜 License

[MIT](LICENSE). Inspired by [Dockge](https://github.com/louislam/dockge); built for people who'd
rather stay in the terminal.

<p align="center"><sub>If it saves you a trip to a web UI, consider giving it a ⭐</sub></p>
