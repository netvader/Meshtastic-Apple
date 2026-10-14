//
//  WDGWarsSettingsView.swift
//
//  WDGWars upload: account (API key), automatic upload and the node lists.
//

import SwiftUI

struct WDGWarsSettingsView: View {
	@EnvironmentObject var accessoryManager: AccessoryManager
	@State private var activity = WDGWarsActivity()
	@AppStorage(WDGWarsUploader.enabledKey) private var autoUpload = false
	@AppStorage("wdgwarsKeyLocked") private var keyLocked = false
	@State private var apiKey = WDGWarsKeychain.load()
	@State private var keyCheck: WDGWarsKeyCheck?
	@State private var checkingKey = false
	@State private var confirmUnlock = false

	var body: some View {
		List {
			accountSection
			uploadSection
			nodesSection
		}
		.navigationTitle("WDGWars Upload")
		.navigationBarTitleDisplayMode(.inline)
		.task {
			// Keeps the summary current while the screen is open, so uploads show up as they happen.
			while !Task.isCancelled {
				activity = await WDGWarsUploader.shared.activity()
				try? await Task.sleep(for: .seconds(3))
			}
		}
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
		Section {
			NavigationLink {
				WDGWarsNodeListView()
			} label: {
				VStack(alignment: .leading, spacing: 6) {
					Label("Nodes", systemImage: "antenna.radiowaves.left.and.right")
					activitySummary
				}
			}
		} footer: {
			Text("Counts since the radio was last connected. Tap to see the nodes, filter them and upload.")
		}
	}

	@ViewBuilder private var activitySummary: some View {
		HStack(spacing: 6) {
			Circle()
				.fill(accessoryManager.isConnected ? Color.green : Color.secondary.opacity(0.5))
				.frame(width: 8, height: 8)
			Text(accessoryManager.isConnected ? "Radio connected" : "No radio connected")
		}
		.font(.caption)
		.foregroundStyle(.secondary)
		if activity.start == nil {
			Text("Connect a radio to see new nodes here.")
				.font(.caption).foregroundStyle(.secondary)
		} else {
			HStack(spacing: 12) {
				Label("\(activity.found.count) new with GPS", systemImage: "sparkles")
				Label("\(activity.uploaded) uploaded", systemImage: "icloud.and.arrow.up")
				Label("\(activity.waiting) waiting", systemImage: "clock")
			}
			.font(.caption)
			.foregroundStyle(.secondary)
			if let last = activity.lastUploadAt {
				Text("Last upload \(last.formatted(.dateTime.day().month().hour().minute())) · \(activity.lastUploadCount) nodes")
					.font(.caption).foregroundStyle(.secondary)
			}
		}
	}
}
