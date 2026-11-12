import CameraCore
import SwiftUI

/// Server-side recordings, only reachable when the provider reports
/// history support. Deletion is deliberate: single recordings or a
/// selection (including a time range), always confirmed with a count, the
/// provider's granularity, and what will be skipped. Active, protected and
/// read-only recordings are never sent for deletion.
struct RecordingsView: View {
    @Environment(AppModel.self) private var model
    let camera: CameraDescriptor

    @State private var recordings: [Recording] = []
    @State private var nextCursor: String?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var hasLoaded = false
    @State private var playing: PlaybackItem?
    @State private var pendingDeletion: [Recording] = []
    @State private var actionError: String?
    @State private var actionResult: String?
    @State private var exported: ExportedFile?
    @State private var exportingID: String?
    @State private var isSelecting = false
    @State private var selection = Set<String>()
    @State private var isChoosingRange = false
    @State private var isDeleting = false

    struct PlaybackItem: Identifiable {
        var recording: Recording
        var session: StreamSession
        var id: String { recording.id }
    }

    struct ExportedFile: Identifiable {
        var url: URL
        var id: URL { url }
    }

    private var canDelete: Bool { camera.capabilities.deletion.isSupported }
    private var serverName: String { model.library.profile(camera.id.connectionID)?.name ?? "the server" }

