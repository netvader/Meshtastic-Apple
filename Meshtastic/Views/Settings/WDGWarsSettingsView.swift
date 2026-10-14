//
//  WDGWarsSettingsView.swift
//
//  WDGWars upload: account (API key), automatic upload and the node lists.
//

import SwiftUI
import SwiftData

struct WDGWarsSettingsView: View {
	@Environment(\.modelContext) private var context
	@State private var index = WDGWarsNodeIndex()
	@AppStorage(WDGWarsUploader.enabledKey) private var autoUpload = false
	@AppStorage("wdgwarsKeyLocked") private var keyLocked = false
	@State private var apiKey = WDGWarsKeychain.load()
	@State private var keyCheck: WDGWarsKeyCheck?
	@State private var checkingKey = false
	@State private var confirmUnlock = false

	var body: some View {
		List {
			accountSection
			overviewSection
			uploadSection
		}
		.navigationTitle("WDGWars Upload")
		.navigationBarTitleDisplayMode(.inline)
		.onAppear { Task { await refresh() } }
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

	// MARK: Overview

	private var overviewSection: some View {
		Section {
			ForEach(WDGWarsFilter.allCases) { filter in
				NavigationLink {
					WDGWarsNodeListView(filter: filter)
				} label: {
					LabeledContent {
						Text("\(index.count(for: filter))")
					} label: {
						Label(filter.title, systemImage: filter.icon)
					}
				}
			}
		} header: {
			Text("Nodes")
		} footer: {
			Text("Found: nodes stored in this app, without your own radio. Known: already uploaded by this app or listed by WDGWars. New: with GPS but not known yet. Tap a row to see the nodes.")
		}
	}

	private func refresh() async {
		index = await WDGWarsNodeIndex.build(context: context)
	}
}
