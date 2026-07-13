import Foundation
import NocturnalCore

/// Fail-open stdin → Unix domain socket bridge for agent hooks.
///
/// Exit code is always 0 so hooks never break the agent if Nocturnal is
/// quit, crashed, or not yet launched.
@main
struct HookForwarderMain {
    static func main() {
        let environment = ProcessInfo.processInfo.environment
        let args = Array(CommandLine.arguments.dropFirst())

        if args.contains("--help") || args.contains("-h") {
            print(
                """
                nocturnal-hook-forwarder — fail-open stdin → Nocturnal socket

                Usage:
                  nocturnal-hook-forwarder [--socket PATH] [--wrap-source codex|claude]
                  echo '{"v":1,...}' | nocturnal-hook-forwarder

                Options:
                  --socket PATH              Unix domain socket path
                  --wrap-source SOURCE       Wrap non-envelope JSON as EventEnvelope (codex|claude)
                  --session-id ID            Default session id when wrapping
                  --timeout SECONDS          Connect timeout (default 0.5)
                  --help                     Show help

                Environment:
                  NOCTURNAL_SOCKET           Override socket path
                  NOCTURNAL_FORWARDER_DEBUG  Set to 1 for stderr diagnostics

                Always exits 0 (fail-open).
                """
            )
            exit(0)
        }

        let socketURL: URL
        if let idx = args.firstIndex(of: "--socket"), args.index(after: idx) < args.endIndex {
            socketURL = URL(fileURLWithPath: args[args.index(after: idx)])
        } else if let env = environment[NocturnalEnvironmentKey.socket.rawValue], !env.isEmpty {
            socketURL = URL(fileURLWithPath: env)
        } else {
            do {
                socketURL = try SocketPaths.resolve(environment: environment).socketURL
            } catch {
                // Fail open even if path resolution fails.
                if environment["NOCTURNAL_FORWARDER_DEBUG"] == "1" {
                    fputs("nocturnal-hook-forwarder: path resolve failed: \(error)\n", stderr)
                }
                exit(0)
            }
        }

        let wrapSource = parseWrapSource(from: args)
        let sessionId = parseValue("--session-id", from: args)
        let timeout: TimeInterval = {
            if let raw = parseValue("--timeout", from: args), let value = TimeInterval(raw) {
                return value
            }
            return 0.5
        }()

        let options = HookForwarderOptions(
            connectTimeout: timeout,
            wrapSource: wrapSource,
            defaultSessionId: sessionId
        )
        let forwarder = FailOpenHookForwarder(options: options)
        let lines = StdinReader.readLines()
        if lines.isEmpty {
            // Some hooks invoke with empty stdin; still succeed.
            exit(0)
        }

        for line in lines {
            let result = forwarder.forward(line: line, socketPath: socketURL)
            if !result.succeeded {
                if environment["NOCTURNAL_FORWARDER_DEBUG"] == "1" {
                    fputs("nocturnal-hook-forwarder: \(result.detail)\n", stderr)
                }
            }
        }

        exit(0)
    }

    private static func parseWrapSource(from args: [String]) -> AgentSource? {
        guard let raw = parseValue("--wrap-source", from: args) else { return nil }
        switch raw.lowercased() {
        case "codex": return .codex
        case "claude": return .claude
        default:
            fputs("nocturnal-hook-forwarder: unknown wrap-source \(raw) (use codex|claude)\n", stderr)
            return nil
        }
    }

    private static func parseValue(_ flag: String, from args: [String]) -> String? {
        guard let idx = args.firstIndex(of: flag), args.index(after: idx) < args.endIndex else {
            return nil
        }
        return args[args.index(after: idx)]
    }
}
