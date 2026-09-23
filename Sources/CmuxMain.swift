import Bonsplit
import CmuxFoundation
import Foundation
import SwiftUI

/// The process entry point. When the binary is launched with a worker flag
/// (the app re-executes its own binary so a crash or hang in paste preparation,
/// the Simulator, interpreter, or renderer kills only the worker process), run
/// that worker instead of the app:
/// - the paste worker resolves providers and prepares images before any app or
///   SwiftUI startup;
/// - the Simulator worker owns private frameworks and remote display state;
/// - the render worker hosts its own faceless AppKit session and shares the
///   rendered layer tree with the host;
/// - the interpreter worker (stage-1 fallback path) runs before any
///   AppKit/SwiftUI setup.
@main
enum CmuxMain {
    /// Raises inherited descriptor limits before receipt writing or worker routing.
    static func main() {
        FileDescriptorLimitController().raiseSoftLimitIfNeeded()
        depottIsolateAgentHookState()
        AppHostProcessReceipt.writeIfRequired()
#if DEBUG
        // Bonsplit's `dlog` and the app's `cmuxDebugLog` resolve the same
        // debug log file. Route bonsplit through the shared writer so the
        // file has exactly one serialized append path (single O_APPEND
        // handle, monotonic #<seq> line prefixes); with two independent
        // appenders, concurrent lines interleaved and landed out of order.
        Bonsplit.DebugEventLog.setExternalSink { cmuxDebugLog($0) }
#endif
        CmuxWorkerEntrypoint(arguments: CommandLine.arguments).runIfRequested()
        SurfaceResumeApprovalStore.preloadSigningSecret()
        cmuxApp.main()
    }

    /// Depott: keep agent hook state out of `~/.cmuxterm`, which a side-by-side
    /// upstream cmux also rewrites. An older cmux CLI re-encodes the shared
    /// `claude-hook-sessions.json` without `pidStartSeconds`, so restore can
    /// never prove Depott's agents were running and never auto-resumes them.
    /// Terminals and hook CLIs inherit the override from this process.
    private static func depottIsolateAgentHookState() {
        let environment = ProcessInfo.processInfo.environment
        if let existing = environment["CMUX_AGENT_HOOK_STATE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return
        }
        let fileManager = FileManager.default
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let stateDirectory = home.appendingPathComponent(".depott/agent-state", isDirectory: true)
        try? fileManager.createDirectory(
            at: stateDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        setenv("CMUX_AGENT_HOOK_STATE_DIR", stateDirectory.path, 1)
    }
}
