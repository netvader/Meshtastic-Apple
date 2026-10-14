//
//  WDGWarsAutoScan.swift
//
//  Runs once the radio's node list has been stored after connecting.
//

import Foundation
import SwiftData

@MainActor
enum WDGWarsAutoScan {
	/// Starts a new session, notes which nodes with GPS are new and, with auto upload on, queues the ones
	/// WDGWars does not know yet. The radio sends its node list as NodeInfo packets, which the live
	/// position hook never sees.
	static func afterConnect(context: ModelContext) async {
		let uploader = WDGWarsUploader.shared
		await uploader.beginSession()
		let index = await WDGWarsNodeIndex.build(context: context)
		await uploader.noteGPSNodes(index.rows.filter { $0.inDatabase && $0.hasGPS }.map(\.id))
		if uploader.isEnabled {
			_ = await uploader.enqueue(index.addable)
		}
	}
}
