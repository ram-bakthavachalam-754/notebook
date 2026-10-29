import XCTest
@testable import NotebookCore

final class AgentWebTransportTests: XCTestCase {
    func testWebURLsRejectPrivateServicesAndCredentials() throws {
        for address in ["file:///private/secret","https://name:password@example.com","http://127.0.0.1","http://127.1","http://2130706433","http://0177.0.0.1","http://192.168.1.1","http://10.0.0.1","http://169.254.169.254","http://[::1]","http://[::ffff:7f00:1]","http://[2001:0db8::1]","http://localhost","http://printer.local","https://example.com:8443","https://example.com\\@127.0.0.1"] {
            XCTAssertThrowsError(try AgentWebTransport.validateURL(address),address)
        }
        XCTAssertEqual(try AgentWebTransport.validateURL("https://example.com/page").host,"example.com")
    }
    func testAddressPolicyMatchesPublicWebRequirements() {
        for address in ["0.0.0.0","10.0.0.1","127.0.0.1","169.254.169.254","172.16.0.1","192.168.1.1","100.64.0.1","198.18.0.1","192.0.2.1","203.0.113.1","224.1.1.1","::1","::ffff:8.8.8.8","fc00::1","fe80::1","2001:0000::1","2001:0db8::1"] { XCTAssertFalse(AgentWebTransport.publicAddress(address),address) }
        XCTAssertTrue(AgentWebTransport.publicAddress("8.8.8.8")); XCTAssertTrue(AgentWebTransport.publicAddress("2606:4700:4700::1111"))
    }
}
