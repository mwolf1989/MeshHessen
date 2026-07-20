import Foundation
import Testing

@testable import MeshHessen

@Suite("MQTT 3.1.1 Codec")
struct MQTT311CodecTests {
    @Test("Remaining length uses MQTT base-128 encoding")
    func remainingLength() throws {
        #expect(try MQTT311Codec.encodeRemainingLength(0) == [0])
        #expect(try MQTT311Codec.encodeRemainingLength(127) == [0x7F])
        #expect(try MQTT311Codec.encodeRemainingLength(128) == [0x80, 0x01])
        #expect(try MQTT311Codec.encodeRemainingLength(16_384) == [0x80, 0x80, 0x01])
        #expect(
            try MQTT311Codec.encodeRemainingLength(MQTT311Codec.maximumRemainingLength)
                == [0xFF, 0xFF, 0xFF, 0x7F]
        )
    }

    @Test("CONNECT requests MQTT 3.1.1, clean session, keepalive and credentials")
    func connectPacket() throws {
        let packet = try MQTT311Codec.connect(
            clientID: "id",
            username: "u",
            password: "p",
            keepAliveSeconds: 60
        )

        #expect(
            Array(packet) == [
                0x10, 0x14,
                0x00, 0x04, 0x4D, 0x51, 0x54, 0x54,
                0x04, 0xC2, 0x00, 0x3C,
                0x00, 0x02, 0x69, 0x64,
                0x00, 0x01, 0x75,
                0x00, 0x01, 0x70,
            ]
        )
    }

    @Test("SUBSCRIBE uses the required fixed-header flags and QoS zero")
    func subscribePacket() throws {
        let packet = try MQTT311Codec.subscribe(topicFilter: "msh/#", packetID: 7)
        #expect(
            Array(packet) == [
                0x82, 0x0A,
                0x00, 0x07,
                0x00, 0x05, 0x6D, 0x73, 0x68, 0x2F, 0x23,
                0x00,
            ]
        )
    }

    @Test("Fragmented retained PUBLISH packets preserve binary payloads")
    func fragmentedPublish() throws {
        let encoded = try MQTT311Codec.publish(
            topic: "msh/test",
            payload: Data([0x00, 0xFF, 0x42]),
            retained: true
        )
        var decoder = MQTT311StreamDecoder()

        #expect(try decoder.append(encoded.prefix(2)).isEmpty)
        #expect(
            try decoder.append(encoded.dropFirst(2))
                == [.publish(topic: "msh/test", payload: Data([0x00, 0xFF, 0x42]), retained: true)]
        )
        #expect(decoder.bufferedByteCount == 0)
    }

    @Test("CONNACK, SUBACK and PINGRESP decode from one receive chunk")
    func brokerResponses() throws {
        let data = Data([
            0x20, 0x02, 0x00, 0x00,
            0x90, 0x03, 0x00, 0x01, 0x00,
            0xD0, 0x00,
        ])
        var decoder = MQTT311StreamDecoder()

        #expect(
            try decoder.append(data) == [
                .connAck(sessionPresent: false, returnCode: 0),
                .subAck(packetID: 1, returnCodes: [0]),
                .pingResponse,
            ]
        )
    }

    @Test("QoS one broker publications are rejected")
    func unsupportedQoS() {
        var decoder = MQTT311StreamDecoder()
        let qosOnePublish = Data([0x32, 0x04, 0x00, 0x01, 0x74, 0x00])

        do {
            _ = try decoder.append(qosOnePublish)
            Issue.record("Expected QoS 1 to be rejected")
        } catch let error as MQTT311Codec.CodecError {
            #expect(error == .unsupportedQoS(1))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}

@Suite("MQTT Broker Endpoint")
struct MQTTBrokerEndpointTests {
    @Test("Empty addresses use the Meshtastic broker and TLS-specific port")
    func defaults() throws {
        #expect(
            try MQTTBrokerEndpoint.parse("", useTLS: false)
                == MQTTBrokerEndpoint(host: "mqtt.meshtastic.org", port: 1883)
        )
        #expect(
            try MQTTBrokerEndpoint.parse("", useTLS: true)
                == MQTTBrokerEndpoint(host: "mqtt.meshtastic.org", port: 8883)
        )
    }

    @Test("Host, URL and bracketed IPv6 ports are parsed")
    func explicitEndpoints() throws {
        #expect(
            try MQTTBrokerEndpoint.parse("broker.example:1884", useTLS: false)
                == MQTTBrokerEndpoint(host: "broker.example", port: 1884)
        )
        #expect(
            try MQTTBrokerEndpoint.parse("mqtts://broker.example:8884", useTLS: true)
                == MQTTBrokerEndpoint(host: "broker.example", port: 8884)
        )
        #expect(
            try MQTTBrokerEndpoint.parse("[2001:db8::1]:1883", useTLS: false)
                == MQTTBrokerEndpoint(host: "2001:db8::1", port: 1883)
        )
    }

    @Test("Meshtastic config maps to root subscription and stable client ID")
    func meshtasticConfigurationBridge() throws {
        var config = Meshtastic_ModuleConfig.MQTTConfig()
        config.address = "broker.example:1884"
        config.root = "/mesh/hessen/"
        config.username = "user"
        config.password = "secret"

        let proxy = try MqttProxyService.Configuration(
            mqttConfig: config,
            myNodeID: 0x1A2B3C4D,
            appVersion: "1.2.3"
        )

        #expect(proxy.subscriptionTopic == "mesh/hessen/#")
        #expect(proxy.clientID == "meshhessenclient-1.2.3-!1a2b3c4d")
        #expect(proxy.host == "broker.example")
        #expect(proxy.port == 1884)
    }
}
