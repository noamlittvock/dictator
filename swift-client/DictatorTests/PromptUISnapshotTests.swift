import AppKit
import SwiftUI
import XCTest
@testable import Dictator

/// Renders the prompt-capture screens to PNGs for visual review. Runs only
/// when DICTATOR_SNAPSHOT_DIR is set or /tmp/dictator-snaps exists.
@MainActor
final class PromptUISnapshotTests: XCTestCase {
    private var directory: URL? {
        if let path = ProcessInfo.processInfo.environment["DICTATOR_SNAPSHOT_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.fileExists(atPath: "/tmp/dictator-snaps") ? URL(fileURLWithPath: "/tmp/dictator-snaps") : nil
    }

    private func render<V: View>(_ view: V, size: CGSize, name: String) async throws {
        guard let directory else { throw XCTSkip("DICTATOR_SNAPSHOT_DIR not set") }
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height).preferredColorScheme(.dark))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(1_500)) // let .task load statuses
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try rep.representation(using: .png, properties: [:])?.write(to: directory.appendingPathComponent("\(name).png"))
    }

    func testRenderPromptScreens() async throws {
        let center = PromptCaptureCenter.shared
        center.notices.note(.remote, context: CaptureContext(remoteHost: "build-box"), label: "Typing over SSH to build-box")
        center.notices.note(.toolOff, context: CaptureContext(toolID: "gemini-cli"), label: "Gemini CLI")
        try await render(PromptSetupView {}, size: CGSize(width: 560, height: 620), name: "setup")
        try await render(PromptsSettingsTab().background(Color.dsBgContent), size: CGSize(width: 700, height: 2600), name: "settings")
        try await render(CaptureMethodSheet(tool: ToolCatalog.shared.tool(id: "claude-code")!) {}.background(Color.dsBgContent), size: CGSize(width: 480, height: 330), name: "method")
        try await render(AddServerSheet(initialAlias: "build-box") {}.background(Color.dsBgContent), size: CGSize(width: 500, height: 220), name: "server")
        for notice in center.notices.active { center.notices.resolve(notice) }
    }
}
