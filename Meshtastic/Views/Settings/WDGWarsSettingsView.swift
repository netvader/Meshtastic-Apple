//
//  WDGWarsSettingsView.swift
//
//  WDGWars upload: account (API key), automatic upload and the node lists.
//

import SwiftUI
import SwiftData

/// Counts of the nodes in the app's database, compared with what WDGWars already knows.
struct WDGWarsNodeStats {
	var found = 0
	var withGPS = 0
	var known = 0
	var new = 0
	var uploadable: [WDGWarsRecord] = []
	var notQueued = 0
}

struct WDGWarsSettingsView: View {
	@Environment(\.modelContext) private var context
	@State private var stats = WDGWarsNodeStats()
	@State private var serverIDs: Set<String>?
	@State private var scanning = false
	@AppStorage(WDGWarsUploader.enabledKey) private var autoUpload = false
	@AppStorage("wdgwarsKeyLocked") private var keyLocked = false
	@State private var apiKey = WDGWarsKeychain.load()
	@State private var keyCheck: WDGWarsKeyCheck?
	@State private var checkingKey = false
	@State private var confirmUnlock = false
	@State private var pendingCount = 0
	@State private var uploadedCount = 0

	var body: some View {
		List {
			accountSection
			overviewSection
			uploadSection
			nodesSection
		}
		.navigationTitle("WDGWars Upload")
		.navigationBarTitleDisplayMode(.inline)
		.task { await refresh() }
		.refreshable { await refresh() }
	}

	// MARK: Account

	private var accountSection: some View {
		Section("Account") {
			if keyLocked && !apiKey.isEmpty {
				HStack {
					Label("API key", systemImage: "lock.fill")
					Spacer()
					Text("••••" + apiKey.suffix(4))
						.foregroundStyle(.secondary)
						.monospaced()
				}
				Button("Change key", role: .destructive) {
					confirmUnlock = true
				}
				.confirmationDialog("Unlock the API key to change it?", isPresented: $confirmUnlock, titleVisibility: .visible) {
					Button("Unlock", role: .destructive) {
						keyLocked = false
						keyCheck = nil
					}
					Button("Cancel", role: .cancel) { }
				}
			} else {
				SecureField("API key", text: $apiKey)
					.textInputAutocapitalization(.never)
					.autocorrectionDisabled()
					.onChange(of: apiKey) { _, newValue in
						WDGWarsKeychain.save(newValue)
					}
			}
			Button {
				Task {
					checkingKey = true
					keyCheck = await WDGWarsKeyCheck.run()
					checkingKey = false
					// A valid key is locked so it is not overwritten by accident.
					if keyCheck?.valid == true { keyLocked = true }
				}
			} label: {
				Label("Test key", systemImage: "checkmark.shield")
			}
			.disabled(apiKey.isEmpty || checkingKey)
			if checkingKey {
				ProgressView()
			} else if let keyCheck {
				WDGWarsKeyCheckCard(check: keyCheck)
			}
		}
	}

	// MARK: Automatic upload

	private var uploadSection: some View {
		Section {
			Toggle("Auto upload heard nodes", isOn: $autoUpload)
				.disabled(apiKey.isEmpty)
		} header: {
			Text("Upload")
		} footer: {
			Text("Nodes with a GPS position and a direct radio reception are uploaded in the background. MQTT-only nodes and your own radio are skipped.")
		}
	}

	// MARK: Nodes

	private var nodesSection: some View {
		Section("Nodes") {
			NavigationLink {
				WDGWarsPendingView()
			} label: {
				LabeledContent {
					Text("\(pendingCount)")
				} label: {
					Label("Waiting to upload", systemImage: "tray.and.arrow.up")
				}
			}
			NavigationLink {
				WDGWarsNodesView()
			} label: {
				LabeledContent {
					Text("\(uploadedCount)")
				} label: {
					Label("Last uploaded nodes", systemImage: "list.bullet.rectangle")
				}
			}
		}
	}

	// MARK: Overview

	private var overviewSection: some View {
		Section {
			LabeledContent("Found nodes", value: "\(stats.found)")
			LabeledContent("With GPS position", value: "\(stats.withGPS)")
			LabeledContent("Known to WDGWars", value: "\(stats.known)")
			LabeledContent("New", value: "\(stats.new)")
			if stats.notQueued > 0 {
				Button {
					Task { await queueNewNodes() }
				} label: {
					Label("Add \(stats.notQueued) new nodes to the queue", systemImage: "plus.circle")
				}
				.disabled(scanning)
			}
		} header: {
			Text("Overview")
		} footer: {
			Text(overviewFooter)
		}
	}

	private var overviewFooter: String {
		var text = "Found: nodes stored in this app, without your own radio. Known: already uploaded by this app or listed by WDGWars. New nodes that were heard directly over radio can be added to the queue; nodes that only arrived via MQTT cannot be uploaded."
		if serverIDs == nil {
			text += " The WDGWars list could not be loaded, so only your own uploads count as known."
		}
		return text
	}

	/// Counts the nodes in the database and works out which ones WDGWars does not know yet.
	private func refresh() async {
		pendingCount = await WDGWarsUploader.shared.pendingNodes.count
		uploadedCount = await WDGWarsUploader.shared.uploadedNodes.count
		if serverIDs == nil, !apiKey.isEmpty { await loadServerIDs() }
		await computeStats()
	}

	/// `/api/meshcore` lists all Meshtastic and MeshCore nodes WDGWars has, world-wide.
	private func loadServerIDs() async {
		guard let (status, data) = try? await WDGWarsUploader.shared.get("meshcore"), status == 200,
			  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }
		serverIDs = Set(list.filter { ($0["network"] as? String) == "meshtastic" }
			.compactMap { $0["node_id"] as? String })
	}

	private func computeStats() async {
		let uploader = WDGWarsUploader.shared
		let known = (serverIDs ?? []).union(await uploader.uploadedIDs)
		let queued = await uploader.queuedIDs
		let nodes = (try? context.fetch(FetchDescriptor<NodeInfoEntity>())) ?? []

		var result = WDGWarsNodeStats()
		for node in nodes where node.myInfo == nil {
			result.found += 1
			guard let pos = node.latestPosition,
				  pos.latitudeI != 0 || pos.longitudeI != 0,
				  pos.latitudeI != Int32.max, pos.longitudeI != Int32.max else { continue }
			result.withGPS += 1
			let id = WDGWarsUploader.nodeID(node.num)
			if known.contains(id) {
				result.known += 1
				continue
			}
			result.new += 1
			let record = WDGWarsUploader.makeRecord(
				nodeNum: node.num,
				name: node.user?.longName ?? node.user?.shortName,
				role: node.user?.role,
				latitudeI: pos.latitudeI, longitudeI: pos.longitudeI,
				rssi: pos.rssi != 0 ? pos.rssi : node.rssi,
				snr: pos.snr != 0 ? pos.snr : node.snr,
				viaMqtt: node.viaMqtt,
				hops: node.hopsAway > 0 ? Int(node.hopsAway) : nil,
				time: pos.time ?? node.lastHeard ?? Date())
			if let record {
				result.uploadable.append(record)
				if !queued.contains(id) { result.notQueued += 1 }
			}
		}
		stats = result
	}

	private func queueNewNodes() async {
		scanning = true
		_ = await WDGWarsUploader.shared.enqueue(stats.uploadable)
		await refresh()
		scanning = false
	}
}
