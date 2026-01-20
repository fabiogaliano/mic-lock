import Foundation
import Rainbow

// MARK: - Helpers

func buildAliasMap(_ devices: [AudioInputDevice], _ aliases: [String: String]) -> [String: String] {
    var map: [String: String] = [:]
    for (alias, deviceName) in aliases {
        for device in devices {
            if device.name.lowercased().contains(deviceName.lowercased()) {
                map[device.name] = alias
            }
        }
    }
    return map
}

// MARK: - List Devices (non-interactive)

func cmdListPlain() {
    let devices = getInputDevices()
    let currentID = getDefaultInputDeviceID()
    let deviceToAlias = buildAliasMap(devices, loadAliases())

    if devices.isEmpty {
        printWarning("No input devices found")
        return
    }

    print("Input devices".primary)
    print("")
    for (index, device) in devices.enumerated() {
        let isCurrent = device.id == currentID
        let marker = isCurrent ? Sym.current : " "
        let num = "\(index + 1).".dim

        let name: String
        if let alias = deviceToAlias[device.name] {
            name = formatDevice(device.name, alias: alias)
        } else {
            name = isCurrent ? device.name.accent : device.name
        }

        print("\(marker) \(num) \(name)")
    }
    print("")
    printSubtle("\(Sym.current) current")
}

// MARK: - Unified Device Picker

/// Interactive picker: Enter = single device, Space = add to priority chain
func cmdPick() {
    let devices = getInputDevices()
    let currentID = getDefaultInputDeviceID()
    let deviceToAlias = buildAliasMap(devices, loadAliases())

    if devices.isEmpty {
        printWarning("No input devices found")
        return
    }

    var selected = 0
    var priorityOrder: [Int] = []

    for (i, d) in devices.enumerated() {
        if d.id == currentID {
            selected = i
            break
        }
    }

    let originalTerm = enableRawMode()
    defer { disableRawMode(originalTerm) }

    print(Ansi.hideCursor, terminator: "")

    func render() {
        print(Ansi.clearScreen, terminator: "")

        // Header
        if priorityOrder.isEmpty {
            print("Select device".primary)
            print("Enter".dim + "=pick  " + "Space".dim + "=priority  " + "q".dim + "=cancel\n")
        } else {
            let chain = priorityOrder.map { i -> String in
                let device = devices[i]
                return deviceToAlias[device.name] ?? device.name
            }.joined(separator: " → ".dim)
            print("Priority: ".dim + chain + "\n")
        }

        for (i, device) in devices.enumerated() {
            let isCurrent = device.id == currentID
            let isSelected = i == selected

            // Markers
            let currentMark = isCurrent ? Sym.current : " "
            let cursor = isSelected ? Sym.cursor.cyan : " "

            // Priority position
            let position: String
            if let pos = priorityOrder.firstIndex(of: i) {
                position = formatPosition(pos + 1)
            } else {
                position = "   "
            }

            // Device name
            let displayName: String
            if let alias = deviceToAlias[device.name] {
                displayName = isSelected
                    ? "\(alias.bold) \("(\(device.name))".dim)"
                    : "\(alias) \("(\(device.name))".dim)"
            } else {
                displayName = isSelected ? device.name.bold : device.name
            }

            // Highlight row
            let highlight = isSelected ? Ansi.reverseVideo : ""
            let reset = isSelected ? Ansi.reset : ""

            print("\(currentMark) \(cursor) \(position) \(highlight) \(displayName) \(reset)")
        }
        fflush(stdout)
    }

    render()

    while true {
        let key = readKey()

        switch key {
        case .up:
            selected = (selected - 1 + devices.count) % devices.count
            render()
        case .down:
            selected = (selected + 1) % devices.count
            render()

        case .space:
            if let pos = priorityOrder.firstIndex(of: selected) {
                priorityOrder.remove(at: pos)
            } else {
                priorityOrder.append(selected)
            }
            render()

        case .enter:
            print("\(Ansi.showCursor)\(Ansi.clearScreen)", terminator: "")
            disableRawMode(originalTerm)

            if isDaemonRunning() { _ = stopDaemon() }

            if priorityOrder.isEmpty {
                let device = devices[selected]
                let query = deviceToAlias[device.name] ?? device.name
                spawnDaemon(args: ["--daemon", query])
                printSuccess(query)
            } else {
                let priorityList = priorityOrder.map { i -> String in
                    let device = devices[i]
                    return deviceToAlias[device.name] ?? device.name
                }
                savePriority(priorityList)
                spawnDaemon(args: ["--daemon-priority"])
                printSuccess(priorityList.joined(separator: " → ".dim))
            }
            return

        case .char("q"), .escape:
            print("\(Ansi.showCursor)\(Ansi.clearScreen)", terminator: "")
            printSubtle("Cancelled")
            return

        default:
            break
        }
    }
}

