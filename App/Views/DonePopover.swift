import SwiftUI
import OrchestraCore

/// The "Done" / Archive popover listing archived tasks. ui-spec §3.8 / §4.9.
struct DonePopover: View {
    @EnvironmentObject var model: BoardModel
    @Environment(\.theme) var theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Text("DONE").font(F.ui(11, .semibold)).tracking(0.8).foregroundColor(theme.text2)
                Spacer(minLength: 0)
                Text("\(model.archived.count) tasks").font(F.ui(11)).foregroundColor(theme.text2)
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 8)

            if model.archived.isEmpty {
                Text("No archived tasks yet")
                    .font(F.ui(11.5)).foregroundColor(theme.text3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.archived.enumerated()), id: \.element.id) { idx, t in
                            ArchiveRow(task: t)
                            if idx < model.archived.count - 1 {
                                Rectangle().fill(theme.hair).frame(height: 0.5)
                            }
                        }
                    }
                    .padding(.horizontal, 8).padding(.bottom, 10)
                }
                .frame(maxHeight: 380)
            }
        }
        .frame(width: 460)
        .background(theme.panelOpaque)
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(theme.hair, lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 13))
        .shadow(color: Color(r: 20, g: 18, b: 40, a: 0.26), radius: 24, x: 0, y: 16)
    }
}

private struct ArchiveRow: View {
    @Environment(\.theme) var theme: Theme
    let task: Task

    private var initials: String {
        let words = task.title.split(separator: " ").prefix(2)
        let s = words.map { String($0.prefix(1)) }.joined()
        return s.isEmpty ? "·" : s.uppercased()
    }
    private var repoName: String { (task.repo as NSString).lastPathComponent }
    private var age: String {
        let secs = Int(Date().timeIntervalSince(task.updatedAt))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        if secs < 86400 { return "\(secs / 3600)h" }
        return "\(secs / 86400)d"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(initials)
                .font(F.mono(9, .heavy)).foregroundColor(.white)
                .frame(width: 22, height: 22)
                .background(theme.gray.dot)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(task.title).font(F.ui(12.5, .semibold)).foregroundColor(theme.text).lineLimit(1)
                Text("\(repoName) · \(age)").font(F.mono(10.5)).foregroundColor(theme.text2).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9).padding(.horizontal, 6)
    }
}
