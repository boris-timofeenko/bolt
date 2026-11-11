// Sends a debug command to a Bolt launched with --debug-control. See Sources/Bolt/App/DebugControl.swift.
//   swiftc -O scripts/boltctl.swift -o .build/boltctl && .build/boltctl key 124
import Foundation

let line = CommandLine.arguments.dropFirst().joined(separator: " ")
DistributedNotificationCenter.default().postNotificationName(
    Notification.Name("org.boltviewer.Bolt.debug"), object: line, userInfo: nil, deliverImmediately: true)