// MARK: - Status

func cmdStatus() {
    let devices = getInputDevices()
    let deviceToAlias = buildAliasMap(devices, loadAliases())

    print("")  // Space below command

    print("Active".dim + "  ", terminator: "")
    if let currentID = getDefaultInputDeviceID(),
       let current = devices.first(where: { $0.id == currentID }) {
        if let alias = deviceToAlias[current.name] {
            print(alias + " " + current.name.dim)
        } else {
            print(current.name)
        }
    } else {
        print("None".dim)
    }

    if isDaemonRunning() {
        let priority = loadPriority()
        if !priority.isEmpty {
            print("Order".dim + "   " + priority.joined(separator: " → ".dim))
        }
    } else {
        print("Daemon".dim + "  " + "stopped".dim)
        clearPid()
        clearLock()
    }
}

// MARK: - Stop

func cmdStop() {
    if isDaemonRunning() {
        if stopDaemon() {
            printSuccess("Stopped")
        } else {
            printError("Failed to stop")
            exit(1)
        }
    } else {
        printSubtle("Not running")
    }
}

// MARK: - Watch (Foreground)

/// Global state for signal handling
private var watchLock: MicLock?
private var watchInterruptCount = 0
private var watchIsPrompting = false

func cmdWatch(daemonMode: Bool = false) {
    if isDaemonRunning() { _ = stopDaemon() }

    let settings = loadSettings()

    if !daemonMode {
        let efficiency = Int((settings.sampleDuration / settings.sampleInterval) * 100)
        print("Watch mode".primary + " " + "Ctrl+C to stop".dim)
        print("Sampling".dim + " \(settings.sampleDuration)s every \(settings.sampleInterval)s (\(efficiency)% active)")
        print("Silence".dim + " \(settings.silenceTimeout)s timeout, detection \(settings.enableSilenceDetection ? "on".green : "off".red)")
        print("")
    }

    let lock = MicLock(targetQuery: nil)
    watchLock = lock

    if daemonMode {
        // Daemon mode: simple signal handling
        signal(SIGTERM) { _ in
            watchLock?.stopSilenceMonitoring()
            clearPid()
            clearLock()
            exit(0)
        }
        lock.start(silent: true)
    } else {
        // Interactive mode: Ctrl+C shows daemon prompt
        signal(SIGINT) { _ in
            watchInterruptCount += 1

            // Double Ctrl+C = force quit
            if watchInterruptCount >= 2 {
                print("\n")
                exit(0)
            }

            // Already prompting? Ignore
            if watchIsPrompting { return }

            // Show prompt on main thread
            DispatchQueue.main.async {
                showDaemonPrompt()
            }
        }

        lock.start(silent: false)
    }
}

/// Shows interactive prompt asking to keep running as daemon
private func showDaemonPrompt() {
    watchIsPrompting = true
    watchLock?.stopSilenceMonitoring()

    // Clear line and show prompt
    print("\r\u{1B}[K")
    print("")
    print("Keep running in background? [y/N]".dim, terminator: " ")
    fflush(stdout)

    // Set terminal to raw mode for single-char input
    var oldTermios = termios()
    tcgetattr(STDIN_FILENO, &oldTermios)
    var newTermios = oldTermios
    newTermios.c_lflag &= ~UInt(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &newTermios)

    let char = getchar()

    // Restore terminal
    tcsetattr(STDIN_FILENO, TCSANOW, &oldTermios)
    print()

    if char == Int32(Character("y").asciiValue!) || char == Int32(Character("Y").asciiValue!) {
        daemonizeWatch()
    } else {
        printSubtle("Stopped")
        exit(0)
    }
}

/// Spawn daemon and exit
private func daemonizeWatch() {
    spawnDaemon(args: ["--daemon-priority"])
    printSuccess("Running in background")
    exit(0)
}

// MARK: - Diagnostics (Consolidated)

