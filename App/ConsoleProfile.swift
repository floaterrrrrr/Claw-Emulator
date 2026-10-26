// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ConsoleLibrarySettings: View {
    @AppStorage("showLibraryPlaytime") private var playtime = true
    @AppStorage("showLibraryClock") private var clock = true
    @AppStorage("showLibraryBattery") private var battery = true
    @AppStorage("libraryHaptics") private var haptics = true
    var body: some View {
        ConsoleSettingsPage(title: "Library & status", subtitle: "Your console, your way.", symbol: "slider.horizontal.3") {
            VStack(alignment: .leading, spacing: 14) {
                Text("LIBRARY").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Toggle("Show playtime", isOn: $playtime)
                Text("Select or hover over a cover to see active playtime. Pauses and background time are excluded.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("App haptics", isOn: $haptics)
                Text("Covers come from your chosen images or icons embedded in imported games.")
                    .font(.caption).foregroundStyle(.secondary)
            }.consolePanel()
            VStack(alignment: .leading, spacing: 14) {
                Text("STATUS CAPSULE").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Toggle("Show clock", isOn: $clock)
                Toggle("Show battery percentage", isOn: $battery)
                Text("Battery updates follow live iOS battery reports and refresh when the app becomes active.")
                    .font(.caption).foregroundStyle(.secondary)
            }.consolePanel()
        }
    }
}
