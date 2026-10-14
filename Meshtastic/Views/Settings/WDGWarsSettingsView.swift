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

	var body: some View {
		List {
			accountSection
			uploadSection
			nodesSection
		}
		.navigationTitle("WDGWars Upload")
		.navigationBarTitleDisplayMode(.inline)
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
				Label("Nodes", systemImage: "antenna.radiowaves.left.and.right")
			}
		} footer: {
			Text("Lists every node with filters, sorting, a map jump and the upload actions.")
		}
	}
}
