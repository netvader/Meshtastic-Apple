//
//  WDGWarsSettingsView.swift
//
//  WDGWars upload: account (API key), automatic upload and the node lists.
//

import SwiftUI

struct WDGWarsSettingsView: View {
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
			uploadSection
			nodesSection
		}
		.navigationTitle("WDGWars Upload")
		.navigationBarTitleDisplayMode(.inline)
		.task { await refreshCounts() }
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

	private func refreshCounts() async {
		pendingCount = await WDGWarsUploader.shared.pendingNodes.count
		uploadedCount = await WDGWarsUploader.shared.uploadedNodes.count
	}
}
