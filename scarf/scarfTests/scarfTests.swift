//
//  scarfTests.swift
//  scarfTests
//
//  Created by Alan Wizemann on 3/31/26.
//

import Testing
import Darwin
import ScarfCore
@testable import scarf

@Suite struct ControlPathTests {

    /// macOS' `sun_path` is 104 bytes including the NUL terminator. OpenSSH's
    /// `%C` token expands to a 64-char SHA1 hex digest. The full bound socket
    /// path is `<controlDir>/<%C>`, so the worst case is
    /// `controlDir.utf8.count + 1 (separator) + 64 (hash) + 1 (NUL)`.
    ///
    /// This test pins the invariant violated by the original Caches-based
    /// path that triggered issue #19 — any future change to `controlDirPath`
    /// that drifts back over the limit will fail here instead of silently
    /// breaking remote SSH for users with long `$HOME` strings.
    @Test func controlDirPathFitsMacOSSocketLimit() {
        let dir = SSHTransport.controlDirPath()
        let worstCase = dir.utf8.count + 1 + 64 + 1
        #expect(worstCase <= 104,
                "ControlPath worst case is \(worstCase) bytes for dir '\(dir)'; macOS sun_path limit is 104")
    }

    /// `/tmp` is shared across all users on a Mac. The per-uid suffix is what
    /// keeps two local users' control sockets from colliding — guard against
    /// a refactor that drops it.
    @Test func controlDirPathIsPerUser() {
        let dir = SSHTransport.controlDirPath()
        #expect(dir.contains("\(getuid())"),
                "ControlPath '\(dir)' must include the current uid for per-user isolation")
    }
}
