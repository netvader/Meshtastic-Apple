//
//  WDGWarsNodeList.swift
//
//  One list of nodes with a filter: found, with GPS, known to WDGWars, new, waiting and uploaded.
//

import SwiftUI
import SwiftData

enum WDGWarsFilter: String, CaseIterable, Identifiable {
	case found, withGPS, known, new, waiting, uploaded

	var id: String { rawValue }

	var title: String {
		switch self {
		case .found: return "Found nodes"
		case .withGPS: return "With GPS position"
		case .known: return "Known to WDGWars"
		case .new: return "New"
		case .waiting: return "Waiting to upload"
		case .uploaded: return "Uploaded"
		}
	}

	var icon: String {
		switch self {
		case .found: return "antenna.radiowaves.left.and.right"
		case .withGPS: return "location.fill"
		case .known: return "checkmark.circle"
		case .new: return "sparkles"
		case .waiting: return "tray.and.arrow.up"
		case .uploaded: return "icloud.and.arrow.up"
		}
	}
}

struct WDGWarsNodeRow: Identifiable {
	var id: String
	var name: String
	/// Node number, set for nodes in the app's database (needed to show them on the map).
	var num: Int64?
	var lat: Double?
	var lon: Double?
	var rssi: Int?
	var hops: Int?
	var time: Date?
	/// Stored in the app's node database (as opposed to only being in the upload lists).
	var inDatabase: Bool
	var hasGPS: Bool
	var known: Bool
	var queued: Bool
	var uploaded: Bool
	/// What would be sent for this node, if it passes the upload filters.
	var uploadable: WDGWarsRecord?

	func matches(_ filter: WDGWarsFilter) -> Bool {
		switch filter {
		case .found: return inDatabase
		case .withGPS: return inDatabase && hasGPS
		case .known: return inDatabase && hasGPS && known
		case .new: return inDatabase && hasGPS && !known
		case .waiting: return queued
		case .uploaded: return uploaded
		}
	}
}

/// All nodes with their status, worked out once from the node database and the upload lists.
struct WDGWarsNodeIndex {
	var rows: [WDGWarsNodeRow] = []

	func rows(for filter: WDGWarsFilter) -> [WDGWarsNodeRow] { rows.filter { $0.matches(filter) } }
	func count(for filter: WDGWarsFilter) -> Int { rows.reduce(0) { $0 + ($1.matches(filter) ? 1 : 0) } }

	/// New nodes that pass the upload filters but are not in the queue yet.
	var addable: [WDGWarsRecord] {
		rows.filter { $0.matches(.new) && !$0.queued }.compactMap(\.uploadable)
	}

	@MainActor
	static func build(context: ModelContext) async -> WDGWarsNodeIndex {
		let uploader = WDGWarsUploader.shared
		let sent = await uploader.uploadedNodes
		let queue = await uploader.pendingNodes
		let sentIDs = Set(sent.map(\.nodeId))
		let queuedIDs = Set(queue.map(\.nodeId))
		let known = (await uploader.serverNodeIDs() ?? []).union(sentIDs)
		let nodes = (try? context.fetch(FetchDescriptor<NodeInfoEntity>())) ?? []

		var byID: [String: WDGWarsNodeRow] = [:]
		for node in nodes where node.myInfo == nil {
			let id = WDGWarsUploader.nodeID(node.num)
			let name = node.user?.longName ?? node.user?.shortName ?? id
			let pos = node.latestPosition
			let hasGPS = pos.map { ($0.latitudeI != 0 || $0.longitudeI != 0)
				&& $0.latitudeI != Int32.max && $0.longitudeI != Int32.max } ?? false
			var row = WDGWarsNodeRow(
				id: id, name: name, num: node.num, time: pos?.time ?? node.lastHeard, inDatabase: true, hasGPS: hasGPS,
				known: known.contains(id), queued: queuedIDs.contains(id), uploaded: sentIDs.contains(id))
			if hasGPS, let pos {
				row.lat = Double(pos.latitudeI) / 1e7
				row.lon = Double(pos.longitudeI) / 1e7
				let rssi = pos.rssi != 0 ? pos.rssi : node.rssi
				row.rssi = rssi != 0 ? Int(rssi) : nil
				row.hops = node.hopsAway > 0 ? Int(node.hopsAway) : nil
				row.uploadable = WDGWarsUploader.makeRecord(
					nodeNum: node.num, name: node.user?.longName ?? node.user?.shortName, role: node.user?.role,
					latitudeI: pos.latitudeI, longitudeI: pos.longitudeI,
					rssi: rssi, snr: pos.snr != 0 ? pos.snr : node.snr,
					viaMqtt: node.viaMqtt, hops: row.hops, time: row.time ?? Date())
			}
			byID[id] = row
		}
		// Nodes that are only in the upload lists (for example deleted from the app's database).
		for record in queue + sent where byID[record.nodeId] == nil {
			byID[record.nodeId] = WDGWarsNodeRow(
				id: record.nodeId, name: record.name, lat: record.lat, lon: record.lon, rssi: record.rssi,
				hops: record.pathHops, time: record.firstSeen, inDatabase: false, hasGPS: true,
				known: known.contains(record.nodeId), queued: queuedIDs.contains(record.nodeId),
				uploaded: sentIDs.contains(record.nodeId))
		}
		let sorted = byID.values.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
		return WDGWarsNodeIndex(rows: sorted)
	}
}

