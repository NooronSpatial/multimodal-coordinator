import Foundation

// Does Process close a pipe's write end TWICE when stdout and stderr share it?
// A second thread opens /dev/null over and over and checks each descriptor is
// still open a moment later; a descriptor closed by nobody it knows of is stolen.
final class Stolen: @unchecked Sendable {
    var count = 0
    var running = true
    let lock = NSLock()
}

func trial(sharedPipe: Bool, launches: Int) -> Int {
    let stolen = Stolen()
    let opener = Thread {
        while stolen.lock.withLock({ stolen.running }) {
            let fd = open("/dev/null", O_RDONLY)
            guard fd >= 0 else { continue }
            usleep(50)
            if fcntl(fd, F_GETFD) == -1 && errno == EBADF {
                stolen.lock.withLock { stolen.count += 1 }   // closed under us
            } else {
                close(fd)
            }
        }
    }
    opener.start()
    for _ in 0..<launches {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/true")
        let out = Pipe()
        process.standardOutput = out
        process.standardError = sharedPipe ? out : Pipe()
        try? process.run()
        process.waitUntilExit()
        _ = try? out.fileHandleForReading.readToEnd()
    }
    stolen.lock.withLock { stolen.running = false }
    usleep(10_000)
    return stolen.lock.withLock { stolen.count }
}

let launches = 1500
print("shared pipe (stdout = stderr):  stolen descriptors =", trial(sharedPipe: true, launches: launches))
print("separate pipes:                  stolen descriptors =", trial(sharedPipe: false, launches: launches))
