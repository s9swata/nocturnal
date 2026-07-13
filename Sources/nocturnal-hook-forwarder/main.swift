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
        let parsed = HookForwarderCLIOptions.parse(arguments: args)

        if parsed.helpRequested {
            print(
                """
                nocturnal-hook-forwarder — fail-open stdin → Nocturnal socket

                Usage:
                  nocturnal-hook-forwarder [--socket PATH] [--wrap-source codex|claude]
                  echo '{"v":1,...}' | nocturnal-hook-forwarder

                Options:
                  --socket PATH              Unix domain socket path
                  --wrap-source SOURCE       Default source when normalizing raw hooks (codex|claude)
                  --session-id ID            Default session id when normalizing
                  --timeout SECONDS          Connect timeout (default 0.5)
                  --help                     Show help

                Environment:
                  NOCTURNAL_SOCKET           Override socket path
                  NOCTURNAL_FORWARDER_DEBUG  Set to 1 for stderr diagnostics

                Always exits 0 (fail-open). Stdin is bounded (size + timeout).
                Raw upstream JSON is normalized to EventEnvelope before send.
                """
            )
            exit(0)
        }

        let debug = environment["NOCTURNAL_FORWARDER_DEBUG"] == "1"
        if debug {
            for warning in parsed.warnings {
                fputs("nocturnal-hook-forwarder: \(warning)\n", stderr)
            }
        }

        let socketURL: URL
        if let path = parsed.socketPath {
            socketURL = URL(fileURLWithPath: path)
        } else if let env = environment[NocturnalEnvironmentKey.socket.rawValue], !env.isEmpty {
            socketURL = URL(fileURLWithPath: env)
        } else {
            do {
                socketURL = try SocketPaths.resolve(environment: environment).socketURL
            } catch {
                // Fail open even if path resolution fails.
                if debug {
                    fputs("nocturnal-hook-forwarder: path resolve failed: \(error)\n", stderr)
                }
                exit(0)
            }
        }

        let options = HookForwarderOptions(
            connectTimeout: parsed.timeout,
            wrapSource: parsed.wrapSource,
            defaultSessionId: parsed.sessionId
        )
        let forwarder = FailOpenHookForwarder(options: options)
        let lines = StdinReader.readLines()
        if lines.isEmpty {
            // Some hooks invoke with empty stdin; still succeed.
            exit(0)
        }

        for line in lines {
            let result = forwarder.forward(line: line, socketPath: socketURL)
            if !result.succeeded, debug {
                fputs("nocturnal-hook-forwarder: \(result.detail)\n", stderr)
            }
        }

        exit(0)
    }
}
