import AppKit
import QuickLookUI

/// A real Quick Look panel for the review steps.
///
/// Quick Look renders in its own process, so previewing a file Fettle is about
/// to trash — including one ClamAV flagged — never opens it in an app.
@MainActor
final class QuickLookPreview: NSObject {
    static let shared = QuickLookPreview()

    private var urls: [URL] = []

    func preview(_ url: URL) { preview([url], startingAt: 0) }

    func preview(_ urls: [URL], startingAt index: Int) {
        guard !urls.isEmpty else { return }
        self.urls = urls
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        panel.currentPreviewItemIndex = min(max(index, 0), urls.count - 1)
        if panel.isVisible {
            panel.orderFront(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }
}

extension QuickLookPreview: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
    }
}

extension QuickLookPreview: @preconcurrency QLPreviewPanelDelegate {}

enum QuickLook {
    @MainActor
    static func preview(_ url: URL) {
        QuickLookPreview.shared.preview(url)
    }
}
