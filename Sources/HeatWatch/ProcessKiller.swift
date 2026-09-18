import Darwin
import Foundation

enum KillMode {
    case terminate   // SIGTERM — lets the app quit cleanly
    case force       // SIGKILL — for the stuck ones

    var signal: Int32 { self == .terminate ? SIGTERM : SIGKILL }
    var signalName: String { self == .terminate ? "SIGTERM" : "SIGKILL" }
    var verb: String { self == .terminate ? "Quit" : "Force Kill" }
    var pastTense: String { self == .terminate ? "Asked to quit" : "Force-killed" }
}

struct KillOutcome {
    var sent = 0
    var failures: [(pid: pid_t, reason: String)] = []
}

enum ProcessKiller {
    static func send(_ mode: KillMode, to pids: [pid_t]) -> KillOutcome {
        var out = KillOutcome()
        for pid in pids where pid > 1 {   // never launchd / kernel_task
            if Darwin.kill(pid, mode.signal) == 0 {
                out.sent += 1
                continue
            }
            let e = errno
            if e == ESRCH {
                out.sent += 1   // already gone
            } else if e == EPERM {
                out.failures.append((pid, "pid \(pid): not permitted (owned by another user)"))
            } else {
                out.failures.append((pid, "pid \(pid): \(String(cString: strerror(e)))"))
            }
        }
        return out
    }
}