func cmdDiag(_ query: String) {
    let resolved = resolveAlias(query)
    let devices = getInputDevices()
    let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }

    if matches.isEmpty {
        printError("No device matching '\(query)'")
        exit(1)
    }

    let device = matches[0]
    let props = inspectDevice(device)

    // Header
    printHeader(device.name)

    // Helper for aligned output (pad BEFORE styling)
    func row(_ label: String, _ value: String) {
        print("  " + label.padding(toLength: 12, withPad: " ", startingAt: 0).dim + value)
    }

    row("ID", "\(device.id)")
    row("UID", device.uid.dim)
    row("Transport", props.transportType)
    row("Sample Rate", "\(Int(props.sampleRate)) Hz")
    row("Streams", "\(props.streamCount)")
    row("Alive", props.isAlive ? "Yes".green : "No".red)
    row("Running", props.isRunning ? "Yes".green : "No".dim)

    if let jack = props.jackConnected {
        row("Jack", jack ? "Connected".green : "Disconnected".red)
    }

    printHeader("Audio sample (5s)")

    // Switch to this device for sampling
    let originalDefault = getDefaultInputDeviceID()
    _ = setDefaultInputDevice(device.id)

    let settings = loadSettings()

    sampleAudioContinuous(
        duration: 5.0,
        threshold: settings.silenceThreshold,
        onSample: { rms, hasSignal in
            print("\r  \(formatRMS(rms, threshold: settings.silenceThreshold))     ", terminator: "")
            fflush(stdout)
        },
        completion: { total, signalCount in
            print("\n")
            printHeader("Summary")

            func summaryRow(_ label: String, _ value: String) {
                print("  " + label.padding(toLength: 12, withPad: " ", startingAt: 0).dim + value)
            }

            summaryRow("Samples", "\(total)")
            summaryRow("Signal", "\(signalCount)/\(total)")

            if total > 0 {
                let signalPercent = Double(signalCount) / Double(total) * 100
                let status = signalPercent > 50
                    ? "Transmitter ON".green
                    : "Transmitter OFF".red + " (silence)".dim
                summaryRow("Status", status)
            }

            if let orig = originalDefault {
                _ = setDefaultInputDevice(orig)
            }
            exit(0)
        }
    )

    RunLoop.main.run()
}

// MARK: - Alias

func cmdAlias(_ args: [String]) {
    let aliases = loadAliases()

    if args.count < 2 {
        // miclock alias → list all
        if aliases.isEmpty {
            printSubtle("No aliases. Use: miclock alias <name> <device>")
            return
        }
        print("")
        for (alias, device) in aliases.sorted(by: { $0.key < $1.key }) {
            print("  \(alias) → ".dim + device.dim)
        }
        return
    }

    let aliasName = args[1]

    if args.count == 2 {
        // miclock alias <name> → show single alias
        if let device = aliases[aliasName] {
            print("\(aliasName) → ".dim + device)
        } else {
            printWarning("Alias '\(aliasName)' not found")
        }
    } else if args[2] == "--delete" || args[2] == "-d" {
        // miclock alias <name> --delete
        var mutableAliases = aliases
        if mutableAliases.removeValue(forKey: aliasName) != nil {
            saveAliases(mutableAliases)
            printSuccess("Removed \(aliasName)")
        } else {
            printError("Not found: \(aliasName)")
        }
    } else {
        // miclock alias <name> <device>
        let deviceName = args.dropFirst(2).joined(separator: " ")
        var mutableAliases = aliases
        mutableAliases[aliasName] = deviceName
        saveAliases(mutableAliases)
        printSuccess("\(aliasName) → ".dim + deviceName)
    }
}

// MARK: - Config

