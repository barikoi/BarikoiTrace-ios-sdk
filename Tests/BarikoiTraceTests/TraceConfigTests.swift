import XCTest
@testable import BarikoiTrace

final class TraceConfigTests: XCTestCase {

    private func makeConfig() -> TraceConfig {
        TraceConfig(apiKey: "key", mqttUsername: "user", mqttPassword: "pass")
    }

    // MARK: - Defaults

    func testDefaultsMatchTraceApiRoutes() {
        let config = makeConfig()
        XCTAssertEqual(config.baseURL, TraceApiRoutes.baseURL)
        XCTAssertEqual(config.mqttURL, TraceApiRoutes.mqttURL)
        XCTAssertEqual(config.mqttClientIdPrefix, TraceMqttClient.defaultClientIdPrefix)
    }

    func testDefaultClientIdPrefixIsPlatformSpecific() {
        // Android uses "AndroidClient-". Brokers that ACL on client-id
        // pattern distinguish the two, so this must not drift.
        XCTAssertEqual(makeConfig().mqttClientIdPrefix, "iOSClient-")
    }

    // MARK: - Transport encryption

    func testTLSSchemesAreRecognized() {
        for scheme in ["ssl", "mqtts", "tls", "wss"] {
            var config = makeConfig()
            config.mqttURL = "\(scheme)://broker.example.com:8883"
            XCTAssertTrue(
                config.isMqttTransportEncrypted,
                "\(scheme):// should be recognized as encrypted"
            )
        }
    }

    func testPlaintextSchemesAreNotEncrypted() {
        for scheme in ["tcp", "mqtt", "ws"] {
            var config = makeConfig()
            config.mqttURL = "\(scheme)://broker.example.com:1883"
            XCTAssertFalse(
                config.isMqttTransportEncrypted,
                "\(scheme):// must not be reported as encrypted"
            )
        }
    }

    func testMalformedURLIsNotReportedAsEncrypted() {
        // Fail closed: an unparseable URL must never claim encryption.
        var config = makeConfig()
        config.mqttURL = "not a url"
        XCTAssertFalse(config.isMqttTransportEncrypted)
    }

    // MARK: - Warnings

    func testSDKDefaultsWarnAboutPlaintextBroker() {
        // The shipped default is plaintext. If that ever changes, this test
        // should be the thing that notices.
        let warnings = makeConfig().warnings
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("plaintext"))
    }

    func testFullyEncryptedConfigProducesNoWarnings() {
        var config = makeConfig()
        config.mqttURL = "ssl://broker.example.com:8883"
        config.baseURL = "https://api.example.com/api/v1/"
        XCTAssertTrue(config.warnings.isEmpty, "\(config.warnings)")
    }

    func testEmptyApiKeyWarns() {
        var config = TraceConfig(apiKey: "", mqttUsername: "u", mqttPassword: "p")
        config.mqttURL = "ssl://broker.example.com:8883"
        XCTAssertTrue(config.warnings.contains { $0.contains("apiKey") })
    }

    func testEmptyBrokerCredentialsWarn() {
        var config = TraceConfig(apiKey: "key", mqttUsername: "", mqttPassword: "")
        config.mqttURL = "ssl://broker.example.com:8883"
        XCTAssertTrue(config.warnings.contains { $0.contains("MQTT credentials") })
    }

    func testNonHTTPSBaseURLWarns() {
        var config = makeConfig()
        config.mqttURL = "ssl://broker.example.com:8883"
        config.baseURL = "http://api.example.com/api/v1/"
        XCTAssertTrue(config.warnings.contains { $0.contains("HTTPS") })
    }
}
