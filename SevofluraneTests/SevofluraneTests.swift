import Foundation
import Testing
@testable import Sevoflurane

struct LicenseParsingTests {
    private let future = "[crossmac]\ncustomer=user\nexpires=2099/01/01\n[license]\nid=abc123\n"
    private let past = "[crossmac]\ncustomer=user\nexpires=2020/01/01\n[license]\nid=abc123\n"

    @Test
    func `valid license`() {
        let result = SetupProbe.parseLicense(future)
        #expect(result.licensed)
        #expect(result.expires == "2099/01/01")
    }

    @Test
    func `expired license`() {
        #expect(!SetupProbe.parseLicense(past).licensed)
    }

    @Test
    func `missing or partial license`() {
        #expect(!SetupProbe.parseLicense("").licensed)
        #expect(!SetupProbe.parseLicense("[crossmac]\nexpires=2099/01/01\n").licensed)
    }

    @Test
    func `no expiry still licensed`() {
        #expect(SetupProbe.parseLicense("[license]\nid=abc123\n").licensed)
    }
}
