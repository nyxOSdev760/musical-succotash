import Foundation
import SwiftUI
import PhotosUI
import AVFoundation

/// Importing media, recording, captions and derived-media processing.
extension EditorViewModel {
    // MARK: Photos picker

    func presentPicker(_ target: PickerTarget) {
        pickerTarget = target
        pickerItems = []
        showMediaPicker = true
    }

    func handlePicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        let target = pickerTarget
        let paths = self.paths
        runBusy("Importing…") { [weak self] in
            guard let self else { return }
            let result = await MediaImportService.importPickerItems(items, into: paths) { index, count in
                self.busy?.message = count > 1 ? "Importing \(min(index + 1, count)) of \(count)…" : "Importing…"
                self.busy?.progress = count > 0 ? Double(index) / Double(count) : nil
            }
            try Task.checkCancellation()
            if !result.items.isEmpty {
                self.insertImported(result.items, target: target)
            }
            if !result.failures.isEmpty {
                self.alert = AlertInfo(title: result.items.isEmpty ? "Couldn't import" : "Some items were skipped",
                                       message: result.failures.joined(separator: "\n"))
            }
        }
        pickerItems = []
    }

    func insertImported(_ items: [MediaItem], target: PickerTarget) {
        let wasEmpty = project.clips.isEmpty
        var newSelection: TimelineSelection?
        perform(target == .mainTrack ? "Add Media" : "Add Overlay") { p in
            p.media.append(contentsOf: items)
            if target == .mainTrack {
                if wasEmpty, autoAspectOnFirstImport, let first = items.first(where: { $0.kind != .audio }) {
                    p.canvas.aspect = AspectRatio.bestMatch(for: first.size)
                }
                var cursor = p.clips.last?.timelineEnd ?? 0
                for m in items where m.kind != .audio {
                    var clip = Clip(media: m, at: cursor)
                    clip.fit = .fit
                    p.clips.append(clip)
                    cursor = clip.timelineEnd
                    if newSelection == nil { newSelection = .clip(clip.id) }
                }
                p.normalizeMainTrack()
            } else {
                let start = currentTime
                for (index, m) in items.enumerated() where m.kind != .audio {
                    if m.kind == .image {
                        var o = OverlayItem(kind: .image, start: start)
                        o.imageMediaID = m.id
                        o.transform.x = Double(index) * 0.05
                        o.transform.y = Double(index) * 0.05
                        p.overlays.append(o)
                        newSelection = .overlay(o.id)
                    } else {
                        var clip = Clip(media: m, at: start)
                        clip.transform.scale = 0.5
                        clip.transform.x = 0.2
                        clip.transform.y = -0.2
                        p.overlayClips.append(clip)
                        newSelection = .overlayClip(clip.id)
                    }
                }
            }
        }
        autoAspectOnFirstImport = false
        if target == .overlay, let newSelection { selection = newSelection }
        if wasEmpty && target == .mainTrack {
            playback.currentTime = 0
            showToast("Tap ▶︎ to preview · Tap a clip to edit it")
        }
        Haptics.success()
        makeProxies(for: items)
    }

    func makeProxies(for items: [MediaItem]) {
        let paths = self.paths
        for m in items where m.kind == .video && m.width * m.height > MediaImportService.proxyThreshold {
            Task.detached(priority: .utility) { [weak self] in
                if await MediaImportService.makeProxyIfNeeded(for: m, paths: paths) != nil {
                    await MainActor.run { self?.rebuild(force: true) }
                }
            }
        }
    }

    /// Regenerates proxies and beat data that may be missing (e.g. after a crash).
    func ensureDerivedMedia() {
        makeProxies(for: project.media.filter { m in
            !FileManager.default.fileExists(atPath: paths.cache(MediaResolver.proxyName(m)).path)
        })
        for m in project.media where m.kind == .audio && beats(for: m.id) == nil {
            if project.audioClips.contains(where: { $0.mediaID == m.id && $0.kind == .music }) {
                analyzeBeats(m)
            }
        }
    }

    // MARK: Music

    func importMusic(_ url: URL) {
        let paths = self.paths
        runBusy("Adding music…") { [weak self] in
            guard let self else { return }
            let media = try await MediaImportService.importAudio(from: url, into: paths, move: false)
            let start = self.project.clips.isEmpty ? 0 : min(self.currentTime, max(self.project.duration - 1, 0))
            var audio = AudioClip(mediaID: media.id, name: media.originalName, kind: .music,
                                  timelineStart: start, sourceStart: 0, sourceEnd: media.duration)
            if self.project.duration > 1 {
                audio.sourceEnd = min(media.duration, max(self.project.duration - start, 1))
                audio.fadeOut = min(1.0, audio.duration / 4)
            }
            self.perform("Add Music") { p in
                p.media.append(media)
                p.audioClips.append(audio)
            }
            self.selection = .audio(audio.id)
            Haptics.success()
            self.analyzeBeats(media)
        }
    }

    func analyzeBeats(_ media: MediaItem) {
        let url = paths.media(media.fileName)
        Task.detached(priority: .utility) { [weak self] in
            guard let env = try? await WaveformGenerator.envelope(url: url) else { return }
            let beats = BeatDetector.detect(envelope: env)
            await MainActor.run {
                guard let self else { return }
                self.beatCache[media.id] = beats
                self.updateSilently { p in
                    if let i = p.media.firstIndex(where: { $0.id == media.id }) { p.media[i].beats = beats }
                }
                if !beats.isEmpty { self.showToast("\(beats.count) beats found — cuts will snap to them") }
            }
        }
    }

    /// Splits the main-track clip under each beat (within the music's range).
    func cutToBeats() {
        guard let audio = selectedAudio, let beats = beats(for: audio.mediaID), !beats.isEmpty else {
            showToast("No beats detected yet")
            return
        }
        let times = beats.map { audio.timelineStart + ($0 - audio.sourceStart) / audio.speed.clamped(0.1, 8) }
            .filter { $0 > audio.timelineStart && $0 < audio.timelineEnd }
        var cuts = 0
        perform("Cut to Beats") { p in
            for t in times {
                if let clip = p.clips.first(where: { $0.contains(t) }), Self.split(&p, clipID: clip.id, at: t) != nil {
                    cuts += 1
                }
            }
        }
        showToast(cuts > 0 ? "Added \(cuts) cuts on the beat" : "No clips under the beats")
    }

    // MARK: Voiceover

    func toggleVoiceover() {
        if recorder.isRecording {
            stopVoiceover()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            guard await Permissions.microphone() else {
                self.show(AppError.permissionDenied(.microphone))
                return
            }
            do {
                try StorageGuard.ensure(20 * 1024 * 1024)
                try self.paths.ensureDirectories()
                let url = self.paths.media("vo_\(UUID().uuidString).m4a")
                self.voiceoverStart = self.currentTime
                try self.recorder.start(to: url)
                self.playback.player.isMuted = true
                if self.playback.hasItem { self.playback.play() }
                Haptics.action()
            } catch {
                self.show(error)
            }
        }
    }

    func stopVoiceover() {
        playback.pause()
        playback.player.isMuted = false
        guard let recording = recorder.stop() else { return }
        let url = recording.0, duration = recording.1
        let media = MediaItem(fileName: url.lastPathComponent, proxyFileName: nil, originalName: "Voiceover",
                              kind: .audio, duration: duration, width: 0, height: 0, hasAudio: true, hasVideo: false,
                              frameRate: 0, beats: nil)
        let audio = AudioClip(mediaID: media.id, name: "Voiceover", kind: .voiceover,
                              timelineStart: voiceoverStart, sourceStart: 0, sourceEnd: duration)
        perform("Record Voiceover") { p in
            p.media.append(media)
            p.audioClips.append(audio)
        }
        selection = .audio(audio.id)
        Haptics.success()
    }

    // MARK: Captions

    func generateCaptions(locale: Locale, style: CaptionStyle) {
        let snapshot = project
        let paths = self.paths
        runBusy("Listening for speech…") { [weak self] in
            guard let self else { return }
            let exporter = ExportService()
            let audioURL: URL
            do {
                audioURL = try await exporter.exportAudio(project: snapshot, paths: paths, includeMusic: false)
            } catch {
                throw AppError.speechUnavailable("There's no speech to caption. Add a video with sound or record a voiceover first.")
            }
            defer { try? FileManager.default.removeItem(at: audioURL) }
            try Task.checkCancellation()
            self.busy?.message = "Writing captions…"
            let words = try await CaptionService.transcribe(audioURL: audioURL, locale: locale)
            try Task.checkCancellation()
            guard !words.isEmpty else {
                self.alert = AlertInfo(title: "No speech found", message: "Cutline couldn't hear any speech in this project.")
                return
            }
            let segments = CaptionService.segments(from: words)
            self.perform("Auto Captions") { p in
                p.captions.segments = segments
                p.captions.style = style
                p.captions.verticalPosition = style.defaultVerticalPosition
            }
            self.showToast("\(segments.count) captions added")
            Haptics.success()
        }
    }

    func setCaptionStyle(_ style: CaptionStyle) {
        perform("Caption Style") { p in
            p.captions.style = style
            p.captions.verticalPosition = style.defaultVerticalPosition
        }
    }

    func updateCaptionText(_ id: UUID, text: String) {
        perform("Edit Caption", coalesce: "caption-\(id)") { p in
            if let i = p.captions.segments.firstIndex(where: { $0.id == id }) {
                p.captions.segments[i].setText(text)
            }
        }
    }

    func removeAllCaptions() {
        perform("Remove Captions") { $0.captions.segments.removeAll() }
        if case .caption? = selection { selection = nil }
    }

    // MARK: Derived media (reverse, denoise, stabilize, freeze)

    func toggleReverse() {
        guard let clip = selectedClip, !clip.isImage, let m = media(clip.mediaID) else {
            showToast("Photos can't be reversed")
            return
        }
        let paths = self.paths
        let revVideo = paths.cache(MediaResolver.reversedVideoName(m))
        let needsWork = !clip.reversed && !FileManager.default.fileExists(atPath: revVideo.path)
        let apply: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            self.updateClip(clip.id, clip.reversed ? "Unreverse" : "Reverse") { c in
                let d = m.duration
                let newStart = max(0, d - c.sourceEnd)
                let newEnd = min(d, d - c.sourceStart)
                c.sourceStart = newStart
                c.sourceEnd = max(newEnd, newStart + 0.1)
                c.reversed.toggle()
                c.effects.stabilize = false
                c.effects.stabilization = nil
            }
            self.rebuild(force: true)
            Haptics.success()
        }
        guard needsWork else {
            apply()
            return
        }
        runBusy("Reversing…") { [weak self] in
            guard let self else { return }
            guard let original = MediaResolver(paths: paths, media: self.project.media, preferProxy: false).originalURL(m) else {
                throw AppError.missingMedia(m.originalName)
            }
            let progressSink: @Sendable (Double) -> Void = { value in
                Task { @MainActor [weak self] in self?.busy?.progress = value * 0.85 }
            }
            try await DerivedMediaService.reverseVideo(source: original, destination: revVideo, progress: progressSink)
            let proxy = paths.cache(MediaResolver.proxyName(m))
            if FileManager.default.fileExists(atPath: proxy.path) {
                try await DerivedMediaService.reverseVideo(source: proxy, destination: paths.cache(MediaResolver.reversedProxyName(m))) { _ in }
            }
            if m.hasAudio {
                self.busy?.message = "Reversing audio…"
                try? await DerivedMediaService.reverseAudio(source: original, destination: paths.cache(MediaResolver.reversedAudioName(m)))
            }
            AssetCache.shared.invalidate(revVideo)
            apply()
        }
    }

    func toggleDenoise() {
        if let audio = selectedAudio {
            setDenoise(mediaID: audio.mediaID, reversed: audio.reversed, enable: !audio.denoise) { [weak self] in
                self?.updateAudio(audio.id, audio.denoise ? "Noise Reduction Off" : "Noise Reduction") { $0.denoise.toggle() }
            }
        } else if let clip = selectedClip, !clip.isImage {
            setDenoise(mediaID: clip.mediaID, reversed: clip.reversed, enable: !clip.denoise) { [weak self] in
                self?.updateClip(clip.id, clip.denoise ? "Noise Reduction Off" : "Noise Reduction") { $0.denoise.toggle() }
            }
        }
    }

    private func setDenoise(mediaID: UUID, reversed: Bool, enable: Bool, apply: @escaping @MainActor () -> Void) {
        guard let m = media(mediaID), m.hasAudio else {
            showToast("This clip has no audio")
            return
        }
        let paths = self.paths
        let dest = paths.cache(MediaResolver.denoisedName(m, reversed: reversed))
        guard enable, !FileManager.default.fileExists(atPath: dest.path) else {
            apply()
            rebuild(force: true)
            return
        }
        runBusy("Reducing noise…") { [weak self] in
            guard let self else { return }
            let source: URL
            if reversed {
                source = paths.cache(MediaResolver.reversedAudioName(m))
            } else {
                source = paths.media(m.fileName)
            }
            guard FileManager.default.fileExists(atPath: source.path) else { throw AppError.missingMedia(m.originalName) }
            try await DerivedMediaService.denoise(source: source, destination: dest)
            apply()
            self.rebuild(force: true)
            self.showToast("Background noise reduced")
            Haptics.success()
        }
    }

    func stabilizeSelected() {
        guard let clip = selectedClip, !clip.isImage else { return }
        if clip.effects.stabilize {
            updateClip(clip.id, "Stabilize Off") { $0.effects.stabilize = false }
            return
        }
        if clip.effects.stabilization != nil {
            updateClip(clip.id, "Stabilize") { $0.effects.stabilize = true }
            return
        }
        guard let url = resolver.videoURL(for: clip) else {
            show(AppError.missingMedia(media(clip.mediaID)?.originalName ?? "clip"))
            return
        }
        runBusy("Analyzing motion…") { [weak self] in
            guard let self else { return }
            let sink: @Sendable (Double) -> Void = { value in
                Task { @MainActor [weak self] in self?.busy?.progress = value }
            }
            let data = try await StabilizationService.analyze(url: url, sourceStart: clip.sourceStart, sourceEnd: clip.sourceEnd, progress: sink)
            self.updateClip(clip.id, "Stabilize") { c in
                c.effects.stabilize = true
                c.effects.stabilization = data
            }
            self.showToast("Stabilized")
            Haptics.success()
        }
    }

    func freezeFrame() {
        let t = currentTime
        let target: Clip?
        if let c = selectedClip, project.clips.contains(where: { $0.id == c.id }), c.contains(t) {
            target = c
        } else {
            target = project.clips.first { $0.contains(t) }
        }
        guard let clip = target, !clip.isImage else {
            showToast("Move the playhead over a video clip")
            return
        }
        let local = t - clip.timelineStart
        let sourceTime = clip.sourceTime(atLocal: local)
        let fullResolver = MediaResolver(paths: paths, media: project.media, preferProxy: false)
        guard let url = fullResolver.videoURL(for: clip) else {
            show(AppError.missingMedia(media(clip.mediaID)?.originalName ?? "clip"))
            return
        }
        let paths = self.paths
        runBusy("Freezing frame…", cancellable: false) { [weak self] in
            guard let self else { return }
            let cg = try await DerivedMediaService.frame(url: url, at: sourceTime)
            let media = try MediaImportService.importImage(cgImage: cg, originalName: "Freeze frame", into: paths)
            var freeze = Clip(media: media, at: t, imageDuration: 2)
            freeze.crop = clip.crop
            freeze.quarterTurns = clip.quarterTurns
            freeze.flipH = clip.flipH
            freeze.flipV = clip.flipV
            freeze.fit = clip.fit
            freeze.filter = clip.filter
            freeze.transform = KeyframeMath.transform(base: clip.transform, keyframes: clip.keyframes, at: local)
            freeze.effects.chromaKey = clip.effects.chromaKey
            freeze.effects.removeBackground = clip.effects.removeBackground
            self.perform("Freeze Frame") { p in
                p.media.append(media)
                if local > 0.02 && local < clip.duration - 0.02 {
                    _ = Self.split(&p, clipID: clip.id, at: t)
                }
                for i in p.clips.indices where p.clips[i].timelineStart >= t - 0.0001 {
                    p.clips[i].timelineStart += freeze.duration
                }
                let index = p.clips.firstIndex { $0.timelineStart >= t } ?? p.clips.count
                freeze.timelineStart = t
                p.clips.insert(freeze, at: index)
                p.normalizeMainTrack()
            }
            self.selection = .clip(freeze.id)
            Haptics.success()
        }
    }
}
