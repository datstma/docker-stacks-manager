# Changelog

All notable changes to this project are documented here. Versions follow
[Semantic Versioning](https://semver.org/).

## [1.2.0] - 2026-11-09

### Added
- Import: turn a container started with `docker run`, or a `docker run`
  command, into a compose stack (`--import NAME`, `--convert CMD...`,
  `--print`; `-Import`, `-Convert`, `-Print` in PowerShell; `I` in the TUI).
  The compose file keeps what was set and leaves out the image's defaults;
  existing volumes and networks are used as `external`, anonymous volumes are
  kept by ID, and anything without a compose equivalent is noted in the file.
  A guided flow writes it to a new stack folder and can switch the container
  over: the old one is stopped and kept as `<name>-pre-compose`, and put back
  if the stack fails to start
- The shell script runs under zsh as well as bash 4+. On macOS, whose bash is
  3.2, it hands itself over to the built-in zsh, so nothing needs installing.
  CI runs the tests under both shells

### Fixed
- PowerShell: the restart/stop confirmation for a service left out its name
- The Bash TUI no longer loops when its input ends

## [1.1.0] - 2026-11-09

### Added
- Native PowerShell edition for Windows, `docker-stacks-manager.ps1`: the
  same status, detailed, watch and network views and the same interactive
  TUI as the Bash script, for Docker Desktop on Windows PowerShell 5.1 or
  PowerShell 7. Bash-style short options (`-I`, `-v`, `-n`, ...) work too
- In the PowerShell TUI, `q`, `Esc` or `Ctrl+C` leave a live view (logs,
  stats, traffic), and the `/` filter narrows the list as you type
- `install.ps1`: one-line Windows installer (`irm ... | iex`) that sets up a
  `dsm` command on your PATH; `dsm -Update` updates it
- `demo/demo.ps1` and a Pester test suite that replays recorded docker output
- CI runs the PowerShell tests on Windows under both PowerShell 5.1 and 7

### Removed
- Git Bash support for the Bash script: on Windows, use the PowerShell
  edition, or the Bash script inside WSL2

## [1.0.0] - 2026-11-09

First public release.

- Status overview of every Compose stack below a directory: running, partly
  running, unhealthy or stopped, with uptime, health, restart counts and
  finished one-shot jobs shown as done
- Interactive TUI (`-I`): vim-style navigation, filter, live refresh without
  flicker, stack and container actions (logs, restart, stop, up, down, shell,
  top, stats) with confirmation for anything destructive
- Network view (`-n`), including containers that share another container's
  network
- Watchtower integration: last session, next check, opted-in containers
- One snapshot of three `docker` calls feeds every view, so 20+ stacks load
  in about half a second
- `-d/--dir` and `DSM_DIR` to choose the stacks directory
- `--update` self-update and `--version`
- `install.sh` one-line installer, updater and uninstaller
- Runs on Linux, macOS (bash 4+ from Homebrew) and Windows (WSL2, Git Bash);
  test suite runs without Docker

[1.2.0]: https://github.com/datstma/docker-stacks-manager/releases/tag/v1.2.0
[1.1.0]: https://github.com/datstma/docker-stacks-manager/releases/tag/v1.1.0
[1.0.0]: https://github.com/datstma/docker-stacks-manager/releases/tag/v1.0.0