struct WDGWarsNodeListView: View {
	@Environment(\.modelContext) private var context
	@EnvironmentObject var router: Router
	@State var filter: WDGWarsFilter
	@State private var index = WDGWarsNodeIndex()
	@State private var working = false
	@State private var result = ""

	private static let dateStyle: Date.FormatStyle = .dateTime.day().month().hour().minute()

	var body: some View {
		let rows = index.rows(for: filter)
		List {
			Section {
				Picker("Show", selection: $filter) {
					ForEach(WDGWarsFilter.allCases) { f in
						Label("\(f.title) (\(index.count(for: f)))", systemImage: f.icon).tag(f)
					}
				}
				.pickerStyle(.menu)
				actionRow
			} footer: {
				Text("Found: nodes stored in this app, without your own radio. Known: already uploaded by this app or listed by WDGWars. New: with GPS but not known yet. Tap a node to show it on the map.")
			}
			Section("\(filter.title) (\(rows.count))") {
				if rows.isEmpty {
					Text("No nodes.").foregroundStyle(.secondary)
				}
				ForEach(rows.prefix(300)) { row in
					rowView(row)
				}
				if rows.count > 300 {
					Text("Showing the 300 most recent.").font(.caption).foregroundStyle(.secondary)
				}
			}
		}
		.navigationTitle(filter.title)
		.navigationBarTitleDisplayMode(.inline)
		.task { await reload() }
		.refreshable { await reload() }
	}

	/// Upload now for the waiting list, adding to the queue for the new list.
	@ViewBuilder private var actionRow: some View {
		if filter == .waiting {
			Button {
				Task { await uploadNow() }
			} label: {
				Label("Upload now", systemImage: "icloud.and.arrow.up")
			}
			.disabled(index.count(for: .waiting) == 0 || working)
		} else if filter == .new {
			Button {
				Task { await addToQueue() }
			} label: {
				Label("Add \(index.addable.count) new nodes to the queue", systemImage: "plus.circle")
			}
			.disabled(index.addable.isEmpty || working)
		}
		if working {
			ProgressView()
		} else if !result.isEmpty, filter == .waiting || filter == .new {
			Text(result).font(.caption).foregroundStyle(.secondary)
		}
	}

	@ViewBuilder
	private func rowView(_ r: WDGWarsNodeRow) -> some View {
		if let num = r.num, r.hasGPS {
			Button {
				showOnMap(num)
			} label: {
				rowContent(r, onMap: true)
			}
			.buttonStyle(.plain)
		} else {
			rowContent(r, onMap: false)
		}
	}

	private func rowContent(_ r: WDGWarsNodeRow, onMap: Bool) -> some View {
		VStack(alignment: .leading, spacing: 2) {
			HStack {
				Text(r.name).font(.body)
				Spacer()
				if r.known { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
				if r.queued { Image(systemName: "clock").foregroundStyle(.orange) }
				if r.uploaded { Image(systemName: "icloud.fill").foregroundStyle(.blue) }
				if onMap { Image(systemName: "map").foregroundStyle(.blue) }
			}
			if let lat = r.lat, let lon = r.lon {
				Label(String(format: "%.5f, %.5f", lat, lon), systemImage: "location.fill")
					.font(.subheadline).foregroundStyle(.blue)
			} else {
				Label("No GPS position", systemImage: "location.slash")
					.font(.subheadline).foregroundStyle(.secondary)
			}
			Text(r.id + " · " + (r.time?.formatted(Self.dateStyle) ?? "–")
				 + (r.rssi.map { " · \($0) dBm" } ?? "")
				 + (r.hops.map { " · \($0) hops" } ?? ""))
				.font(.caption).foregroundStyle(.secondary)
		}
	}

	/// Opens the node on the app's map tab.
	private func showOnMap(_ num: Int64) {
		router.selectedTab = .map
		router.mapState = .selectedNode(num)
	}

	private func reload() async {
		index = await WDGWarsNodeIndex.build(context: context)
	}

	private func uploadNow() async {
		working = true
		await WDGWarsUploader.shared.flush()
		result = await WDGWarsUploader.shared.lastResult
		await reload()
		working = false
	}

	private func addToQueue() async {
		working = true
		let added = await WDGWarsUploader.shared.enqueue(index.addable)
		result = "\(added) nodes added to the queue."
		await reload()
		working = false
	}
}
