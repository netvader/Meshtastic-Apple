//
//  WDGWarsNodesView.swift
//
//  Lists the nodes this app uploaded to WDGWars most recently.
//

import SwiftUI

struct WDGWarsNodesView: View {
	@State private var uploaded: [WDGWarsRecord] = []

	private static let dateStyle: Date.FormatStyle = .dateTime.day().month().hour().minute()

	var body: some View {
		List {
			if uploaded.isEmpty {
				Text("No nodes uploaded yet.").foregroundStyle(.secondary)
			}
			ForEach(uploaded.prefix(50), id: \.nodeId) { row($0) }
		}
		.navigationTitle("Last uploaded nodes")
		.navigationBarTitleDisplayMode(.inline)
		.task { uploaded = await WDGWarsUploader.shared.uploadedNodes }
		.refreshable { uploaded = await WDGWarsUploader.shared.uploadedNodes }
	}

	private func row(_ r: WDGWarsRecord) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			Text(r.name).font(.body)
			Text("\(r.nodeId) · \(String(format: "%.5f, %.5f", r.lat, r.lon))")
				.font(.caption).foregroundStyle(.secondary)
			Text(r.firstSeen.formatted(Self.dateStyle)
				 + (r.rssi.map { " · \($0) dBm" } ?? "")
				 + (r.pathHops.map { " · \($0) hops" } ?? ""))
				.font(.caption2).foregroundStyle(.secondary)
		}
	}
}
