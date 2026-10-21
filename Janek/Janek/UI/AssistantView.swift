import SwiftUI

struct AssistantView: View {
    @Environment(AssistantController.self) private var controller
    @State private var typedCommand = ""
    @FocusState private var textFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TranscriptList(entries: controller.transcript)

            VStack(spacing: 16) {
                Text(controller.state.title)
                    .font(.title3.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(isError ? Color.red : Color.primary)
                    .lineLimit(3)
                    .frame(minHeight: 56)
                    .padding(.horizontal)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.2), value: controller.state.title)

                if let engine = controller.lastEngine {
                    Label(engine, systemImage: engine.hasPrefix("Claude") ? "cloud" : "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Button {
                    if controller.state.isBusy { controller.cancelCurrentTurn() } else { controller.startListeningManually() }
                } label: {
                    VoiceOrb(state: controller.state)
                        .frame(width: 150, height: 150)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(controller.state.isBusy ? "Przerwij" : "Mów do Janka")

                HStack {
                    TextField("Albo napisz polecenie…", text: $typedCommand)
                        .textFieldStyle(.roundedBorder)
                        .submitLabel(.send)
                        .focused($textFieldFocused)
                        .onSubmit(send)
                    Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                        .disabled(typedCommand.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 20)
            .background(.bar)
        }
        .navigationTitle("Janek")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink { NotesView() } label: { Image(systemName: "note.text") }
                    .accessibilityLabel("Notatki")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    NavigationLink { SettingsView() } label: { Label("Ustawienia", systemImage: "gearshape") }
                    NavigationLink { CapabilitiesView() } label: { Label("Co potrafi Janek", systemImage: "sparkles") }
                    Button(role: .destructive) { controller.clearConversation() } label: {
                        Label("Wyczyść rozmowę", systemImage: "trash")
                    }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private var isError: Bool {
        if case .error = controller.state { return true }
        return false
    }

    private func send() {
        controller.submit(text: typedCommand)
        typedCommand = ""
        textFieldFocused = false
    }
}

private struct TranscriptList: View {
    let entries: [TranscriptEntry]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if entries.isEmpty {
                        EmptyHint().padding(.top, 40)
                    }
                    ForEach(entries) { entry in
                        Bubble(entry: entry).id(entry.id)
                    }
                }
                .padding()
            }
            .onChange(of: entries.last?.id) { _, id in
                guard let id else { return }
                withAnimation { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }
}

private struct Bubble: View {
    let entry: TranscriptEntry

    var body: some View {
        HStack {
            if entry.role == .user { Spacer(minLength: 40) }
            Text(entry.text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(background, in: .rect(cornerRadius: 18))
                .foregroundStyle(entry.role == .user ? Color.white : Color.primary)
                .font(entry.role == .system ? .footnote : .body)
            if entry.role != .user { Spacer(minLength: 40) }
        }
    }

    private var background: some ShapeStyle {
        switch entry.role {
        case .user: AnyShapeStyle(Color.accentColor)
        case .assistant: AnyShapeStyle(.thinMaterial)
        case .system: AnyShapeStyle(Color.orange.opacity(0.15))
        }
    }
}

private struct EmptyHint: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Powiedz „Hej Janek” i na przykład:")
                .font(.headline)
            ForEach([
                "Zapisz spotkanie z Anią w przyszły wtorek o dziesiątej",
                "Zadzwoń do mamy",
                "Gdzie jest najbliższa apteka?",
                "Nastaw minutnik na dwanaście minut",
                "Dopisz mleko do listy zakupów",
                "Ile kroków dziś zrobiłem?",
                "Włącz Dawida Podsiadło",
            ], id: \.self) { example in
                Label(example, systemImage: "quote.bubble").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Animowana kula odzwierciedlająca stan asystenta.
struct VoiceOrb: View {
    let state: AssistantState

    var body: some View {
        TimelineView(.animation) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle()
                    .fill(gradient)
                    .scaleEffect(pulse(t))
                    .blur(radius: 14)
                    .opacity(0.55)
                Circle()
                    .fill(gradient)
                    .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 2))
                    .scaleEffect(0.82 + 0.04 * sin(t * 2))
                Image(systemName: icon)
                    .font(.system(size: 42, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, isActive: state.isBusy)
            }
        }
    }

    private var icon: String {
        switch state {
        case .listening: "waveform"
        case .thinking: "ellipsis"
        case .speaking: "speaker.wave.2.fill"
        case .error: "exclamationmark.triangle.fill"
        default: "mic.fill"
        }
    }

    private var gradient: AngularGradient {
        let colors: [Color] = switch state {
        case .listening: [.blue, .cyan, .mint, .blue]
        case .thinking: [.purple, .indigo, .pink, .purple]
        case .speaking: [.indigo, .blue, .teal, .indigo]
        case .error: [.orange, .red, .orange]
        case .waitingForWakeWord: [.indigo, .blue, .indigo]
        case .idle: [.gray, .secondary, .gray]
        }
        return AngularGradient(colors: colors, center: .center)
    }

    private func pulse(_ t: TimeInterval) -> CGFloat {
        switch state {
        case .listening: 1.0 + 0.08 * sin(t * 8)
        case .thinking: 0.95 + 0.05 * sin(t * 4)
        case .speaking: 1.0 + 0.06 * sin(t * 6)
        default: 0.92 + 0.02 * sin(t * 1.5)
        }
    }
}
