import Foundation

// §233 experiment: does accept() BLOCK when it is called on a listening
// socket AFTER shutdown(SHUT_RDWR)? (The fixed stop() wakes a thread that is
// already in accept; a thread that reaches accept a moment later is the case.)
func listening() -> Int32 {
    let s = socket(AF_INET, SOCK_STREAM, 0)
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    listen(s, 16)
    return s
}

func acceptReturns(within seconds: Double, on s: Int32) -> (returned: Bool, result: Int32, error: Int32) {
    let done = DispatchSemaphore(value: 0)
    final class Box: @unchecked Sendable { var result: Int32 = 0; var error: Int32 = 0 }
    let box = Box()
    let thread = Thread {
        box.result = accept(s, nil, nil)
        box.error = errno
        done.signal()
    }
    thread.start()
    let returned = done.wait(timeout: .now() + seconds) == .success
    return (returned, box.result, box.error)
}

// 1. accept called AFTER shutdown
let a = listening()
shutdown(a, SHUT_RDWR)
let late = acceptReturns(within: 2, on: a)
print("1. accept after shutdown:   returned=\(late.returned) result=\(late.result) errno=\(late.error) (\(String(cString: strerror(late.error))))")

// 2. accept already blocked, THEN shutdown (what the fix relies on)
let b = listening()
let done = DispatchSemaphore(value: 0)
let t = Thread { _ = accept(b, nil, nil); done.signal() }
t.start()
Thread.sleep(forTimeInterval: 0.3)   // experiment only: let the thread block
shutdown(b, SHUT_RDWR)
print("2. blocked, then shutdown:  returned=\(done.wait(timeout: .now() + 2) == .success)")

// 3. case 1's stuck thread: does close() wake it?
if !late.returned {
    let c = DispatchSemaphore(value: 0)
    let s2 = listening()
    shutdown(s2, SHUT_RDWR)
    let stuck = Thread { _ = accept(s2, nil, nil); c.signal() }
    stuck.start()
    Thread.sleep(forTimeInterval: 0.3)
    close(s2)
    print("3. stuck after shutdown, then close: returned=\(c.wait(timeout: .now() + 2) == .success)")
}
