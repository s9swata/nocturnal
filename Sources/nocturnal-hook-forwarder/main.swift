import Foundation
import NocturnalCore

/// Fail-open stdin → Unix domain socket bridge for agent hooks.
///
/// Exit code is always 0 so hooks never break the agent if Nocturnal is
/// quit, crashed, or not yet launched.
///
/// **PermissionRequest / decision events:** blocks until Nocturnal UI answers
/// (or timeout), then prints Codex/Claude allow|deny JSON on stdout.
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
                  --decision-timeout SECONDS Wait for UI on PermissionRequest (default 120)
                  --help                     Show help

                Environment:
                  NOCTURNAL_SOCKET           Override socket path
                  NOCTURNAL_FORWARDER_DEBUG  Set to 1 for stderr diagnostics
                  NOCTURNAL_DECISION_TIMEOUT Override decision wait (seconds)
                  NOCTURNAL_FAIL_CLOSED=1    Timeout/app-down → deny (default defer)

                Always exits 0 (fail-open for agent process).
                PermissionRequest waits for Nocturnal Allow/Deny then prints decision JSON.
                Other events print {} after forward.
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
                if debug {
                    fputs("nocturnal-hook-forwarder: path resolve failed: \(error)\n", stderr)
                }
                print("{}")
                exit(0)
            }
        }

        var decisionTimeout = HookForwarderOptions.defaultDecisionTimeout
        if let env = environment["NOCTURNAL_DECISION_TIMEOUT"], let v = TimeInterval(env), v > 0 {
            decisionTimeout = min(v, HookForwarderOptions.maxDecisionTimeout)
        }
        if let cli = parsed.decisionTimeout {
            decisionTimeout = cli
        }

        let failClosed = environment["NOCTURNAL_FAIL_CLOSED"] == "1"
            || environment["NOCTURNAL_FAIL_CLOSED"]?.lowercased() == "true"

        let options = HookForwarderOptions(
            connectTimeout: parsed.timeout,
            wrapSource: parsed.wrapSource,
            defaultSessionId: parsed.sessionId,
            decisionTimeout: decisionTimeout,
            failClosedOnTimeout: failClosed
        )
        let forwarder = FailOpenHookForwarder(options: options)
        let lines = StdinReader.readLines()
        if lines.isEmpty {
            print("{}")
            exit(0)
        }

        // Last line's stdout wins (hooks usually send one JSON object).
        var stdoutBody = "{}"
        for line in lines {
            let outcome = forwarder.forwardWithDecision(line: line, socketPath: socketURL)
            if !outcome.forward.succeeded, debug {
                fputs("nocturnal-hook-forwarder: \(outcome.forward.detail)\n", stderr)
            }
            if debug {
                fputs("nocturnal-hook-forwarder: \(outcome.forward.detail)\n", stderr)
            }
            stdoutBody = outcome.stdoutJSON
        }

        print(stdoutBody)
        exit(0)
    }
}
