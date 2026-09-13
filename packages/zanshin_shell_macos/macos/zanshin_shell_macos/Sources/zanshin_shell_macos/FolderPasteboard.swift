// SPDX-License-Identifier: MIT

import Cocoa

/// Reads the folders a drag carries off its pasteboard.
enum FolderPasteboard {
    /// The absolute paths of the folders on `pasteboard`.
    ///
    /// Takes the file URLs, resolves Finder aliases and symlinks, and keeps
    /// what is a directory but not a package: Finder treats packages (`.app`,
    /// `.xcodeproj`, ...) as files, so they do not count as folders here
    /// either. An item that cannot be resolved - a broken alias or symlink -
    /// is skipped. The resolved path is returned, because an alias file is no
    /// folder anyone could open.
    static func folderPaths(on pasteboard: NSPasteboard) -> [String] {
        let urls =
            pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.compactMap { url in
            guard let resolved = try? URL(resolvingAliasFileAt: url),
                let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey]),
                values.isDirectory == true,
                values.isPackage != true
            else {
                return nil
            }
            return resolved.path
        }
    }
}
