//
//  WDGWarsPendingView.swift
//
//  Nodes waiting for upload, with a button to send them now.
//

import SwiftUI

struct WDGWarsPendingView: View {
	@State private var pending: [WDGWarsRecord] = []
	@State private var uploading = false
	@State private var result = ""

	private static let dateStyle: Date.FormatStyle = .dateTime.day().month().hour().minute()

	var body: some View {
		List {
			Section {
				Button {
					Task { await uploadNow() }
				} label: {
					Label("Upload now", systemImage: "icloud.and.arrow.up")
				}
				.disabled(pending.isEmpty || uploading)
				if uploading {
					ProgressView()
				} else if !result.isEmpty {
					Text(result).font(.caption).foregroundStyle(.secondary)
				}
			}
			Section("Waiting to upload (\(pending.count))") {
				if pending.isEmpty {
					Text("Nothing waiting.").foregroundStyle(.secondary)
				}
				ForEach(pending, id: \.nodeId) { r in
					VStack(alignment: .leading, spacing: 2) {
						Text(r.name)
						Text("\(r.nodeId) · \(String(format: "%.5f, %.5f", r.lat, r.lon))")
							.font(.caption).foregroundStyle(.secondary)
						Text(r.firstSeen.formatted(Self.dateStyle)
							 + (r.rssi.map { " · \($0) dBm" } ?? "")
							 + (r.pathHops.map { " · \($0) hops" } ?? ""))
							.font(.caption2).foregroundStyle(.secondary)
					}
				}
			}
		}
		.navigationTitle("Waiting to upload")
		.navigationBarTitleDisplayMode(.inline)
		.task { pending = await WDGWarsUploader.shared.pendingNodes }
		.refreshable { pending = await WDGWarsUploader.shared.pendingNodes }
	}

	private func uploadNow() async {
		uploading = true
		await WDGWarsUploader.shared.flush()
		result = await WDGWarsUploader.shared.lastResult
		pending = await WDGWarsUploader.shared.pendingNodes
		uploading = false
	}
}
