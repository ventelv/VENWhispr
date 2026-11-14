import AppKit
import SwiftUI

/// Preferences window (⌘,) with toolbar tabs: General, Dictation, Models, Permissions.
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let model: AppModel

    init(model: AppModel) {
        self.model = model
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        super.init(window: window)

        addTab(to: tabs, "General", "gearshape", GeneralPane(model: model))
        addTab(to: tabs, "Dictation", "waveform", DictationPane(model: model))
        addTab(to: tabs, "Models", "cpu", ModelsPane(model: model))
        addTab(to: tabs, "Permissions", "lock.shield", PermissionsPane(model: model))

        window.styleMask = [.titled, .closable]
        window.toolbarStyle = .preference
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func addTab<Pane: View>(to tabs: NSTabViewController, _ title: String, _ symbol: String, _ pane: Pane) {
        let host = NSHostingController(rootView: pane)
        host.sizingOptions = .preferredContentSize
        host.title = title
        let item = NSTabViewItem(viewController: host)
        item.label = title
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        tabs.addTabViewItem(item)
    }

    func show(tab: Int? = nil) {
        if let tab, let tabs = window?.contentViewController as? NSTabViewController {
            tabs.selectedTabViewItemIndex = tab
        }
        model.refreshPermissions()
        NSApp.activate(ignoringOtherApps: true)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }
}

private let paneWidth: CGFloat = 480

private extension View {
    /// Grouped form sized to its content so the window fits each tab.
    func settingsPane() -> some View {
        formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)
            .frame(width: paneWidth)
    }
}

/// A label with a secondary detail line, laid out the way grouped forms show subtitles.
private struct RowLabel: View {
    let title: String
    let detail: String?

    init(_ title: String, _ detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail {
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: General

private struct GeneralPane: View {
    @ObservedObject var model: AppModel
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                Toggle(isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { on in
                        do { try model.setLaunchAtLogin(on) } catch { loginError = error.localizedDescription }
                    }
                )) {
                    RowLabel("Launch at login")
                }
            }
            Section {
                Picker(selection: $model.hotkey) {
                    ForEach(Hotkey.allCases, id: \.self) { Text($0.title).tag($0) }
                } label: {
                    RowLabel("First key", "Hold to dictate, double-tap to lock, Esc cancels")
                }
                Picker(selection: $model.language) {
                    ForEach(Language.all, id: \.code) { Text($0.name).tag($0.code) }
                } label: {
                    RowLabel("Language")
                }
                Picker(selection: $model.secondHotkey) {
                    Text("Off").tag(Hotkey?.none)
                    ForEach(Hotkey.allCases.filter { $0 != model.hotkey }, id: \.self) { Text($0.title).tag(Hotkey?.some($0)) }
                } label: {
                    RowLabel("Second key", "Dictates in its own language")
                }
                if model.secondHotkey != nil {
                    Picker(selection: $model.secondLanguage) {
                        ForEach(Language.all, id: \.code) { Text($0.name).tag($0.code) }
                    } label: {
                        RowLabel("Language")
                    }
                }
            } header: {
                Text("Hotkeys")
            } footer: {
                Text("A fixed language per key is about 0.8 s faster than Auto-detect.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Section {
                Toggle(isOn: $model.sounds) {
                    RowLabel("Sounds", "Tink on start, Pop on stop, Morse on lock")
                }
                Toggle(isOn: $model.keepMicWarm) {
                    RowLabel("Keep mic ready for 2 minutes", "Next dictation starts instantly; the mic stays on (orange dot) meanwhile")
                }
                Toggle(isOn: $model.muteWhileRecording) {
                    RowLabel("Mute audio while recording", "Silences music and video while the mic is on")
                }
            } header: {
                Text("Recording")
            }
        }
        .settingsPane()
        .alert("Couldn’t change login item", isPresented: Binding(get: { loginError != nil }, set: { if !$0 { loginError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(loginError ?? "")
        }
    }
}

// MARK: Dictation

private struct DictationPane: View {
    @ObservedObject var model: AppModel
    @State private var devices: [AudioInputDevice] = []
    @State private var automaticName: String?

    var body: some View {
        Form {
            Section {
                Picker(selection: microphone) {
                    Text(automaticName.map { "Automatic (\($0))" } ?? "Automatic").tag("")
                    let physical = devices.filter { !$0.isVirtual }
                    let virtual = devices.filter(\.isVirtual)
                    if !physical.isEmpty {
                        Divider()
                        ForEach(physical, id: \.uid) { Text($0.name).tag($0.uid) }
                    }
                    if !virtual.isEmpty {
                        Divider()
                        ForEach(virtual, id: \.uid) { Text($0.name).tag($0.uid) }
                    }
                } label: {
                    RowLabel("Microphone", "Automatic uses the system default but skips Bluetooth headsets")
                }
            } header: {
                Text("Input")
            }
            Section {
                Toggle(isOn: $model.aiPunctuation) {
                    RowLabel("Smart punctuation", "Gemma adds periods, commas and question marks, on device")
                }
                Toggle(isOn: $model.livePreview) {
                    RowLabel("Live preview", "Shows a draft of your words as you speak; about 250 MB of memory while on")
                }
                Toggle(isOn: $model.removeFillers) {
                    RowLabel("Remove filler words", "um, uh, er, ăă")
                }
                Toggle(isOn: $model.trailingSpace) {
                    RowLabel("Trailing space", "Adds a space after each paste")
                }
            } header: {
                Text("Output")
            }
            Section {
                TextField("Custom words", text: $model.customWords, prompt: Text("VENWhispr, Kubernetes, Thabo, Supabase"), axis: .vertical)
                    .labelsHidden()
                    .lineLimit(2...4)
            } header: {
                Text("Custom Words")
            } footer: {
                Text("Names, brands and jargon Whisper should spell correctly, separated by commas.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .settingsPane()
        .onAppear(perform: reloadDevices)
        .onReceive(NotificationCenter.default.publisher(for: .audioDevicesChanged)) { _ in reloadDevices() }
    }

    private func reloadDevices() {
        devices = AudioDevices.inputs()
        automaticName = AudioDevices.automaticInput()?.name
    }

    /// A chosen mic that's unplugged shows as Automatic, which is what recording falls back to.
    private var microphone: Binding<String> {
        Binding(
            get: { devices.contains { $0.uid == model.microphoneUID } ? model.microphoneUID : "" },
            set: { model.microphoneUID = $0 }
        )
    }
}

// MARK: Models

private struct ModelsPane: View {
    @ObservedObject var model: AppModel
    private let whisper = AppModel.whisperModel()
    private let gemma = AppModel.punctuationModel()
    private let preview = AppModel.previewModel()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    status(model.engineStatus)
                } label: {
                    RowLabel(whisper.name, facts("Speech to text", whisper.size, "Metal"))
                }
                LabeledContent {
                    if model.aiPunctuation {
                        status(model.punctuationStatus)
                    } else {
                        StatusLabel(text: "Off", tone: .pending)
                    }
                } label: {
                    RowLabel(gemma.name, facts("Smart punctuation", gemma.size, "unloads when off"))
                }
                LabeledContent {
                    if model.livePreview {
                        status(model.previewStatus)
                    } else {
                        StatusLabel(text: "Off", tone: .pending)
                    }
                } label: {
                    RowLabel(preview.name, facts("Live preview", preview.size, "unloads when off"))
                }
            } header: {
                Text("Models")
            }
            Section {
                LabeledContent {
                    Button("Restart") { model.onRestartWhisper() }
                } label: {
                    RowLabel("Whisper server", "Reloads the speech model")
                }
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.open(LocalServer.supportDir) }
                } label: {
                    RowLabel("Model folder", "~/Library/Application Support/VENWhispr")
                }
                LabeledContent {
                    Button("Show in Finder") { NSWorkspace.shared.open(LocalServer.logDir) }
                } label: {
                    RowLabel("Logs", "~/Library/Logs/VENWhispr")
                }
            } header: {
                Text("Troubleshooting")
            }
        }
        .settingsPane()
    }

