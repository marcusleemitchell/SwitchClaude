import AppKit
import SwiftUI

@main
struct SwitchClaudeApp: App {
    @StateObject private var store = ProfileStore()

    var body: some Scene {
        WindowGroup("SwitchClaude") {
            ContentView().environmentObject(store)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

// MARK: - Main window

struct ContentView: View {
    @EnvironmentObject var store: ProfileStore
    @StateObject private var ui = ContentUIState()


    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if store.claude == nil { claudeMissingBanner }
            if store.canImport && store.claude != nil { importBanner }
            if store.anyNeedsRebuild && store.claude != nil { rebuildBanner }

            if store.profiles.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(store.profiles) { p in
                        ProfileRow(profile: p, onDelete: { ui.pendingDelete = p })
                    }
                }
                .listStyle(.inset)
            }
            Divider()
            footer
        }
        .frame(minWidth: 600, minHeight: 440)
        .sheet(item: $ui.sheet) { kind in
            NewProfileSheet(importMode: kind == .importExisting).environmentObject(store)
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(store.errorMessage ?? "")
        }
        .confirmationDialog(
            "Delete “\(ui.pendingDelete?.name ?? "")”?",
            isPresented: Binding(get: { ui.pendingDelete != nil }, set: { if !$0 { ui.pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            if let p = ui.pendingDelete {
                Button("Delete launcher only") { store.delete(p, deleteData: false); ui.pendingDelete = nil }
                Button("Delete launcher and move data to Bin", role: .destructive) {
                    store.delete(p, deleteData: true); ui.pendingDelete = nil
                }
                Button("Cancel", role: .cancel) { ui.pendingDelete = nil }
            }
        } message: {
            Text("Keeping the data means you can recreate a profile later by re-importing its folder. Moving it to the Bin signs that profile out for good.")
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("SwitchClaude").font(.title2.weight(.semibold))
                Text("Run several Claude Desktop accounts side by side.")
                    .font(.callout).foregroundColor(.secondary)
            }
            Spacer()
            Button {
                ui.sheet = .new
            } label: {
                Label("New Profile", systemImage: "plus")
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(store.claude == nil)
        }
        .padding(16)
    }

    private var claudeMissingBanner: some View {
        Banner(systemImage: "exclamationmark.triangle.fill", tint: .orange,
               text: "Claude Desktop wasn't found in Applications.") {
            Button("Locate Claude.app…") { store.chooseClaude() }
        }
    }

    private var importBanner: some View {
        Banner(systemImage: "square.and.arrow.down.on.square", tint: .accentColor,
               text: "An existing Claude Desktop sign-in and history were found. Import them into a named profile?") {
            Button("Import…") { ui.sheet = .importExisting }
            Button("Dismiss") { store.importDismissed = true }
        }
    }

    private var rebuildBanner: some View {
        Banner(systemImage: "arrow.triangle.2.circlepath", tint: .orange,
               text: "Claude has been updated. Rebuild your Standalone profiles to pick up the new version.") {
            Button("Rebuild All") { store.rebuildAll() }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "person.2.crop.square.stack")
                .font(.system(size: 42)).foregroundColor(.secondary)
            Text("No profiles yet").font(.headline)
            Text("Create one for each Claude account, e.g. “Work” and “Personal”.\nEach gets its own sign-in, history, settings and app icon.")
                .multilineTextAlignment(.center).foregroundColor(.secondary)
            Button("Create Your First Profile") { ui.sheet = .new }
                .disabled(store.claude == nil)
                .padding(.top, 4)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let c = store.claude {
                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                Text("Claude \(c.version)").font(.callout)
                Text(c.url.path).font(.caption).foregroundColor(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                Text("Claude Desktop not found").font(.callout)
            }
            Button("Change…") { store.chooseClaude() }.buttonStyle(.link)
            Spacer()
            Button("Open Launchers Folder") { store.openLaunchersFolder() }.buttonStyle(.link)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct Banner<Actions: View>: View {
    let systemImage: String
    let tint: Color
    let text: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage).foregroundColor(tint)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            actions()
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(tint.opacity(0.08))
    }
}

// MARK: - Row

struct ProfileAvatar: View {
    let colorHex: String
    let initial: String
    var size: CGFloat = 36

    var body: some View {
        let ns = NSColor(hex: colorHex) ?? .systemOrange
        ZStack {
            Circle().fill(Color(nsColor: ns))
            Text(initial.isEmpty ? "?" : initial)
                .font(.system(size: size * 0.45, weight: .bold))
                .foregroundColor(Color(nsColor: ns.contrastingText))
        }
        .frame(width: size, height: size)
    }
}

struct ProfileRow: View {
    @EnvironmentObject var store: ProfileStore
    let profile: Profile
    let onDelete: () -> Void

    private var isRunning: Bool { store.running[profile.id] != nil }
    private var busyText: String? { store.busy[profile.id] }

    var body: some View {
        HStack(spacing: 12) {
            ProfileAvatar(colorHex: profile.colorHex, initial: profile.initial)
            VStack(alignment: .leading, spacing: 3) {
                Text(profile.name).font(.headline)
                status
            }
            Spacer()
            if isRunning {
                Button("Quit") { store.quit(profile) }
            }
            Button(isRunning ? "Show" : "Launch") { store.launch(profile) }
                .disabled(busyText != nil || store.claude == nil)
            Menu {
                Button("Rebuild Launcher") { store.rebuild(profile) }
                    .disabled(isRunning || busyText != nil)
                Button(profile.mode == .standalone ? "Switch to Lightweight" : "Switch to Standalone") {
                    store.switchMode(profile)
                }
                .disabled(isRunning || busyText != nil)
                Divider()
                Button("Show Launcher in Finder") { store.revealLauncher(profile) }
                Button("Open Data Folder") { store.openDataFolder(profile) }
                Button("Edit MCP Config…") { store.openConfig(profile) }
                Divider()
                Button("Delete Profile…", action: onDelete)
                    .disabled(isRunning || busyText != nil)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 30)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if busyText == nil { store.launch(profile) } }
    }

    @ViewBuilder private var status: some View {
        if let busyText {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(busyText).font(.caption).foregroundColor(.secondary)
            }
        } else {
            HStack(spacing: 6) {
                if isRunning {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("Running").font(.caption).foregroundColor(.green)
                    Text("·").font(.caption).foregroundColor(.secondary)
                }
                Text(profile.mode.title).font(.caption).foregroundColor(.secondary)
                if store.needsRebuild(profile) {
                    Text("·").font(.caption).foregroundColor(.secondary)
                    Text("Needs rebuild").font(.caption).foregroundColor(.orange)
                }
            }
        }
    }
}

// MARK: - New profile

struct NewProfileSheet: View {
    let importMode: Bool
    @EnvironmentObject var store: ProfileStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var form = NewProfileForm()

    private var trimmed: String { form.name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var nameError: String? {
        if trimmed.isEmpty { return nil }
        if Paths.safeFileName(trimmed).isEmpty { return "Please use some letters or numbers." }
        if store.isNameTaken(trimmed) { return "A profile with this name already exists." }
        return nil
    }
    private var canCreate: Bool { !trimmed.isEmpty && nameError == nil }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { Color(nsColor: NSColor(hex: form.colorHex) ?? .systemOrange) },
            set: { form.colorHex = NSColor($0).hexString }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                ProfileAvatar(colorHex: form.colorHex, initial: String(trimmed.prefix(1)).uppercased(), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(importMode ? "Import Existing Claude Data" : "New Profile").font(.title3.weight(.semibold))
                    Text(importMode
                         ? "Your current Claude Desktop sign-in, chats and settings are copied into this profile. The original is left untouched."
                         : "A separate Claude Desktop with its own sign-in, history and settings.")
                        .font(.callout).foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Name").font(.subheadline.weight(.medium))
                TextField(importMode ? "e.g. Personal" : "e.g. Work", text: $form.name)
                    .textFieldStyle(.roundedBorder)
                if let nameError {
                    Text(nameError).font(.caption).foregroundColor(.red)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Colour").font(.subheadline.weight(.medium))
                HStack(spacing: 8) {
                    ForEach(Palette.hexes, id: \.self) { hex in
                        Circle()
                            .fill(Color(nsColor: NSColor(hex: hex) ?? .gray))
                            .frame(width: 22, height: 22)
                            .overlay(Circle().stroke(Color.primary, lineWidth: form.colorHex == hex ? 2 : 0).padding(-3))
                            .onTapGesture { form.colorHex = hex }
                    }
                    ColorPicker("", selection: colorBinding, supportsOpacity: false).labelsHidden()
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Type").font(.subheadline.weight(.medium))
                Picker("", selection: $form.mode) {
                    ForEach(LaunchMode.allCases) { m in Text(m.title).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(form.mode.detail).font(.caption).foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(importMode ? "Import" : "Create") {
                    store.create(name: trimmed, colorHex: form.colorHex, mode: form.mode, importDefault: importMode)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!canCreate)
            }
        }
        .padding(22)
        .frame(width: 460)
    }
}

// MARK: - UI state
// Plain ObservableObjects rather than @State: on recent SDKs @State is a macro, and macros
// need a compiler plugin that a bare `swiftc` build (no Xcode project) can't always find.

enum SheetKind: Identifiable {
    case new, importExisting
    var id: Int { self == .new ? 0 : 1 }
}

final class ContentUIState: ObservableObject {
    @Published var sheet: SheetKind?
    @Published var pendingDelete: Profile?
}

final class NewProfileForm: ObservableObject {
    @Published var name = ""
    @Published var colorHex = Palette.hexes[0]
    @Published var mode: LaunchMode = .standalone
}
