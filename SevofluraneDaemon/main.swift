import Foundation

let daemon = Daemon()

// launchd sends SIGTERM for a bootout, a logout and a shutdown; each of those
// is the session ending, and a bottle left running past it is a Wine tree with
// nothing left to own it. The dispatch source delivers the signal on the main
// queue, where the daemon can run its bounded teardown before exiting.
signal(SIGTERM, SIG_IGN)
let termination = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
termination.setEventHandler {
    Task(name: "Daemon shutdown") { @MainActor in
        await daemon.bringTheBottleDown()
        exit(0)
    }
}
termination.resume()

// The control port is taken exclusively, so a second daemon cannot come up
// beside the first and split supervision between them. It ends here instead,
// having said in the log which one holds the port. That exit is a success, so
// launchd's `KeepAlive { SuccessfulExit = false }` leaves it ended; a control
// port that failed for any other reason exits nonzero and is started again.
Task(name: "Daemon startup") { @MainActor in
    switch await daemon.start() {
    case .serving: break
    case .anotherSupervisorHoldsThePort: exit(0)
    case .failed: exit(1)
    }
}

RunLoop.main.run()