    private func facts(_ parts: String?...) -> String {
        parts.compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder
    private func status(_ status: LocalServer.Status) -> some View {
        switch status {
        case .stopped: StatusLabel(text: "Off", tone: .pending)
        case .starting: StatusLabel(text: "Loading", tone: .pending)
        case .ready: StatusLabel(text: "Ready", tone: .ready)
        case .failed(let message): StatusLabel(text: "Failed", tone: .danger).help(message)
        }
    }
}

// MARK: Permissions

private struct PermissionsPane: View {
    @ObservedObject var model: AppModel
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    if model.microphoneAllowed {
                        StatusLabel(text: "Allowed", tone: .ready)
                    } else if model.microphoneBlocked {
                        HStack(spacing: 10) {
                            StatusLabel(text: "Not allowed", tone: .warn)
                            Button("Open Settings…") { AppModel.openMicrophoneSettings() }
                        }
                    } else {
                        HStack(spacing: 10) {
                            StatusLabel(text: "Not asked yet", tone: .pending)
                            Button("Allow…") { model.requestMicrophone() }
                        }
                    }
                } label: {
                    RowLabel("Microphone", "Needed to hear you")
                }
                LabeledContent {
                    if model.accessibilityGranted {
                        StatusLabel(text: "Allowed", tone: .ready)
                    } else {
                        HStack(spacing: 10) {
                            StatusLabel(text: "Not allowed", tone: .warn)
                            Button("Open Settings…") { Paster.openAccessibilitySettings() }
                        }
                    }
                } label: {
                    RowLabel("Accessibility", "Needed for the hotkey and to paste into other apps")
                }
            } footer: {
                Text("Audio and text never leave this Mac.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .settingsPane()
        .onReceive(poll) { _ in model.refreshPermissions() }
    }
}
