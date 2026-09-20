import SwiftUI
import FettleCore

/// Whether macOS will let Fettle read the user's protected folders.
///
/// This belongs in Settings as a standing fact, not only as a banner that
/// appears once a scan has already been chosen. It is the single thing that
/// decides whether a malware scan's result means anything: without Full Disk
/// Access, clamscan is refused on Desktop, Documents, Mail and Messages, and
/// reports those folders as clean rather than as unread.
struct FullDiskAccessLabel: View {
    let status: FullDiskAccessStatus

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch status {
        case .granted: return "checkmark.circle.fill"
        case .denied: return "lock.trianglebadge.exclamationmark"
        case .unknown: return "questionmark.circle"
        }
    }

    private var tint: Color {
        switch status {
        case .granted: return Theme.Palette.safe
        case .denied: return Theme.Palette.caution
        case .unknown: return .secondary
        }
    }

    private var title: String {
        switch status {
        case .granted: return "Granted"
        case .denied: return "Not granted"
        case .unknown: return "Couldn't tell"
        }
    }

    private var detail: String {
        switch status {
        case .granted:
            return "Scans can read every folder on this Mac."
        case .denied:
            // Named rather than counted, and stated as a consequence rather
            // than as a setting: "Full Disk Access is off" tells nobody what
            // it costs them.
            return "Desktop, Documents, Mail and Messages can't be read. "
                + "A scan reports them as clean either way."
        case .unknown:
            // The probe file wasn't where it was expected. Claiming "denied"
            // would send someone to System Settings to fix a permission that
            // was never the problem.
            return "The permission couldn't be checked on this system."
        }
    }
}
