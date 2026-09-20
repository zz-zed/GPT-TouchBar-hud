import Foundation
import HookCore
import Darwin

let arguments = CommandLine.arguments
// Configuration emits this exact versioned owner argument. No arbitrary subcommands.
if arguments.count == 5, arguments[1] == "emit", arguments[2] == "--owner=gpt-touchbar-hud-v1", arguments[3] == "--socket" {
    HookEmitter.run(socketURL: URL(fileURLWithPath: arguments[4]))
}
print("{}")
exit(0)
