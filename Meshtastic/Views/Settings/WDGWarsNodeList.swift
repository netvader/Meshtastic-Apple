//
//  WDGWarsNodeList.swift
//
//  One list of nodes with a filter: found, with GPS, known to WDGWars, new, waiting and uploaded.
//

import SwiftUI
import SwiftData

/// Switches that can be combined; a node has to pass every switch that is on.
struct WDGWarsNodeFilters: Equatable {
	/// Only nodes found since the radio was connected.
	var session = false
	var withGPS = false
	var known = false
	var new = false
	var waiting = false
	var uploaded = false

	var isActive: Bool { session || withGPS || known || new || waiting || uploaded }

	func matches(_ r: WDGWarsNodeRow) -> Bool {
		// Nodes that are only in the upload lists show up when those switches are on.
		guard r.inDatabase || waiting || uploaded else { return false }
		if session && !r.inSession { return false }
		if withGPS && !r.hasGPS { return false }
		if known && !r.known { return false }
		if new && !(r.hasGPS && !r.known) { return false }
		if waiting && !r.queued { return false }
		if uploaded && !r.uploaded { return false }
		return true
	}
}

enum WDGWarsSort: String, CaseIterable, Identifiable {
	case date, name

	var id: String { rawValue }

	var title: String { self == .date ? "Date" : "Name" }
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
	/// New with a GPS position since the radio was connected.
	var inSession = false
	/// What would be sent for this node, if it passes the upload filters.
	var uploadable: WDGWarsRecord?
}

/// All nodes with their status, worked out once from the node database and the upload lists.
struct WDGWarsNodeIndex {
	var rows: [WDGWarsNodeRow] = []

	/// How many nodes pass one switch on its own (shown next to the switch).
	func count(_ filters: WDGWarsNodeFilters) -> Int { rows.reduce(0) { $0 + (filters.matches($1) ? 1 : 0) } }

	var waitingCount: Int { rows.reduce(0) { $0 + ($1.queued ? 1 : 0) } }

	/// New nodes that pass the upload filters but are not in the queue yet.
	var addable: [WDGWarsRecord] {
		rows.filter { $0.inDatabase && $0.hasGPS && !$0.known && !$0.queued }.compactMap(\.uploadable)
	}

	@MainActor
	static func build(context: ModelContext) async -> WDGWarsNodeIndex {
		let uploader = WDGWarsUploader.shared
		let sent = await uploader.uploadedNodes
		let queue = await uploader.pendingNodes
		let sessionFound = Set(await uploader.activity().found)
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
				known: known.contains(id), queued: queuedIDs.contains(id), uploaded: sentIDs.contains(id),
				inSession: sessionFound.contains(id))
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
				uploaded: sentIDs.contains(record.nodeId), inSession: sessionFound.contains(record.nodeId))
		}
		let sorted = byID.values.sorted { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
		return WDGWarsNodeIndex(rows: sorted)
	}
}

struct WDGWarsNodeListView: View {
	@Environment(\.modelContext) private var context
	@EnvironmentObject var router: Router
	@State private var index = WDGWarsNodeIndex()
	@State private var filters = WDGWarsNodeFilters()
	@AppStorage("wdgwarsSort") private var sort: WDGWarsSort = .date
	@AppStorage("wdgwarsSortReversed") private var reversed = false
	@State private var search = ""
	@State private var working = false
	@State private var message: String?

	private static let dateStyle: Date.FormatStyle = .dateTime.day().month().hour().minute()

	private var shown: [WDGWarsNodeRow] {
		let text = search.trimmingCharacters(in: .whitespaces).lowercased()
		var list = index.rows.filter { row in
			filters.matches(row)
				&& (text.isEmpty || row.name.lowercased().contains(text) || row.id.contains(text))
		}
		switch sort {
		case .date:
			list.sort { ($0.time ?? .distantPast) > ($1.time ?? .distantPast) }
		case .name:
			list.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
		}
		return reversed ? list.reversed() : list
	}

