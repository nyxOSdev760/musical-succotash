# Cutline

Cutline is a video editor for iPhone and iPad. It is written in Swift and SwiftUI and uses AVFoundation, Core Image, Metal, Speech and Vision. It needs iOS 17 or later.

There are no accounts, ads, watermarks or network calls. All processing happens on the device.

- **Unsigned IPA:** `dist/Cutline.ipa`. CI rebuilds it on every push.
- **Xcode project:** `Cutline.xcodeproj`. It needs Xcode 16 or later because it uses synchronized folders.
- **Full source listing:** `SOURCE.md` has the file tree followed by every file in full.

## Building

```bash
open Cutline.xcodeproj                      # then Product › Run (choose your team under Signing)
# or, unsigned from the command line:
xcodebuild -project Cutline.xcodeproj -scheme Cutline -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' -derivedDataPath build \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" build
mkdir -p Payload && cp -R build/Build/Products/Release-iphoneos/Cutline.app Payload/
zip -qry Cutline.ipa Payload
```

The workflow in `.github/workflows/build-ios.yml` runs the same steps on a macOS runner with Xcode 16.4 and the iOS 18.5 SDK. It uploads the IPA as an artifact and also commits it to `dist/`.

The IPA is **not signed**. To install it on a device, re-sign it with your own Apple ID or certificate, for example with Xcode, Sideloadly or AltStore.

`tools/make_xcodeproj.py` regenerates the Xcode project and `tools/make_icon.py` regenerates the app icon. Every file under `Cutline/` is added to the target automatically.

## Architecture (MVVM)

```
Views (SwiftUI)  ──▶  ViewModels (@Observable, @MainActor)  ──▶  Services / Rendering
HomeView              EditorViewModel (+Editing, +Media)         ProjectStore, AutosaveService
EditorView            PlaybackController                         MediaImportService, ThumbnailCache
TimelineView          TimelineInteraction (UIKit gestures)       WaveformGenerator, BeatDetector
Panels/*              ExportViewModel                            CaptionService, ExportService
                                                                 ProjectUndoManager, DerivedMediaService
                                                                 StabilizationService, VoiceoverRecorder
                                                                 CompositionBuilder → AVMutableComposition
                                                                 CutlineCompositor (AVVideoCompositing)
                                                                 FrameRenderer, FilterEngine, TextRenderer,
                                                                 TransitionRenderer, Kernels.metal
```

- **Model.** `Project` is a single `Codable` value. It holds the media, the main-track `clips`, `overlayClips` (picture in picture), `overlays` (photos, stickers and shapes), `texts`, `audioClips`, `captions`, the canvas settings, the whole-timeline filter and the editor state (playhead, zoom and selection).
- **Edits.** Every change goes through `EditorViewModel.perform(_:)`. That one function records an undo snapshot, autosaves and refreshes the preview. Slider drags and gestures use `beginInteractive` / `updateInteractive` / `endInteractive`, so a whole drag becomes one undo step while the preview updates live.
- **Rendering.** `CompositionBuilder` builds an `AVMutableComposition`:
  - A black "timing backbone" track covers the full timeline.
  - Clips are packed onto pooled tracks.
  - Speed segments are applied with `scaleTimeRange`. Speed ramps are split into 12 segments.
  - Transition handles are added, using a held frame when there is no spare footage.
  - An `AVMutableAudioMix` handles volume and fades.

  `CutlineCompositor` renders every frame with Core Image on a Metal-backed `CIContext`. That covers stabilization, chroma key (a Metal CI kernel), Vision person segmentation, filters, crop, rotate and flip, fit or fill with a blurred background, keyframes with easing, in/out motion, transitions, the global filter, overlays, text and captions.
- **Fast preview.** Changes that only affect looks (filters, text, transforms) update a shared `RenderStateBox` and re-render the current frame without rebuilding the composition. Videos larger than 1080p get a 720p proxy for editing. Export always renders from the originals.
- **Export.** Export reads the timeline with `AVAssetReader` and writes it with `AVAssetWriter`. You choose the codec (H.264 or HEVC), 720p / 1080p / 4K, 24/30/60 fps and a quality slider that sets the bitrate. Audio-only export produces an M4A. A still frame is rendered by `AVAssetImageGenerator` with the custom compositor.

## Feature map

| Area | Where |
|---|---|
| Projects grid, search, rename/duplicate/delete, templates | `Views/Home/HomeView.swift`, `Services/ProjectStore.swift` |
| Autosave (debounced 0.6 s, on background, backup copy, crash-session restore) | `Services/AutosaveService.swift`, `ProjectFileIO`, `HomeView.restoreSessionIfNeeded` |
| Timeline: fixed playhead, pinch zoom, momentum scrub, trim handles, long-press move, double-tap split, snapping + haptics, lanes, thumbnails, waveforms, beat markers | `Views/Timeline/*` |
| Trim/split/delete/duplicate/reorder/freeze/reverse | `EditorViewModel+Editing.swift`, `+Media.swift`, `DerivedMediaService` |
| Speed 0.1×–8× + ramps (pitch preserved) | `Clip.segments()`, `SpeedPanel` |
| Crop, rotate, flip, zoom/pan, fit/fill, 9:16 · 1:1 · 4:5 · 16:9, blurred fill | `CropPanel`, `CanvasPanel`, `FrameRenderer` |
| Keyframes (position, scale, rotation, opacity) with easing curves | `Transform.swift`, `AnimatePanel` |
| Audio: volume, fades, mute, detach, voiceover, music from Files, waveform, noise reduction | `VolumePanel`, `AudioPanel`, `VoiceoverRecorder`, `DerivedMediaService.denoise` |
| Auto beat markers + "Beat Cuts" | `BeatDetector`, `EditorViewModel.cutToBeats` |
| Text: system font picker with live preview, size, color, outline, shadow, box, alignment, fade/pop/slide/typewriter | `TextPanel`, `TextRenderer`, `FrameRenderer.textLayer` |
| Auto captions (on-device, word timing, editable, 3 styles) | `CaptionService`, `CaptionsPanel` |
| Overlays: photos, video PiP, stickers, shapes | `OverlayPanel`, `OverlayStylePanel` |
| 17 looks + 9 adjustments, per clip or whole timeline | `FilterEngine`, `EffectsPanel`, `GlobalFiltersPanel` |
| Transitions: cut, fade, dissolve, slide, zoom, spin, glitch | `TransitionRenderer`, `TransitionPanel` |
| Background removal (Vision), green screen (Metal kernel), stabilization (Vision) | `FrameRenderer`, `Kernels.metal`, `StabilizationService` |
| Copy / paste effects | `Clip.effectsPayload()`, `EffectsPanel` |
| Export + progress/cancel + background time + Photos/share, audio-only, still frame | `ExportService`, `ExportView` |
| Errors: unsupported formats, low storage, missing media, permission denials | `AppError`, `StorageGuard`, `MediaResolver`, `Permissions` |

## Notes

- Captions require on-device speech recognition for the chosen language (Settings › General › Keyboard › Dictation). Captions are never sent to a server.
- Reverse, noise reduction and stabilization write derived files into the project's `Cache/` folder. Undo/redo only switches which file a clip uses, so it's instant.
