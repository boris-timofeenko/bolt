// BoltBench.app: holds the Screen Recording and Accessibility grants for the viewer benchmark.
// It runs exactly one program, `viewerbench` next to the app, with the arguments it was given.
// macOS attributes a child's screen recording and key presses to the app that started it, so the
// measuring tool can be rebuilt without asking for the grants again.
import Foundation

let bundle = Bundle.main.bundleURL
let tool = bundle.deletingLastPathComponent().appendingPathComponent("viewerbench").path
var pid: pid_t = 0
let arguments = [tool] + CommandLine.arguments.dropFirst()
let argv = arguments.map { strdup($0) } + [nil]
guard posix_spawn(&pid, tool, nil, nil, argv, environ) == 0 else { exit(127) }
var status: Int32 = 0
waitpid(pid, &status, 0)
exit((status >> 8) & 0xff)