func cmdConfig(_ args: [String]) {
    let settings = loadSettings()
    if args.count < 2 {
        print("Settings".primary + "\n")

        // Silence detection settings
        let detection = settings.enableSilenceDetection ? "on".green : "off".red
        print("  " + "Silence Detection".dim)
        print("  " + "timeout".padding(toLength: 12, withPad: " ", startingAt: 0).dim + "\(settings.silenceTimeout)s".accent)
        print("  " + "threshold".padding(toLength: 12, withPad: " ", startingAt: 0).dim + "\(settings.silenceThreshold)".accent)
        print("  " + "detection".padding(toLength: 12, withPad: " ", startingAt: 0).dim + detection)

        // Intermittent sampling settings
        let efficiency = Int((settings.sampleDuration / settings.sampleInterval) * 100)
        print("")
        print("  " + "Intermittent Sampling".dim)
        print("  " + "interval".padding(toLength: 12, withPad: " ", startingAt: 0).dim + "\(settings.sampleInterval)s".accent + " (between samples)".dim)
        print("  " + "duration".padding(toLength: 12, withPad: " ", startingAt: 0).dim + "\(settings.sampleDuration)s".accent + " (per window)".dim)
        print("  " + "efficiency".padding(toLength: 12, withPad: " ", startingAt: 0).dim + "\(efficiency)%".accent + " engine active".dim)

        print("")
        print("  " + "timeout".accent + "    " + "Seconds of silence before fallback".dim)
        print("  " + "threshold".accent + "  " + "RMS level below = silent".dim)
        print("  " + "detection".accent + "  " + "Enable/disable silence detection".dim)
        print("  " + "interval".accent + "   " + "Seconds between sample windows".dim)
        print("  " + "duration".accent + "   " + "Seconds per sample window".dim)
        print("")
        printSubtle("Usage: miclock config <key> <value>")
    } else {
        var newSettings = settings
        switch args[1].lowercased() {
        case "timeout":
            if args.count < 3 {
                print("\(settings.silenceTimeout)s")
            } else if let value = Double(args[2]) {
                newSettings.silenceTimeout = max(1.0, value)
                saveSettings(newSettings)
                printSuccess("timeout = \(newSettings.silenceTimeout)s")
            } else {
                printError("Invalid value")
            }
        case "threshold":
            if args.count < 3 {
                print("\(settings.silenceThreshold)")
            } else if let value = Float(args[2]) {
                newSettings.silenceThreshold = max(0.0, value)
                saveSettings(newSettings)
                printSuccess("threshold = \(value)")
            } else {
                printError("Invalid value")
            }
        case "detection":
            if args.count < 3 {
                print(settings.enableSilenceDetection ? "on" : "off")
            } else {
                let value = args[2].lowercased()
                if value == "on" || value == "true" || value == "1" {
                    newSettings.enableSilenceDetection = true
                    saveSettings(newSettings)
                    printSuccess("detection = on")
                } else if value == "off" || value == "false" || value == "0" {
                    newSettings.enableSilenceDetection = false
                    saveSettings(newSettings)
                    printSuccess("detection = off")
                } else {
                    printError("Use 'on' or 'off'")
                }
            }
        case "interval":
            if args.count < 3 {
                print("\(settings.sampleInterval)s")
            } else if let value = Double(args[2]) {
                newSettings.sampleInterval = max(1.0, value)
                // Ensure duration doesn't exceed interval
                if newSettings.sampleDuration > newSettings.sampleInterval {
                    newSettings.sampleDuration = newSettings.sampleInterval
                }
                saveSettings(newSettings)
                printSuccess("interval = \(newSettings.sampleInterval)s")
            } else {
                printError("Invalid value")
            }
        case "duration":
            if args.count < 3 {
                print("\(settings.sampleDuration)s")
            } else if let value = Double(args[2]) {
                // Duration can't exceed interval
                newSettings.sampleDuration = max(0.5, min(value, settings.sampleInterval))
                saveSettings(newSettings)
                if value > settings.sampleInterval {
                    printSuccess("duration = \(newSettings.sampleDuration)s (clamped to interval)")
                } else {
                    printSuccess("duration = \(newSettings.sampleDuration)s")
                }
            } else {
                printError("Invalid value")
            }
        default:
            printError("Unknown: \(args[1]). Options: timeout, threshold, detection, interval, duration")
        }
    }
}

// MARK: - Completion

let zshCompletion = #"""
#compdef miclock

_miclock_devices() {
    local -a devices
    devices=(${(f)"$(miclock list 2>/dev/null | grep -E '^\s+[0-9]+\.' | sed 's/^[^0-9]*//' | sed 's/^[0-9]*\. *//')"})
    _describe -t devices 'devices' devices
}

_miclock_aliases() {
    local -a aliases
    aliases=(${(f)"$(miclock aliases 2>/dev/null | grep '→' | awk '{print $1}')"})
    _describe -t aliases 'aliases' aliases
}

_miclock_devices_and_aliases() {
    _miclock_devices
    _miclock_aliases
}

