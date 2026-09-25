import Testing
@testable import Sevoflurane

/// Naming the wineserver a launch could not connect to, from Wine's log.
struct StaleWineserverTests {
    @Test
    func `the cannot-connect line names the server's pid`() {
        let log = """
        sevo:loader pid=52356 exe=Steam.exe loader=engine
        wine: a wine server seems to be running, but I cannot connect to it.
           You probably need to kill that process (it might be pid 45089).
        """
        #expect(StaleWineserver.pid(in: log) == 45089)
    }

    @Test
    func `a log without the line names nothing`() {
        #expect(StaleWineserver.pid(in: "sevo:loader pid=1 exe=Steam.exe\n(it might be pid 7)") == nil)
    }
}