	var body: some View {
		let rows = shown
		List {
			if rows.isEmpty {
				Text("No nodes.").foregroundStyle(.secondary)
			}
			ForEach(rows.prefix(300)) { row in
				rowView(row)
			}
			if rows.count > 300 {
				Text("Showing the first 300.").font(.caption).foregroundStyle(.secondary)
			}
		}
		.listStyle(.plain)
		.navigationTitle(String.localizedStringWithFormat("Nodes (%@)".localized, String(rows.count)))
		.navigationBarTitleDisplayMode(.inline)
		.searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Find a node")
		.autocorrectionDisabled(true)
		.safeAreaInset(edge: .bottom, alignment: .trailing) { bottomBar }
		.alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
			Button("OK") { }
		}
		.task { await reload() }
		.refreshable { await reload() }
	}

	// MARK: Filter button

	private var bottomBar: some View {
		HStack {
			Spacer()
			if filters.isActive {
				Button {
					withAnimation { filters = WDGWarsNodeFilters() }
				} label: {
					Image(systemName: "arrow.counterclockwise.circle").padding(.vertical, 5)
				}
				.tint(Color(UIColor.secondarySystemBackground))
				.foregroundColor(.accentColor)
				.buttonStyle(.borderedProminent)
				.accessibilityLabel("Reset node filters")
			}
			Menu {
				filterToggles
				Section("Sort by") {
					Picker("Sort by", selection: $sort) {
						ForEach(WDGWarsSort.allCases) { Text($0.title).tag($0) }
					}
					Toggle("Reverse order", isOn: $reversed)
				}
				Section("Upload") {
					Button {
						Task { await uploadNow() }
					} label: {
						Label("Upload now (\(index.waitingCount) waiting)", systemImage: "icloud.and.arrow.up")
					}
					.disabled(index.waitingCount == 0 || working)
					Button {
						Task { await addToQueue() }
					} label: {
						Label("Add \(index.addable.count) new nodes to the queue", systemImage: "plus.circle")
					}
					.disabled(index.addable.isEmpty || working)
				}
			} label: {
				Image(systemName: filters.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
					.padding(.vertical, 5)
			}
			.tint(Color(UIColor.secondarySystemBackground))
			.foregroundColor(.accentColor)
			.buttonStyle(.borderedProminent)
			.accessibilityLabel("Show node filters")
		}
		.controlSize(.regular)
		.padding(5)
	}

	@ViewBuilder private var filterToggles: some View {
		Section("Show only") {
			Toggle("This connection (\(count(\.session)))", isOn: $filters.session)
			Toggle("With GPS position (\(count(\.withGPS)))", isOn: $filters.withGPS)
			// Known and new exclude each other.
			Toggle("Known to WDGWars (\(count(\.known)))", isOn: Binding(
				get: { filters.known },
				set: { filters.known = $0; if $0 { filters.new = false } }))
			Toggle("New (\(count(\.new)))", isOn: Binding(
				get: { filters.new },
				set: { filters.new = $0; if $0 { filters.known = false } }))
			Toggle("Waiting to upload (\(count(\.waiting)))", isOn: $filters.waiting)
			Toggle("Uploaded (\(count(\.uploaded)))", isOn: $filters.uploaded)
		}
	}

	private func count(_ flag: WritableKeyPath<WDGWarsNodeFilters, Bool>) -> Int {
		var single = WDGWarsNodeFilters()
		single[keyPath: flag] = true
		return index.count(single)
	}

	// MARK: Rows

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

	// MARK: Actions

	private func reload() async {
		index = await WDGWarsNodeIndex.build(context: context)
	}

	private func uploadNow() async {
		working = true
		await WDGWarsUploader.shared.flush()
		message = await WDGWarsUploader.shared.lastResult
		await reload()
		working = false
	}

	private func addToQueue() async {
		working = true
		let added = await WDGWarsUploader.shared.enqueue(index.addable)
		message = "\(added) nodes added to the queue."
		await reload()
		working = false
	}
}
