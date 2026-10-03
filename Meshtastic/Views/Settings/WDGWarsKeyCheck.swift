//
//  WDGWarsKeyCheck.swift
//
//  Result of checking the WDGWars API key with GET /api/me.
//

import SwiftUI

struct WDGWarsKeyCheck {
	var valid: Bool
	var title: String
	var lines: [String]

	static func run() async -> WDGWarsKeyCheck {
		do {
			let (status, data) = try await WDGWarsUploader.shared.get("me")
			switch status {
			case 200:
				let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
				var lines: [String] = []
				if let user = obj?["username"] as? String {
					let country = (obj?["country"] as? String).map { " (\($0))" } ?? ""
					lines.append("Account: \(user)\(country)")
				}
				if let mesh = obj?["mesh"] { lines.append("Mesh nodes: \(mesh)") }
				return WDGWarsKeyCheck(valid: true, title: "Key is valid", lines: lines)
			case 401, 403:
				return WDGWarsKeyCheck(valid: false, title: "Key was rejected",
									   lines: ["Check the key in your WDGWars profile."])
			default:
				return WDGWarsKeyCheck(valid: false, title: "Server answered with HTTP \(status)", lines: [])
			}
		} catch {
			return WDGWarsKeyCheck(valid: false, title: "No connection",
								   lines: [error.localizedDescription])
		}
	}
}

struct WDGWarsKeyCheckCard: View {
	let check: WDGWarsKeyCheck

	var body: some View {
		HStack(alignment: .top, spacing: 12) {
			Image(systemName: check.valid ? "checkmark.circle.fill" : "xmark.octagon.fill")
				.font(.title2)
				.foregroundStyle(check.valid ? .green : .red)
			VStack(alignment: .leading, spacing: 2) {
				Text(check.title).font(.headline)
				ForEach(check.lines, id: \.self) { line in
					Text(line).font(.subheadline).foregroundStyle(.secondary)
				}
			}
		}
		.padding(.vertical, 4)
	}
}