_miclock() {
    local curcontext="$curcontext" state line
    typeset -A opt_args

    local -a commands
    commands=(
        'set:Set priority (or TUI)'
        'list:Show devices'
        'stop:Stop daemon'
        'watch:Foreground mode'
        'diag:Audio diagnostics'
        'config:Settings'
        'alias:Manage aliases'
    )

    _arguments -C \
        '1: :->command' \
        '*: :->args'

    case $state in
        command)
            _describe -t commands 'commands' commands
            ;;
        args)
            case ${words[2]} in
                set)
                    _miclock_devices_and_aliases
                    ;;
                diag)
                    _miclock_devices_and_aliases
                    ;;
                alias)
                    if (( CURRENT == 3 )); then
                        _miclock_aliases
                    elif (( CURRENT == 4 )); then
                        local -a opts
                        opts=('--delete:Remove this alias' '-d:Remove this alias')
                        _describe -t options 'options' opts
                        _miclock_devices
                    fi
                    ;;
                config)
                    if (( CURRENT == 3 )); then
                        local -a keys
                        keys=(
                            'timeout:Seconds of silence before fallback (default 5)'
                            'threshold:RMS level threshold for silence (default 0.00001)'
                            'detection:Enable or disable silence detection'
                            'interval:Seconds between sample windows (default 10)'
                            'duration:Seconds per sample window (default 2)'
                        )
                        _describe -t keys 'config keys' keys
                    elif (( CURRENT == 4 )); then
                        case ${words[3]} in
                            timeout)
                                local -a vals
                                vals=('1:1 second' '3:3 seconds' '5:5 seconds (default)' '10:10 seconds' '30:30 seconds')
                                _describe -t values 'timeout values' vals
                                ;;
                            threshold)
                                local -a vals
                                vals=('0.0001:Higher sensitivity' '0.00001:Default' '0.000001:Lower sensitivity')
                                _describe -t values 'threshold values' vals
                                ;;
                            detection)
                                local -a vals
                                vals=('on:Enable silence detection' 'off:Disable silence detection')
                                _describe -t values 'detection values' vals
                                ;;
                            interval)
                                local -a vals
                                vals=('5:5 seconds' '10:10 seconds (default)' '15:15 seconds' '30:30 seconds')
                                _describe -t values 'interval values' vals
                                ;;
                            duration)
                                local -a vals
                                vals=('1:1 second' '2:2 seconds (default)' '3:3 seconds' '5:5 seconds')
                                _describe -t values 'duration values' vals
                                ;;
                        esac
                    fi
                    ;;
                list|stop|watch)
                    # No additional arguments
                    ;;
            esac
            ;;
    esac
}

compdef _miclock miclock
"""#

let bashCompletion = #"""
_miclock() {
    local cur prev words cword
    _init_completion || return

    local commands="set list stop watch diag alias config"

    if [[ $cword -eq 1 ]]; then
        COMPREPLY=($(compgen -W "$commands" -- "$cur"))
    else
        case ${words[1]} in
            set)
                local devices=$(miclock list 2>/dev/null | grep -E '^\s+[0-9]+\.' | sed 's/^[^0-9]*//' | sed 's/^[0-9]*\. *//')
                local aliases=$(miclock aliases 2>/dev/null | grep '→' | awk '{print $1}')
                COMPREPLY=($(compgen -W "$devices $aliases" -- "$cur"))
                ;;
            diag)
                local devices=$(miclock list 2>/dev/null | grep -E '^\s+[0-9]+\.' | sed 's/^[^0-9]*//' | sed 's/^[0-9]*\. *//')
                local aliases=$(miclock aliases 2>/dev/null | grep '→' | awk '{print $1}')
                COMPREPLY=($(compgen -W "$devices $aliases" -- "$cur"))
                ;;
            alias)
                if [[ $cword -eq 2 ]]; then
                    local aliases=$(miclock aliases 2>/dev/null | grep '→' | awk '{print $1}')
                    COMPREPLY=($(compgen -W "$aliases" -- "$cur"))
                elif [[ $cword -eq 3 ]]; then
                    local devices=$(miclock list 2>/dev/null | grep -E '^\s+[0-9]+\.' | sed 's/^[^0-9]*//' | sed 's/^[0-9]*\. *//')
                    COMPREPLY=($(compgen -W "--delete -d $devices" -- "$cur"))
                fi
                ;;
            config)
                if [[ $cword -eq 2 ]]; then
                    COMPREPLY=($(compgen -W "timeout threshold detection interval duration" -- "$cur"))
                elif [[ $cword -eq 3 ]]; then
                    case ${words[2]} in
                        timeout)
                            COMPREPLY=($(compgen -W "1 3 5 10 30" -- "$cur"))
                            ;;
                        threshold)
                            COMPREPLY=($(compgen -W "0.0001 0.00001 0.000001" -- "$cur"))
                            ;;
                        detection)
                            COMPREPLY=($(compgen -W "on off" -- "$cur"))
                            ;;
                        interval)
                            COMPREPLY=($(compgen -W "5 10 15 30" -- "$cur"))
                            ;;
                        duration)
                            COMPREPLY=($(compgen -W "1 2 3 5" -- "$cur"))
                            ;;
                    esac
                fi
                ;;
        esac
    fi
}

