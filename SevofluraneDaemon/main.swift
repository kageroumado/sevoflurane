import Foundation

let daemon = Daemon()

// launchd sends SIGTERM at bootout, logout and shutdown: bring the bottle down
// first, or its Wine tree outlives its owner.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    Task(name: "Daemon shutdown") { @MainActor in
        await daemon.bringTheBottleDown()
        exit(0)
    }
}
termination.resume()

// A second daemon finds the control port taken and exits 0, which
// `KeepAlive { SuccessfulExit = false }` leaves ended; any other failure exits
// nonzero and launchd starts it again.
Task(name: "Daemon startup") { @MainActor in
    switch await daemon.start() {
    case .serving: break
    case .anotherSupervisorHoldsThePort: exit(0)
    case .failed: exit(1)
    }
}

RunLoop.main.run()
