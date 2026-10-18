// SPDX-License-Identifier: MIT

import Cocoa

/// The folder picker behind `chooseDirectory`: the system's open panel for one folder.
enum DirectoryPanel {
    /// Asks for one folder — folders only, one, new folders allowed — as a sheet on `window`, or as a modal panel
    /// without one. It starts in `initialDirectory` and names its default button `prompt` when given.
    ///
    /// - Parameter completion: called on the main thread with the chosen folder's path, or nil when cancelled
    static func choose(
        on window: NSWindow?, initialDirectory: String?, prompt: String?, completion: @escaping (String?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.resolvesAliases = true
        if let initialDirectory = initialDirectory {
            panel.directoryURL = URL(fileURLWithPath: initialDirectory, isDirectory: true)
        }
        if let prompt = prompt {
            panel.prompt = prompt
        }
        let finish = { (response: NSApplication.ModalResponse) in
            completion(response == .OK ? panel.url?.path : nil)
        }
        if let window = window {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            finish(panel.runModal())
        }
    }
}
