import SwiftUI
import OrchestraUI

/// The app's theme preference: follow the system, or force light/dark. Persisted client-side under
/// `orch_theme_mode` and applied at the app root via `.preferredColorScheme`. (macOS uses a two-way
/// `orch_dark` bool; the phone wants an explicit *System* option, so it carries its own three-way key.)
enum ThemeMode: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light:  return "Light"
        case .dark:   return "Dark"
        }
    }
    /// `nil` → follow the system; otherwise force the scheme.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}

/// Appearance section: theme mode (System/Light/Dark) + accent. Accent reuses the shared `orch_accent`
/// pref on `BoardModel` so it stays one setting across clients; the picker tints the whole app via the
/// root `.tint(...)`.
struct AppearanceSettingsSection: View {
    @EnvironmentObject var model: BoardModel
    @AppStorage("orch_theme_mode") private var themeRaw = ThemeMode.system.rawValue

    private var themeBinding: Binding<ThemeMode> {
        Binding(get: { ThemeMode(rawValue: themeRaw) ?? .system }, set: { themeRaw = $0.rawValue })
    }
    private var accentBinding: Binding<Accent> {
        Binding(get: { model.accent }, set: { model.accentRaw = $0.rawValue })
    }

    @Environment(\.colorScheme) private var systemScheme

    /// Whether the accent swatch previews should render their dark variant, resolving `.system` against
    /// the live scheme. Preview-only; the actual app scheme is driven by the root `.preferredColorScheme`.
    private var previewDark: Bool {
        switch themeBinding.wrappedValue.colorScheme {
        case .some(.dark):  return true
        case .some(.light): return false
        default:            return systemScheme == .dark
        }
    }

    var body: some View {
        Section("Appearance") {
            Picker("Theme", selection: themeBinding) {
                ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
            }
            Picker("Accent", selection: accentBinding) {
                ForEach(Accent.allCases) { accent in
                    Label {
                        Text(accent.rawValue.capitalized)
                    } icon: {
                        Circle().fill(accent.color(dark: previewDark))
                    }
                    .tag(accent)
                }
            }
        }
    }
}
