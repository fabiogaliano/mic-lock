import Foundation

// MARK: - Usage

func printUsage() {
    print("Mic preference manager with priority fallback".dim)
    print("")
    print("  set [device]...".accent + "   " + "Set priority (or TUI if no args)".dim)
    print("  list".accent + "              " + "Show devices".dim)
    print("  stop".accent + "              " + "Stop daemon".dim)
    print("  watch".accent + "             " + "Foreground mode".dim)
    print("  diag <device>".accent + "     " + "Audio diagnostics".dim)
    print("  config".accent + "            " + "Settings".dim)
    print("  alias [name]".accent + "      " + "Manage aliases".dim)
}

// MARK: - Main

let args = Array(CommandLine.arguments.dropFirst())

if args.isEmpty {
    cmdStatus()
    print("")
    printUsage()
    exit(0)
}

switch args[0].lowercased() {
case "set", "pick":
    if args.count == 1 {
        cmdPick()
    } else {
        let deviceArgs = Array(args.dropFirst())
        let devices = getInputDevices()

        // Validate all device queries
        for query in deviceArgs {
            let resolved = resolveAlias(query)
            let matches = devices.filter { $0.name.lowercased().contains(resolved.lowercased()) }
            if matches.count > 1 {
                printError("'\(query)' matches multiple devices:")
                for m in matches { print("  - \(m.name)") }
                exit(1)
            }
        }

        if isDaemonRunning() { _ = stopDaemon() }

        if deviceArgs.count == 1 {
            // Single device: lock mode (no sampling)
            let query = deviceArgs[0]
            spawnDaemon(args: ["--daemon", query])

            if let device = findDevice(matching: query) {
                let aliases = loadAliases()
                let deviceToAlias = buildAliasMap([device], aliases)
                if let alias = deviceToAlias[device.name] {
                    printSuccess(alias + " " + device.name.dim)
                } else {
                    printSuccess(device.name)
                }
            } else {
                printInfo("Waiting for \(query)...")
            }
        } else {
            // Multiple devices: priority mode (with sampling if detection on)
            savePriority(deviceArgs)
            spawnDaemon(args: ["--daemon-priority"])

            if let (device, _) = findBestAvailableDevice() {
                let aliases = loadAliases()
                let deviceToAlias = buildAliasMap([device], aliases)
                if let alias = deviceToAlias[device.name] {
                    printSuccess(alias + " " + device.name.dim)
                } else {
                    printSuccess(device.name)
                }
            } else {
                printInfo("Waiting for devices...")
            }
        }
    }

case "list", "ls", "-l":
    cmdListPlain()

case "stop":
    cmdStop()

case "watch":
    cmdWatch()

case "diag", "inspect", "rms", "debug":
    if args.count < 2 {
        print("Usage: miclock diag <device>")
        exit(1)
    }
    let query = args.dropFirst().joined(separator: " ")
    cmdDiag(query)

case "alias", "aliases":
    cmdAlias(args)

case "config":
    cmdConfig(args)

case "completion":
    let shell = args.count > 1 ? args[1] : "zsh"
    cmdCompletion(shell)

case "--daemon":
    if args.count < 2 { exit(1) }
    let query = args.dropFirst().joined(separator: " ")
    let lock = MicLock(targetQuery: query)
    lock.start(silent: true)

case "--daemon-priority":
    let lock = MicLock(targetQuery: nil)
    lock.start(silent: true)

case "-h", "--help", "help":
    printUsage()

default:
    printError("Unknown command: \(args[0])")
    print("")
    printUsage()
    exit(1)
}