    var body: some View {
        List {
            if let loadError {
                Label(loadError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            if let actionError {
                Label(actionError, systemImage: "exclamationmark.circle").foregroundStyle(.red)
            }
            if let actionResult {
                Label(actionResult, systemImage: "checkmark.circle").foregroundStyle(.green)
            }
            if hasLoaded, recordings.isEmpty, loadError == nil {
                Text("The server has no recordings for this camera.").foregroundStyle(.secondary)
            }
            ForEach(groupedByDay, id: \.day) { group in
                Section(group.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(group.recordings) { recording in
                        HStack {
                            if isSelecting {
                                Image(systemName: selection.contains(recording.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(recording.deletionBlockedReason == nil ? Color.accentColor : .secondary)
                            }
                            RecordingRow(recording: recording, isExporting: exportingID == recording.id)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { isSelecting ? toggle(recording) : play(recording) }
                        .contextMenu { actions(for: recording) }
                        .swipeActions(edge: .trailing) { if !isSelecting { actions(for: recording) } }
                        .accessibilityIdentifier("recording.\(recording.id)")
                    }
                }
            }
            if nextCursor != nil {
                Button("Load More") { Task { await load(more: true) } }
                    .disabled(isLoading)
            }
        }
        .overlay { if isLoading, recordings.isEmpty { ProgressView() } }
        .navigationTitle(isSelecting ? "\(selection.count) Selected" : "Recordings")
        .refreshable { await load(more: false) }
        .task { await load(more: false) }
        .toolbar {
            if canDelete {
                ToolbarItem {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        selection = []
                    }
                    .accessibilityIdentifier("recordings.select")
                }
                if isSelecting {
                    ToolbarItem {
                        Button("Time Range…") { isChoosingRange = true }
                            .accessibilityIdentifier("recordings.range")
                    }
                    ToolbarItem {
                        Button(role: .destructive) {
                            pendingDeletion = recordings.filter { selection.contains($0.id) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .disabled(selection.isEmpty || isDeleting)
                        .accessibilityIdentifier("recordings.deleteSelected")
                    }
                }
            }
        }
        .sheet(item: $playing) { item in
            NavigationStack {
                LivePlayerContainer(camera: camera, fixedSession: item.session)
                    .padding()
                    .navigationTitle(item.recording.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("Done") { playing = nil } }
                    }
            }
            #if os(macOS)
            .frame(minWidth: 720, minHeight: 480)
            #endif
        }
        .sheet(item: $exported) { file in
            ExportSheet(fileURL: file.url)
        }
        .sheet(isPresented: $isChoosingRange) {
            TimeRangeSheet { range in
                Task { await selectRange(range) }
            }
        }
        .confirmationDialog(
            deletionTitle,
            isPresented: Binding(get: { !pendingDeletion.isEmpty }, set: { if !$0 { pendingDeletion = [] } }),
            titleVisibility: .visible
        ) {
            Button(deletableCount == 1 ? "Delete Recording" : "Delete \(deletableCount) Recordings", role: .destructive) {
                delete(pendingDeletion)
            }
            .disabled(deletableCount == 0)
        } message: {
            Text(deletionMessage)
        }
    }

    private var groupedByDay: [(day: Date, recordings: [Recording])] {
        let calendar = Calendar.current
        let groups = Dictionary(grouping: recordings) { calendar.startOfDay(for: $0.startedAt) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!.sorted { $0.startedAt > $1.startedAt }) }
    }

    private var deletableCount: Int { pendingDeletion.filter { $0.deletionBlockedReason == nil }.count }

    private var deletionTitle: String {
        pendingDeletion.count == 1 ? "Delete this recording from \(serverName)?" : "Delete \(deletableCount) recordings from \(serverName)?"
    }

    private var deletionMessage: String {
        let skipped = pendingDeletion.count - deletableCount
        var text = "This permanently deletes them on the server (\((camera.capabilities.deletionGranularity ?? .recording).displayName.lowercased())). Other recordings are not affected."
        if pendingDeletion.count == 1, let first = pendingDeletion.first {
            text = "This permanently deletes the \(first.startedAt.formatted(date: .abbreviated, time: .shortened)) recording on \(serverName). Other recordings are not affected."
        }
        if skipped > 0 { text += " \(skipped) protected, read-only or still-recording item\(skipped == 1 ? " is" : "s are") skipped." }
        return text
    }

    @ViewBuilder
    private func actions(for recording: Recording) -> some View {
        if camera.capabilities.playback.isSupported {
            Button { play(recording) } label: { Label("Play", systemImage: "play") }
        }
        if camera.capabilities.export.isSupported {
            Button { export(recording) } label: { Label("Export", systemImage: "square.and.arrow.up") }
                .disabled(recording.isActive)
        }
        if camera.capabilities.protection.isSupported, !recording.isReadOnly {
            Button { setProtected(!recording.isProtected, recording) } label: {
                Label(recording.isProtected ? "Unprotect" : "Protect", systemImage: recording.isProtected ? "lock.open" : "lock")
            }
        }
        if canDelete {
            if let reason = recording.deletionBlockedReason {
                Button {} label: { Label(reason, systemImage: "lock") }.disabled(true)
            } else {
                Button(role: .destructive) { pendingDeletion = [recording] } label: { Label("Delete", systemImage: "trash") }
            }
        }
    }

    private var provider: (any CameraProvider)? { model.library.provider(for: camera.id.connectionID) }

    private func toggle(_ recording: Recording) {
        guard recording.deletionBlockedReason == nil else {
            actionError = recording.deletionBlockedReason
            return
        }
        if selection.contains(recording.id) { selection.remove(recording.id) } else { selection.insert(recording.id) }
    }

    private func load(more: Bool) async {
        guard let provider else { return }
        isLoading = true
        defer { isLoading = false; hasLoaded = true }
        do {
            let page = try await provider.recordings(for: camera.id, cursor: more ? nextCursor : nil)
            recordings = more ? recordings + page.recordings : page.recordings
            nextCursor = page.nextCursor
            loadError = nil
        } catch {
            // Keep what's already listed; say why it couldn't refresh.
            loadError = describe(error)
        }
    }

    /// Loads every page covering the range, then selects what can be deleted.
    private func selectRange(_ range: ClosedRange<Date>) async {
        guard let provider else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let found = try await provider.recordings(for: camera.id, in: range)
            var byID = Dictionary(uniqueKeysWithValues: recordings.map { ($0.id, $0) })
            for recording in found { byID[recording.id] = recording }
            recordings = byID.values.sorted { $0.startedAt > $1.startedAt }
            let deletable = found.filter { $0.deletionBlockedReason == nil }
            selection = Set(deletable.map(\.id))
            actionResult = "Selected \(deletable.count) of \(found.count) recordings in that range\(found.count > deletable.count ? "; the rest can't be deleted" : "")."
        } catch {
            actionError = describe(error)
        }
    }

    private func play(_ recording: Recording) {
        guard camera.capabilities.playback.isSupported, let provider else { return }
        actionError = nil
        Task {
            do {
                playing = PlaybackItem(recording: recording, session: try await provider.playbackSession(for: recording))
            } catch {
                actionError = describe(error)
            }
        }
    }

    private func export(_ recording: Recording) {
        guard let provider else { return }
        actionError = nil
        exportingID = recording.id
        Task {
            defer { exportingID = nil }
            do {
                let export = try await provider.export(recording)
                exported = ExportedFile(url: try await ExportDownloader.download(export))
            } catch {
                actionError = describe(error)
            }
        }
    }

    private func setProtected(_ protected: Bool, _ recording: Recording) {
        guard let provider else { return }
        actionError = nil
        Task {
            do {
                let updated = try await provider.setProtected(protected, for: recording)
                if let index = recordings.firstIndex(where: { $0.id == updated.id }) { recordings[index] = updated }
            } catch {
                actionError = describe(error)
            }
        }
    }

    private func delete(_ batch: [Recording]) {
        guard let provider else { return }
        actionError = nil
        actionResult = nil
        isDeleting = true
        Task {
            defer { isDeleting = false }
            let result = await provider.delete(batch)
            let deleted = Set(result.deleted.map(\.id))
            recordings.removeAll { deleted.contains($0.id) }
            selection.subtract(deleted)
            var parts = ["Deleted \(result.deleted.count) recording\(result.deleted.count == 1 ? "" : "s")"]
            if !result.skipped.isEmpty { parts.append("skipped \(result.skipped.count)") }
            actionResult = parts.joined(separator: ", ") + "."
            if let failure = result.failed.first {
                actionError = "\(result.failed.count) couldn't be deleted: \(failure.1)"
            }
            if selection.isEmpty { isSelecting = false }
        }
    }
}

/// Chooses a time range for selecting recordings.
struct TimeRangeSheet: View {
    @Environment(\.dismiss) private var dismiss
    var onSelect: (ClosedRange<Date>) -> Void
    @State private var start = Date().addingTimeInterval(-24 * 3600)
    @State private var end = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section("Quick ranges") {
                    ForEach([("Last hour", 3600.0), ("Last 24 hours", 86400.0), ("Last 7 days", 604800.0)], id: \.0) { preset in
                        Button(preset.0) {
                            end = Date()
                            start = end.addingTimeInterval(-preset.1)
                        }
                    }
                }
                Section("Range") {
                    DatePicker("From", selection: $start, in: ...end)
                    DatePicker("To", selection: $end, in: start...)
                }
                Section {
                    Text("Recordings that overlap this range are selected. Nothing is deleted until you confirm.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Select Time Range")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Select") {
                        onSelect(start...end)
                        dismiss()
                    }
                    .accessibilityIdentifier("range.select")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
    }
}

struct RecordingRow: View {
    let recording: Recording
    let isExporting: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(recording.startedAt.formatted(date: .abbreviated, time: .standard)).font(.headline)
                HStack(spacing: 8) {
                    Text(recording.label.flatMap { $0.isEmpty ? nil : $0.capitalized } ?? recording.kind.rawValue.capitalized)
                    if let duration = recording.duration {
                        Text(Duration.seconds(duration).formatted(.time(pattern: .minuteSecond)))
                    }
                    if let size = recording.sizeBytes {
                        Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if isExporting { ProgressView().controlSize(.small) }
            if recording.isActive { CapabilityChip(text: "Recording", symbol: "record.circle") }
            if recording.isProtected { CapabilityChip(text: "Protected", symbol: "lock.fill") }
            if recording.isReadOnly { CapabilityChip(text: "Read-only", symbol: "archivebox") }
        }
    }
}

struct ExportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let fileURL: URL
    @State private var isSaving = false
    @State private var saveResult: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                Image(systemName: "film").font(.system(size: 44)).foregroundStyle(.tint)
                Text(fileURL.lastPathComponent).font(.headline).multilineTextAlignment(.center)
                ShareLink(item: fileURL) { Label("Share…", systemImage: "square.and.arrow.up") }
                    .buttonStyle(.borderedProminent)
                Button { isSaving = true } label: { Label("Save to…", systemImage: "folder") }
                    .buttonStyle(.bordered)
                if let saveResult { Text(saveResult).font(.caption).foregroundStyle(.secondary) }
            }
            .padding()
            .navigationTitle("Export")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .fileMover(isPresented: $isSaving, file: fileURL) { result in
                switch result {
                case let .success(url): saveResult = "Saved to \(url.deletingLastPathComponent().lastPathComponent)."
                case let .failure(error): saveResult = describe(error)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 380, minHeight: 300)
        #endif
    }
}
