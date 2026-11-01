import Foundation
import SwiftUI
import AVFoundation
import Observation
import PhotosUI

enum EditorPanel: String, Identifiable {
    case audio, overlay, captions, filters, canvas
    case speed, volume, crop, animate, effects, trim
    case text, transition, overlayStyle

    var id: String { rawValue }
}

enum PickerTarget {
    case mainTrack
    case overlay
}

enum SafeGuide: String, CaseIterable, Identifiable {
    case none, tiktok, reels, shorts, youtube
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "Off"
        case .tiktok: return "TikTok"
        case .reels: return "Reels"
        case .shorts: return "Shorts"
        case .youtube: return "YouTube"
        }
    }
}

struct BusyState {
    var message: String
    var progress: Double?
    var cancellable: Bool
}

struct DragGhost {
    var selection: TimelineSelection
    var kind: TrackKind
    var start: Double
    var duration: Double
    var insertionTime: Double?
}

@MainActor
@Observable
final class EditorViewModel: Identifiable {
    let id: UUID
    let store: ProjectStore
    let paths: ProjectPaths
    private(set) var project: Project

    let playback = PlaybackController()
    let history = ProjectUndoManager()
    let thumbnails = ThumbnailCache()
    let waveforms = WaveformStore()
    let recorder = VoiceoverRecorder()

    var selection: TimelineSelection?
    var pixelsPerSecond: Double = 60
    var verticalOffset: CGFloat = 0
    var activePanel: EditorPanel?
    var transitionTargetClipID: UUID?
    var alert: AlertInfo?
    var toast: String?
    var busy: BusyState?
    var dragGhost: DragGhost?
    var snapTime: Double?
    var safeGuide: SafeGuide = .none
    var copiedEffects: ClipEffectsPayload?
    var showMediaPicker = false
    var pickerTarget: PickerTarget = .mainTrack
    var pickerItems: [PhotosPickerItem] = []
    var showMusicImporter = false
    var showExport = false
    var missingMediaCount = 0
    var recoveredFromBackup = false

    @ObservationIgnored private(set) var autosave: AutosaveService!
    @ObservationIgnored private var renderBox: RenderStateBox?
    @ObservationIgnored private var lastSignature: Int?
    @ObservationIgnored private var rebuildTask: Task<Void, Never>?
    @ObservationIgnored private(set) var interactiveBase: Project?
    @ObservationIgnored private var toastTask: Task<Void, Never>?
    @ObservationIgnored var busyTask: Task<Void, Never>?
    @ObservationIgnored var voiceoverStart: Double = 0
    @ObservationIgnored var autoAspectOnFirstImport: Bool
    @ObservationIgnored var beatCache: [UUID: [Double]] = [:]
    @ObservationIgnored var openingToast: String?
    @ObservationIgnored private var stateSaveTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailWriteTask: Task<Void, Never>?
    @ObservationIgnored private(set) var interaction: TimelineInteraction!

    static let sessionKey = "cutline.openProjectID"

    init(project: Project, store: ProjectStore, recovered: Bool = false, autoAspect: Bool = false) {
        self.id = project.id
        self.project = project
        self.store = store
        self.paths = store.paths(for: project.id)
        self.recoveredFromBackup = recovered
        self.autoAspectOnFirstImport = autoAspect
        self.selection = project.editorState.selection
        self.pixelsPerSecond = project.editorState.pixelsPerSecond.clamped(5, 800)
        self.verticalOffset = CGFloat(project.editorState.verticalOffset)
        for m in project.media where m.kind == .audio {
            if let b = m.beats { beatCache[m.id] = b }
        }
        self.autosave = AutosaveService(paths: paths) { [weak self] in
            self?.projectForSaving() ?? project
        }
        self.autosave.onSaved = { [weak self] in self?.scheduleThumbnailWrite() }
        playback.onStop = { [weak self] in self?.scheduleStateSave() }
        interaction = TimelineInteraction(viewModel: self)
    }

    // MARK: Lifecycle

    func onAppear() {
        UserDefaults.standard.set(id.uuidString, forKey: Self.sessionKey)
        playback.currentTime = project.editorState.playhead
        if selection != nil && !selectionExists(selection) { selection = nil }
        rebuild(force: true)
        ensureDerivedMedia()
        if recoveredFromBackup {
            showToast("Recovered from the last good save")
        } else if let message = openingToast {
            showToast(message)
            openingToast = nil
        }
        missingMediaCount = project.media.filter { m in
            !FileManager.default.fileExists(atPath: paths.media(m.fileName).path)
        }.count
    }

    func close() {
        if recorder.isRecording { stopVoiceover() }
        playback.pause()
        autosave.flush()
        writeThumbnail()
        UserDefaults.standard.removeObject(forKey: Self.sessionKey)
        rebuildTask?.cancel()
        busyTask?.cancel()
        playback.clear()
        thumbnails.clearMemory()
        Task { await store.refresh() }
    }

