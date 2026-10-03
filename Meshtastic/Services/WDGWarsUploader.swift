//
//  WDGWarsUploader.swift
//
//  Uploads heard Meshtastic nodes to wdgwars.pl, following the protocol of
//  willryker/meshtastic-to-wdgwars (ratatoskr).
//

import Foundation
import CryptoKit
import OSLog

struct WDGWarsRecord: Codable, Equatable {
	/// 8 lowercase hex characters, no "!" (what the server stores).
	var nodeId: String
	var nodeType: String?
	var name: String
	var lat: Double
	var lon: Double
	var rssi: Int?
	var firstSeen: Date
	var pathHops: Int?
}

actor WDGWarsUploader {
	static let shared = WDGWarsUploader()

	static let enabledKey = "wdgwarsAutoUpload"
	private static let queueKey = "wdgwarsQueue"
	private static let sentKey = "wdgwarsSent"

	private static let roleNames: [Int32: String] = [
		0: "CLIENT", 1: "CLIENT_MUTE", 2: "ROUTER", 3: "ROUTER_CLIENT", 4: "REPEATER", 5: "TRACKER",
		6: "SENSOR", 7: "TAK", 8: "CLIENT_HIDDEN", 9: "LOST_AND_FOUND", 10: "TAK_TRACKER",
		11: "ROUTER_LATE", 12: "CLIENT_BASE"
	]

	private let endpoint = URL(string: "https://wdgwars.pl/api/upload/")!
	private let batchSize = 1000
	private let flushInterval: TimeInterval = 60
	/// A node is re-sent only after it moved this far or after a day.
	private let resendDistance: Double = 100
	private let resendAge: TimeInterval = 24 * 3600

	private var queue: [WDGWarsRecord]
	private var lastSent: [String: WDGWarsRecord]
	private var flushTask: Task<Void, Never>?

	private(set) var lastResult: String = ""

	init() {
		queue = (Self.load([WDGWarsRecord].self, key: Self.queueKey) ?? []).map(Self.normalized)
		let sent = (Self.load([String: WDGWarsRecord].self, key: Self.sentKey) ?? [:]).values.map(Self.normalized)
		lastSent = Dictionary(sent.map { ($0.nodeId, $0) }, uniquingKeysWith: { $1 })
	}

	// MARK: Settings

	nonisolated var isEnabled: Bool {
		UserDefaults.standard.bool(forKey: Self.enabledKey) && !apiKey.isEmpty
	}

	nonisolated var apiKey: String {
		WDGWarsKeychain.load()
	}

	// MARK: Collecting

	/// Called for every position packet. Applies the same filters as ratatoskr:
	/// needs GPS and a direct radio measurement, nothing that came via MQTT.
	func record(nodeNum: Int64, name: String?, role: Int32?, latitudeI: Int32, longitudeI: Int32,
				rssi: Int32, snr: Float, viaMqtt: Bool, hops: Int?, time: Date) {
		guard isEnabled, !viaMqtt else { return }
		guard latitudeI != Int32.max, longitudeI != Int32.max, latitudeI != 0 || longitudeI != 0 else { return }
		guard rssi != 0 || snr != 0 else { return }

		let id = String(format: "%08x", UInt32(truncatingIfNeeded: nodeNum))
		let rec = WDGWarsRecord(
			nodeId: id,
			nodeType: role.flatMap { Self.roleNames[$0] } ?? "CLIENT",
			name: name ?? id,
			lat: Double(latitudeI) / 1e7,
			lon: Double(longitudeI) / 1e7,
			rssi: rssi != 0 ? Int(rssi) : nil,
			firstSeen: time,
			pathHops: hops
		)
		if let prev = lastSent[id],
		   time.timeIntervalSince(prev.firstSeen) < resendAge,
		   Self.distance(prev, rec) < resendDistance {
			return
		}
		queue.removeAll { $0.nodeId == id }
		queue.append(rec)
		Self.save(queue, key: Self.queueKey)
		scheduleFlush()
	}

	private func scheduleFlush() {
		guard flushTask == nil else { return }
		let delay = queue.count >= batchSize ? 0 : flushInterval
		flushTask = Task { [weak self] in
			try? await Task.sleep(for: .seconds(delay))
			await self?.flush()
		}
	}

	// MARK: Uploading

	func flush() async {
		flushTask = nil
		guard isEnabled, !queue.isEmpty else { return }
		let key = apiKey
		while !queue.isEmpty {
			let batch = Array(queue.prefix(batchSize))
			do {
				let (status, body) = try await post(batch, apiKey: key)
				guard status == 200 else {
					lastResult = "HTTP \(status): \(body.prefix(120))"
					Logger.services.error("WDGWars upload failed: \(self.lastResult, privacy: .public)")
					scheduleFlush()
					return
				}
				queue.removeFirst(batch.count)
				for r in batch { lastSent[r.nodeId] = r }
				Self.save(queue, key: Self.queueKey)
				Self.save(lastSent, key: Self.sentKey)
				lastResult = "Uploaded \(batch.count) nodes"
				Logger.services.info("WDGWars: uploaded \(batch.count, privacy: .public) nodes")
			} catch {
				lastResult = error.localizedDescription
				Logger.services.error("WDGWars upload error: \(error.localizedDescription, privacy: .public)")
				scheduleFlush()
				return
			}
		}
	}

	var pendingCount: Int { queue.count }

	var pendingNodes: [WDGWarsRecord] { queue.sorted { $0.firstSeen > $1.firstSeen } }

	var uploadedNodes: [WDGWarsRecord] { lastSent.values.sorted { $0.firstSeen > $1.firstSeen } }

	/// Authenticated GET on the WDGWars API, e.g. `me`, `upload-history`, `meshcore`.
	func get(_ path: String) async throws -> (Int, Data) {
		var request = URLRequest(url: URL(string: "https://wdgwars.pl/api/\(path)")!)
		request.timeoutInterval = 30
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
		request.setValue("meshtastic-ios-wdgwars/1.0", forHTTPHeaderField: "User-Agent")
		let (data, response) = try await URLSession.shared.data(for: request)
		return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
	}

	private func post(_ records: [WDGWarsRecord], apiKey: String) async throws -> (Int, String) {
		var request = URLRequest(url: endpoint)
		request.httpMethod = "POST"
		request.timeoutInterval = 30
		request.httpBody = try Self.envelope(records: records, apiKey: apiKey)
		request.setValue("application/json", forHTTPHeaderField: "Content-Type")
		request.setValue("application/json", forHTTPHeaderField: "Accept")
		request.setValue(apiKey, forHTTPHeaderField: "X-API-Key")
		request.setValue("meshtastic-ios-wdgwars/1.0", forHTTPHeaderField: "User-Agent")
		let (data, response) = try await URLSession.shared.data(for: request)
		let status = (response as? HTTPURLResponse)?.statusCode ?? 0
		return (status, String(decoding: data, as: UTF8.self))
	}

	// MARK: Envelope

	/// `{"data": base64(payload), "nonce": hex, "sig": hmac_sha256(apiKey, nonce + data)}`
	nonisolated static func envelope(records: [WDGWarsRecord], apiKey: String, nonce: String? = nil) throws -> Data {
		let iso = ISO8601DateFormatter()
		iso.formatOptions = [.withInternetDateTime]
		let nodes: [[String: Any]] = records.map { r in
			var d: [String: Any] = [
				"node_id": r.nodeId,
				"node_type": r.nodeType ?? "CLIENT",
				"name": r.name,
				"lat": r.lat,
				"lon": r.lon,
				"first_seen": iso.string(from: r.firstSeen),
				"type": "MESHTASTIC",
				"network": "meshtastic"
			]
			if let rssi = r.rssi { d["rssi"] = rssi }
			if let hops = r.pathHops { d["path_hops"] = hops }
			return d
		}
		let payload: [String: Any] = ["networks": [], "aircraft": [], "meshcore_nodes": nodes]
		let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
		let dataB64 = json.base64EncodedString()
		let nonce = nonce ?? (0..<8).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
		let mac = HMAC<SHA256>.authenticationCode(
			for: Data((nonce + dataB64).utf8),
			using: SymmetricKey(data: Data(apiKey.utf8))
		)
		let sig = mac.map { String(format: "%02x", $0) }.joined()
		return try JSONSerialization.data(withJSONObject: ["data": dataB64, "nonce": nonce, "sig": sig])
	}

	// MARK: Helpers

	private static func normalized(_ r: WDGWarsRecord) -> WDGWarsRecord {
		var r = r
		r.nodeId = r.nodeId.trimmingCharacters(in: CharacterSet(charactersIn: "!")).lowercased()
		return r
	}

	private static func distance(_ a: WDGWarsRecord, _ b: WDGWarsRecord) -> Double {
		let dLat = (a.lat - b.lat) * 111_320
		let dLon = (a.lon - b.lon) * 111_320 * cos(a.lat * .pi / 180)
		return (dLat * dLat + dLon * dLon).squareRoot()
	}

	private static func load<T: Decodable>(_ type: T.Type, key: String) -> T? {
		guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
		let dec = JSONDecoder()
		dec.dateDecodingStrategy = .secondsSince1970
		return try? dec.decode(type, from: data)
	}

	private static func save<T: Encodable>(_ value: T, key: String) {
		let enc = JSONEncoder()
		enc.dateEncodingStrategy = .secondsSince1970
		if let data = try? enc.encode(value) { UserDefaults.standard.set(data, forKey: key) }
	}
}
