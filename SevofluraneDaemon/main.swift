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

MainActor.assumeIsolated { daemon.start() }

RunLoop.main.run()