    func flushSave() {
        autosave.flush()
    }

    private func projectForSaving() -> Project {
        var p = project
        p.editorState = EditorState(playhead: playback.currentTime, pixelsPerSecond: pixelsPerSecond,
                                    verticalOffset: Double(verticalOffset), selection: selection)
        for i in p.media.indices where p.media[i].kind == .audio {
            if let b = beatCache[p.media[i].id] { p.media[i].beats = b }
        }
        return p
    }

    func scheduleStateSave() {
        stateSaveTask?.cancel()
        stateSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.autosave.schedule(delay: 0.05)
        }
    }

    // MARK: Edit pipeline

    /// Applies an undoable edit. Every edit autosaves and refreshes the preview.
    func perform(_ name: String, coalesce: String? = nil, _ change: (inout Project) -> Void) {
        // During a continuous gesture (slider drag), apply live; one undo step is recorded at the end.
        if interactiveBase != nil {
            change(&project)
            renderBox?.update(project)
            playback.refreshFrame()
            return
        }
        let before = project
        var after = project
        change(&after)
        history.record(before, name: name, coalesceKey: coalesce)
        project = after
        projectDidChange()
    }

    /// Updates analysis data (proxies, beats) without creating an undo step.
    func updateSilently(_ change: (inout Project) -> Void) {
        change(&project)
        projectDidChange()
    }

    func beginInteractive() {
        if interactiveBase == nil {
            interactiveBase = project
            history.breakCoalescing()
        }
    }

    /// Live update during a drag; the change is computed from the state at the start of the gesture.
    func updateInteractive(_ change: (inout Project, Project) -> Void) {
        guard let base = interactiveBase else { return }
        var p = base
        change(&p, base)
        project = p
        renderBox?.update(project)
        playback.refreshFrame()
    }

    func endInteractive(_ name: String) {
        guard let base = interactiveBase else { return }
        interactiveBase = nil
        snapTime = nil
        if Self.signature(base) != Self.signature(project) || Self.visualChanged(base, project) {
            history.record(base, name: name)
        }
        projectDidChange()
    }

    func cancelInteractive() {
        guard let base = interactiveBase else { return }
        interactiveBase = nil
        project = base
        projectDidChange()
    }

    private static func visualChanged(_ a: Project, _ b: Project) -> Bool {
        a.texts != b.texts || a.overlays != b.overlays || a.clips != b.clips || a.overlayClips != b.overlayClips ||
            a.captions != b.captions || a.audioClips != b.audioClips
    }

    func projectDidChange() {
        if let sel = selection, !selectionExists(sel) { selection = nil }
        renderBox?.update(project)
        if interactiveBase == nil {
            rebuild()
        } else {
            playback.refreshFrame()
        }
        autosave.schedule()
    }

    func undo() {
        guard let result = history.undo(current: project) else { return }
        project = result.0
        Haptics.tap()
        showToast("Undo \(result.1)")
        projectDidChange()
    }

    func redo() {
        guard let result = history.redo(current: project) else { return }
        project = result.0
        Haptics.tap()
        showToast("Redo \(result.1)")
        projectDidChange()
    }

    // MARK: Composition

    static func signature(_ p: Project) -> Int {
        var h = Hasher()
        h.combine(p.canvas.aspect)
        func combine(_ c: Clip) {
            h.combine(c.id); h.combine(c.mediaID); h.combine(c.kind)
            h.combine(c.timelineStart); h.combine(c.sourceStart); h.combine(c.sourceEnd)
            h.combine(c.speed); h.combine(c.ramp); h.combine(c.reversed)
            h.combine(c.volume); h.combine(c.muted); h.combine(c.fadeIn); h.combine(c.fadeOut)
            h.combine(c.audioDetached); h.combine(c.denoise); h.combine(c.transitionOut)
        }
        for c in p.clips { combine(c) }
        h.combine(-1)
        for c in p.overlayClips { combine(c) }
        h.combine(-2)
        for a in p.audioClips { h.combine(a) }
        h.combine(Int((p.duration * 600).rounded()))
        for m in p.media { h.combine(m.id); h.combine(m.fileName) }
        return h.finalize()
    }

    /// Rebuilds the AVComposition when timing/media changed; otherwise just re-renders the frame.
    func rebuild(force: Bool = false) {
        let sig = Self.signature(project)
        if !force, sig == lastSignature {
            renderBox?.update(project)
            playback.refreshFrame()
            return
        }
        lastSignature = sig
        rebuildTask?.cancel()
        let snapshot = project
        let paths = self.paths
        rebuildTask = Task { [weak self] in
            guard let self else { return }
            if snapshot.duration <= 0.01 {
                self.playback.clear()
                self.renderBox = nil
                return
            }
            do {
                let built = try await CompositionBuilder.build(project: snapshot, paths: paths, options: .preview(for: snapshot))
                guard !Task.isCancelled else { return }
                self.renderBox = built.renderBox
                built.renderBox.update(self.project)
                self.missingMediaCount = built.missingMediaCount
                self.playback.load(built, keepTime: self.playback.currentTime)
            } catch {
                if !Task.isCancelled {
                    self.lastSignature = nil
                    self.alert = AlertInfo(title: "Preview problem", message: "The preview couldn't be updated. \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: Feedback

    func showToast(_ message: String) {
        toast = message
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            withAnimation { self?.toast = nil }
        }
    }

    func show(_ error: Error) {
        if let app = error as? AppError, case .cancelled = app { return }
        alert = AlertInfo(error: error)
        Haptics.warning()
    }

    /// Runs long work behind a progress HUD; the UI stays responsive.
    func runBusy(_ message: String, cancellable: Bool = true, _ work: @escaping @MainActor () async throws -> Void) {
        busyTask?.cancel()
        busy = BusyState(message: message, progress: nil, cancellable: cancellable)
        busyTask = Task { [weak self] in
            do {
                try await work()
            } catch {
                if !(error is CancellationError) { self?.show(error) }
            }
            self?.busy = nil
        }
    }

    func cancelBusy() {
        busyTask?.cancel()
        busy = nil
    }

    func setBusyProgress(_ value: Double) {
        busy?.progress = value
    }

    // MARK: Thumbnails for the home screen

    private func scheduleThumbnailWrite() {
        guard thumbnailWriteTask == nil else { return }
        thumbnailWriteTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            self?.writeThumbnail()
            self?.thumbnailWriteTask = nil
        }
    }

    func writeThumbnail() {
        let resolver = MediaResolver(paths: paths, media: project.media, preferProxy: true)
        let dest = paths.thumbnailFile
        let store = self.store
        guard let first = project.clips.first ?? project.overlayClips.first,
              let url = first.isImage ? resolver.imageURL(for: first.mediaID) : resolver.videoURL(for: first) else {
            try? FileManager.default.removeItem(at: dest)
            return
        }
        let time = first.sourceStart + min(0.5, first.sourceDuration / 2)
        let isImage = first.isImage
        Task.detached(priority: .utility) {
            if let img = await ThumbnailCache.posterFrame(url: url, time: time, isImage: isImage),
               let data = img.jpegData(compressionQuality: 0.8) {
                try? data.write(to: dest, options: .atomic)
                await MainActor.run { store.noteThumbnailChanged() }
            }
        }
    }

    // MARK: Selection helpers

    var currentTime: Double { playback.currentTime }

    func selectionExists(_ sel: TimelineSelection?) -> Bool {
        guard let sel else { return false }
        switch sel {
        case .clip(let id): return project.clips.contains { $0.id == id }
        case .overlayClip(let id): return project.overlayClips.contains { $0.id == id }
        case .overlay(let id): return project.overlays.contains { $0.id == id }
        case .text(let id): return project.texts.contains { $0.id == id }
        case .audio(let id): return project.audioClips.contains { $0.id == id }
        case .caption(let id): return project.captions.segments.contains { $0.id == id }
        }
    }

    var selectedClip: Clip? {
        switch selection {
        case .some(.clip(let id)): return project.clips.first { $0.id == id }
        case .some(.overlayClip(let id)): return project.overlayClips.first { $0.id == id }
        default: return nil
        }
    }

    var selectedText: TextItem? {
        if case .text(let id)? = selection { return project.texts.first { $0.id == id } }
        return nil
    }

    var selectedOverlay: OverlayItem? {
        if case .overlay(let id)? = selection { return project.overlays.first { $0.id == id } }
        return nil
    }

    var selectedAudio: AudioClip? {
        if case .audio(let id)? = selection { return project.audioClips.first { $0.id == id } }
        return nil
    }

    var selectedCaption: CaptionSegment? {
        if case .caption(let id)? = selection { return project.captions.segments.first { $0.id == id } }
        return nil
    }

    func media(_ id: UUID?) -> MediaItem? { project.mediaItem(id) }

    func select(_ sel: TimelineSelection?) {
        if sel != selection {
            selection = sel
            if sel != nil { Haptics.tap() }
            scheduleStateSave()
        }
        if sel == nil { activePanel = nil }
    }

    func beats(for mediaID: UUID) -> [Double]? {
        beatCache[mediaID] ?? project.mediaItem(mediaID)?.beats
    }

    /// Beat markers in timeline time across all music clips.
    var timelineBeats: [Double] {
        var result: [Double] = []
        for a in project.audioClips {
            guard let beats = beats(for: a.mediaID) else { continue }
            for b in beats where b >= a.sourceStart && b <= a.sourceEnd {
                result.append(a.timelineStart + (b - a.sourceStart) / a.speed.clamped(0.1, 8))
            }
        }
        return result.sorted()
    }

    var resolver: MediaResolver {
        MediaResolver(paths: paths, media: project.media, preferProxy: true)
    }
}
