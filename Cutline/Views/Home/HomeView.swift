import SwiftUI
import PhotosUI

struct HomeView: View {
    @Environment(ProjectStore.self) private var store
    @State private var editor: EditorViewModel?
    @State private var search = ""
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var pendingAspect: AspectRatio?
    @State private var renaming: ProjectSummary?
    @State private var renameText = ""
    @State private var deleting: ProjectSummary?
    @State private var alert: AlertInfo?
    @State private var didRestoreSession = false

    private var filtered: [ProjectSummary] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.summaries }
        return store.summaries.filter { $0.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    templates
                    if store.hasLoaded && store.summaries.isEmpty {
                        emptyState
                    } else {
                        projectGrid
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 40)
            }
            .background(Color.black)
            .navigationTitle("Cutline")
            .searchable(text: $search, prompt: "Search projects")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Haptics.action()
                        pendingAspect = nil
                        showPicker = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 18, weight: .bold))
                            .frame(width: 40, height: 40)
                            .background(Theme.accent, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("New project")
                }
            }
        }
        .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 50,
                      selectionBehavior: .ordered, matching: .any(of: [.videos, .images]))
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            createProject(with: items)
            pickerItems = []
        }
        .fullScreenCover(item: $editor) { vm in
            EditorView(vm: vm) {
                vm.close()
                editor = nil
            }
        }
        .alert(alert?.title ?? "", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } }), presenting: alert) { _ in
            Button("OK", role: .cancel) {}
        } message: { info in
            Text(info.message)
        }
        .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $renameText)
            Button("Cancel", role: .cancel) {}
            Button("Save") {
                if let p = renaming {
                    Task { await store.rename(p.id, to: renameText) }
                }
            }
        }
        .confirmationDialog("Delete “\(deleting?.name ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete project", role: .destructive) {
                if let p = deleting {
                    Haptics.warning()
                    Task { await store.delete(p.id) }
                }
            }
        } message: {
            Text("The project and its imported media will be removed from this device. Your originals in Photos aren't affected.")
        }
        .task {
            await store.refresh()
            restoreSessionIfNeeded()
        }
        .onChange(of: editor == nil) { _, closed in
            if closed { Task { await store.refresh() } }
        }
    }

    // MARK: Sections

    private var templates: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Start a new video").font(.headline)
            HStack(spacing: 10) {
                templateButton(.portrait9x16, title: "9:16", subtitle: "TikTok · Reels · Shorts")
                templateButton(.square1x1, title: "1:1", subtitle: "Square")
                templateButton(.landscape16x9, title: "16:9", subtitle: "YouTube")
            }
        }
        .padding(.top, 6)
    }

    private func templateButton(_ aspect: AspectRatio, title: String, subtitle: String) -> some View {
        Button {
            Haptics.action()
            pendingAspect = aspect
            showPicker = true
        } label: {
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Theme.accent, lineWidth: 2.5)
                    .aspectRatio(aspect.ratio, contentMode: .fit)
                    .frame(height: 44)
                Text(title).font(.headline)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(Theme.secondaryText)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity, minHeight: 124)
            .padding(.vertical, 6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(PressableStyle())
        .foregroundStyle(.white)
        .accessibilityLabel("New \(title) project for \(subtitle)")
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "film.stack")
                .font(.system(size: 46))
                .foregroundStyle(Theme.accent)
            Text("Make your first video").font(.title3.bold())
            Text("Pick a format above, or tap + and choose your clips. Cutline lays them out so you can edit right away.")
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondaryText)
            Button {
                pendingAspect = nil
                showPicker = true
            } label: {
                Label("Choose videos & photos", systemImage: "photo.on.rectangle.angled")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .frame(height: 50)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 40)
    }

    private var projectGrid: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(search.isEmpty ? "Projects" : "Results").font(.headline)
            if filtered.isEmpty && !search.isEmpty {
                Text("No projects match “\(search)”.").foregroundStyle(Theme.secondaryText)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 16) {
                ForEach(filtered) { summary in
                    ProjectCard(summary: summary, revision: store.thumbnailRevision)
                        .onTapGesture { open(summary) }
                        .contextMenu {
                            Button {
                                renameText = summary.name
                                renaming = summary
                            } label: { Label("Rename", systemImage: "pencil") }
                            Button {
                                Task {
                                    do { try await store.duplicate(summary.id) } catch { alert = AlertInfo(error: error) }
                                }
                            } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
                            Button(role: .destructive) {
                                deleting = summary
                            } label: { Label("Delete", systemImage: "trash") }
                        }
                }
            }
        }
    }

    // MARK: Actions

    private func open(_ summary: ProjectSummary) {
        Haptics.tap()
        if summary.isCorrupted {
            alert = AlertInfo(title: "Can't open project", message: AppError.corruptedProject.errorDescription ?? "")
            deleting = summary
            return
        }
        do {
            let (project, recovered) = try store.load(summary.id)
            editor = EditorViewModel(project: project, store: store, recovered: recovered)
        } catch {
            alert = AlertInfo(error: error)
        }
    }

    private func createProject(with items: [PhotosPickerItem]) {
        do {
            let project = try store.createProject(aspect: pendingAspect ?? .portrait9x16)
            let vm = EditorViewModel(project: project, store: store, autoAspect: pendingAspect == nil)
            vm.pickerTarget = .mainTrack
            editor = vm
            vm.handlePicked(items)
            Task { await store.refresh() }
        } catch {
            alert = AlertInfo(error: error)
        }
    }

    /// Reopens the project that was open when the app last quit unexpectedly.
    private func restoreSessionIfNeeded() {
        guard !didRestoreSession, editor == nil else { return }
        didRestoreSession = true
        guard let idString = UserDefaults.standard.string(forKey: EditorViewModel.sessionKey),
              let id = UUID(uuidString: idString) else { return }
        guard store.exists(id), let loaded = try? store.load(id) else {
            UserDefaults.standard.removeObject(forKey: EditorViewModel.sessionKey)
            return
        }
        let vm = EditorViewModel(project: loaded.0, store: store, recovered: loaded.1)
        vm.openingToast = "Restored where you left off"
        editor = vm
    }
}

struct ProjectCard: View {
    let summary: ProjectSummary
    let revision: Int
    @State private var image: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                Theme.card
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: summary.isCorrupted ? "exclamationmark.triangle" : "film")
                        .font(.system(size: 30))
                        .foregroundStyle(summary.isCorrupted ? .yellow : Theme.secondaryText)
                }
            }
            .frame(height: 190)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(alignment: .topTrailing) {
                Text(summary.aspect.title)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
            .overlay(alignment: .bottomTrailing) {
                if summary.duration > 0 {
                    Text(TimeFormat.clock(summary.duration))
                        .font(.caption2.bold().monospacedDigit())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                }
            }
            Text(summary.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text(summary.modifiedAt, format: .relative(presentation: .named))
                .font(.caption)
                .foregroundStyle(Theme.secondaryText)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the project. Touch and hold for more options.")
        .task(id: "\(summary.id)-\(revision)-\(summary.modifiedAt.timeIntervalSince1970)") {
            let url = summary.thumbnailURL
            image = await Task.detached(priority: .utility) { UIImage(contentsOfFile: url.path) }.value
        }
    }
}