complete -F _miclock miclock
"""#

let fishCompletion = #"""
# Disable file completions
complete -c miclock -f

# Helper functions
function __miclock_devices
    miclock list 2>/dev/null | grep -E '^\s+[0-9]+\.' | sed 's/^[^0-9]*//' | sed 's/^[0-9]*\. *//'
end

function __miclock_aliases
    miclock aliases 2>/dev/null | grep '→' | awk '{print $1}'
end

# Commands
complete -c miclock -n "__fish_use_subcommand" -a "set" -d "Interactive picker"
complete -c miclock -n "__fish_use_subcommand" -a "list" -d "Show devices"
complete -c miclock -n "__fish_use_subcommand" -a "stop" -d "Stop daemon"
complete -c miclock -n "__fish_use_subcommand" -a "watch" -d "Foreground mode"
complete -c miclock -n "__fish_use_subcommand" -a "diag" -d "Audio diagnostics"
complete -c miclock -n "__fish_use_subcommand" -a "config" -d "Settings"
complete -c miclock -n "__fish_use_subcommand" -a "alias" -d "Manage aliases"

# set completions (devices for priority)
complete -c miclock -n "__fish_seen_subcommand_from set" -a "(__miclock_devices)" -d "Device"
complete -c miclock -n "__fish_seen_subcommand_from set" -a "(__miclock_aliases)" -d "Alias"

# diag completions
complete -c miclock -n "__fish_seen_subcommand_from diag" -a "(__miclock_devices)" -d "Device"
complete -c miclock -n "__fish_seen_subcommand_from diag" -a "(__miclock_aliases)" -d "Alias"

# alias completions
complete -c miclock -n "__fish_seen_subcommand_from alias; and __fish_is_token_n 3" -a "(__miclock_aliases)" -d "Alias"
complete -c miclock -n "__fish_seen_subcommand_from alias; and __fish_is_token_n 4" -a "--delete" -d "Remove alias"
complete -c miclock -n "__fish_seen_subcommand_from alias; and __fish_is_token_n 4" -a "(__miclock_devices)" -d "Device"

# config completions
complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_is_token_n 3" -a "timeout" -d "Silence timeout"
complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_is_token_n 3" -a "threshold" -d "RMS threshold"
complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_is_token_n 3" -a "detection" -d "Enable/disable"
complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_is_token_n 3" -a "interval" -d "Sample interval"
complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_is_token_n 3" -a "duration" -d "Sample duration"

complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_prev_arg_in timeout" -a "1 3 5 10 30" -d "Seconds"
complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_prev_arg_in threshold" -a "0.0001 0.00001 0.000001" -d "RMS level"
complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_prev_arg_in detection" -a "on off" -d "Toggle"
complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_prev_arg_in interval" -a "5 10 15 30" -d "Seconds"
complete -c miclock -n "__fish_seen_subcommand_from config; and __fish_prev_arg_in duration" -a "1 2 3 5" -d "Seconds"
"""#

func cmdCompletion(_ shell: String) {
    switch shell.lowercased() {
    case "zsh":
        print(zshCompletion)
    case "bash":
        print(bashCompletion)
    case "fish":
        print(fishCompletion)
    default:
        printError("Unknown shell: \(shell)")
        printSubtle("Supported: zsh, bash, fish")
        exit(1)
    }
}

// MARK: - Daemon Spawn

func spawnDaemon(args: [String]) {
    let execPath: String
    if let resolvedPath = Bundle.main.executablePath {
        execPath = resolvedPath
    } else {
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            execPath = arg0
        } else {
            let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":")
            var found = arg0
            for dir in pathDirs {
                let candidate = "\(dir)/\(arg0)"
                if FileManager.default.fileExists(atPath: candidate) {
                    found = candidate
                    break
                }
            }
            execPath = found
        }
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: execPath)
    process.arguments = args
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice

    do {
        try process.run()
        usleep(100_000)
    } catch {
        print("\(Sym.cross) Failed: \(error)")
        exit(1)
    }
}
