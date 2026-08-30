//
//  AppDelegate.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 30.08.26.
//

import AppKit
import OSLog

/// Owns the recorder and handles `bettercapture://` URLs.
///
/// URL handling cannot live on the `MenuBarExtra` scene. SwiftUI only routes external
/// events such as URLs to window-presenting scenes, and the menu bar content is not built
/// until the user first opens the popover, so `onOpenURL` there is never registered.
/// `NSApplicationDelegate` receives the Apple Event from launch onwards, which is why the
/// recorder is owned here: it has to be reachable without the popover ever being opened.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {

    let viewModel = RecorderViewModel()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "AppDelegate")

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "bettercapture" {
            handle(url)
        }
    }

    // MARK: - URL Scheme

    private func handle(_ url: URL) {
        logger.info("Handling URL: \(url.absoluteString)")

        switch url.host {
        case "toggle", "toggle-copy":
            let copyToClipboard = url.host == "toggle-copy"
            Task {
                if viewModel.isRecording {
                    await viewModel.stopRecording(copyToClipboard: copyToClipboard)
                } else {
                    switch ContentSelectionMode.current {
                    case .pickContent:
                        viewModel.presentPicker()
                    case .selectArea:
                        await viewModel.presentAreaSelection()
                    }
                }
            }
        case "open-recordings":
            let settings = viewModel.settings
            let didStart = settings.startAccessingOutputDirectory()
            defer {
                if didStart {
                    settings.stopAccessingOutputDirectory()
                }
            }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: settings.outputDirectory.path)
        default:
            logger.warning("Unhandled URL host: \(url.host ?? "nil")")
        }
    }
}
