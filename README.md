# mic-lock

**Lock microphone once. Reconnects automatically.**

mic-lock locks your audio input on MacOS to a specific device and intelligently handles ordered fallback when that device is not connected. If that device goes silent (audio fails), mic-lock automatically switches to the next mic in your priority chain. When your primary comes back, it switches back.

---

**Set multiple devices** — mic-lock tries them in order, automatically falling back if the primary goes silent.

```bash
$ miclock set "USB Condenser" "Wireless Headset" "Laptop Mic"
```

**How the fallback works:**
1. Samples every 10 seconds for 2 seconds (configurable)
2. Calculates RMS (root mean square) of the audio
3. If RMS below threshold (default: 0.00001) for 5+ seconds total, triggers fallback
4. Tries next device in the priority list
5. Every 30 seconds while in fallback, checks if the primary device has signal again
6. When primary recovers, automatically switches back

---

## What It Does

Quick reference:

```bash
$ miclock list              # List connected devices
$ miclock set               # Interactive picker (no args)
$ miclock set "Device"      # Lock to single device
$ miclock set "A" "B" "C"   # Priority chain with fallback
$ miclock watch             # Watch in foreground (Ctrl+C to daemonize)
$ miclock stop              # Stop the daemon
```

---

## Getting Started

### Prerequisites

- macOS 12.0+
- Swift 5.9+ (to build from source)

### Build & Install

```bash
git clone https://github.com/f/mic-lock.git
cd mic-lock
swift build -c release

# Install to PATH
ln -s $(pwd)/.build/release/miclock /usr/local/bin/miclock
```

---

## Commands

### Core

```bash
miclock list               # Show input devices
miclock                    # Check status
```

### Set Devices

```bash
miclock set                     # Interactive picker (TUI)
miclock set "Device Name"       # Lock mode: single device
miclock set "A" "B" "C"         # Priority mode: fallback chain
```

**Interactive picker** — Run `miclock set` with no arguments to open the TUI:
- **Arrow keys**: navigate devices
- **Space**: add/remove from priority chain
- **Enter**: confirm and start daemon
- **q**: cancel


### Monitor & Control

```bash
miclock watch               # Foreground mode (see real-time status) [Press Ctrl+C once to see a prompt: "Keep running in background? [y/N]"]
miclock stop                # Stop the daemon
miclock diag "Device"       # Inspect device & sample audio (5s)
miclock alias               # Manage device aliases
```

**Configuration** — Fine-tune silence detection:

```bash
$ miclock config                          # View all settings
$ miclock config timeout 10.0             # Change a value
```

| Key         | Default | Purpose                            |
| ----------- | ------- | ---------------------------------- |
| `timeout`   | 5.0s    | Seconds of silence before fallback |
| `threshold` | 0.00001 | RMS level below this = silent      |
| `detection` | on      | Enable/disable silence detection   |
| `interval`  | 10.0s   | Seconds between sample windows     |
| `duration`  | 2.0s    | Seconds per sample window          |

---

## Configuration Files

Stored in `~/.config/mic-lock/`:

| File            | Purpose                    |
| --------------- | -------------------------- |
| `priority.json` | Current priority list      |
| `settings.json` | Silence detection settings |
| `aliases.json`  | Device aliases             |
| `daemon.pid`    | Running daemon process ID  |
| `current.lock`  | Current lock target        |


---

## Project Structure

```
Sources/
├── main.swift           # CLI entry point and command routing
├── Commands.swift       # Command implementations
├── MicLock.swift        # Core state machine and logic
├── AudioDevice.swift    # CoreAudio device enumeration/control
├── AudioMonitor.swift   # RMS sampling
├── Config.swift         # Settings, aliases, priority list persistence
├── Output.swift         # Terminal formatting
├── Terminal.swift       # Raw terminal mode for interactive picker
```

---

## Shell Completions

Completions available for zsh, bash, and fish.

### Zsh

```bash
mkdir -p ~/.zsh/completions
miclock completion zsh > ~/.zsh/completions/_miclock
```

Add to `.zshrc`:
```bash
fpath=(~/.zsh/completions $fpath)
autoload -U compinit && compinit
```

### Bash

```bash
mkdir -p ~/.bash_completion.d
miclock completion bash > ~/.bash_completion.d/miclock
```

Add to `.bashrc`:
```bash
for completion in ~/.bash_completion.d/*; do
    source "$completion"
done
```

Or source directly:
```bash
source <(miclock completion bash)
```

### Fish

```bash
mkdir -p ~/.config/fish/completions
miclock completion fish > ~/.config/fish/completions/miclock.fish
```

---

## Tech Stack

| Layer    | Choice       | Notes                         |
| -------- | ------------ | ----------------------------- |
| Language | Swift        | Type-safe, native macOS       |
| Audio    | CoreAudio    | System-level audio management |
| Storage  | File (JSON)  | Simple, portable config       |
| CLI      | Native Swift | No external deps              |
| Colors   | Rainbow      | Terminal styling              |

---

## Contributing

Personal project. Issues and discussions welcome.

## License

MIT
