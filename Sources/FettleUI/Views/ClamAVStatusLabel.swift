import SwiftUI
import FettleCore

struct ClamAVStatusLabel: View {
    let availability: ClamAVAvailability

    var body: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var symbol: String {
        switch availability {
        case .unknown: return "ellipsis.circle"
        case .available: return "checkmark.circle.fill"
        case .missing: return "exclamationmark.circle"
        case .broken: return "exclamationmark.triangle.fill"
        }
    }

    private var tint: Color {
        switch availability {
        case .unknown: return .secondary
        case .available: return Theme.Palette.safe
        case .missing: return Theme.Palette.caution
        case .broken: return Theme.Palette.danger
        }
    }

    private var title: String {
        switch availability {
        case .unknown: return "Checking…"
        case .available(_, let version, _): return version
        case .missing: return "Not installed"
        case .broken: return "Installed but not working"
        }
    }

    private var detail: String? {
        switch availability {
        case .unknown:
            return nil
        case .available(let path, _, let databaseDate):
            guard let databaseDate else { return "\(path) · no signature database found" }
            let days = Int(Date().timeIntervalSince(databaseDate) / 86_400)
            let freshness = days > 7
                ? "signatures \(Formatting.age(days: days)) old — run freshclam"
                : "signatures updated \(Formatting.age(days: days)) ago"
            return "\(path) · \(freshness)"
        case .missing:
            return "Run `brew install clamav`, then `freshclam`."
        case .broken(let path, let reason):
            return "\(path) · \(reason)"
        }
    }
}
