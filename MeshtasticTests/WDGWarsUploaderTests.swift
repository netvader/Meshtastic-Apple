import Foundation
import Testing
@testable import Meshtastic

struct WDGWarsUploaderTests {
	@Test func envelopeSignatureMatchesReference() throws {
		let rec = WDGWarsRecord(nodeId: "12345678", nodeType: "ROUTER", name: "Test", lat: 50.1, lon: 8.6,
								rssi: -90, firstSeen: Date(timeIntervalSince1970: 1_700_000_000), pathHops: 1)
		let data = try WDGWarsUploader.envelope(records: [rec], apiKey: "secret", nonce: "0011223344556677")
		let obj = try #require(JSONSerialization.jsonObject(with: data) as? [String: String])
		#expect(obj["nonce"] == "0011223344556677")
		let payload = try #require(Data(base64Encoded: obj["data"]!))
		let parsed = try #require(JSONSerialization.jsonObject(with: payload) as? [String: Any])
		let nodes = try #require(parsed["meshcore_nodes"] as? [[String: Any]])
		#expect(nodes.first?["network"] as? String == "meshtastic")
		#expect(nodes.first?["public_key"] == nil)
		#expect(nodes.first?["node_id"] as? String == "12345678")
		#expect(nodes.first?["node_type"] as? String == "ROUTER")
		#expect(obj["sig"]?.count == 64)
	}
}
