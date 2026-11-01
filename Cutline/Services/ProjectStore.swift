import Foundation
import Observation
import UIKit

struct ProjectPaths: Hashable, Sendable {
    let root: URL

    var projectFile: URL { root.appendingPathComponent("project.json") }
    var backupFile: URL { root.appendingPathComponent("project.backup.json") }
    var mediaDir: URL { root.appendingPathComponent("Media", isDirectory: true) }
    var cacheDir: URL { root.appendingPathComponent("Cache", isDirectory: true) }
    var thumbnailFile: URL { root.appendingPathComponent("thumbnail.jpg") }

    func media(_ name: String) -> URL { mediaDir.appendingPathComponent(name) }
    func cache(_ name: String) -> URL { cacheDir.appendingPathComponent(name) }

    func ensureDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(at: mediaDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}

struct ProjectSummary: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var modifiedAt: Date
    var aspect: AspectRatio
    var duration: Double
    var clipCount: Int
    var thumbnailURL: URL
    var isCorrupted: Bool
}

/// Reads and writes project files. All methods are safe to call from any thread.
enum ProjectFileIO {
    static func encode(_ project: Project) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(project)
    }

    static func decode(_ data: Data) throws -> Project {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Project.self, from: data)
    }

    /// Atomically writes the project, keeping the previous version as a backup.
    static func write(_ data: Data, to paths: ProjectPaths) throws {
        try paths.ensureDirectories()
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.projectFile.path),
           let current = try? Data(contentsOf: paths.projectFile),
           (try? decode(current)) != nil {
            try? current.write(to: paths.backupFile, options: .atomic)
        }
        try data.write(to: paths.projectFile, options: .atomic)
    }

    /// Loads a project, falling back to the backup if the main file is damaged.
    static func read(_ paths: ProjectPaths, id: UUID) throws -> (Project, Bool) {
        if let data = try? Data(contentsOf: paths.projectFile), var p = try? decode(data) {
            p.id = id
            return (p, false)
        }
        if let data = try? Data(contentsOf: paths.backupFile), var p = try? decode(data) {
            p.id = id
            try? data.write(to: paths.projectFile, options: .atomic)
            return (p, true)
        }
        throw AppError.corruptedProject
    }

    static func scanSummaries(root: URL) -> [ProjectSummary] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var result: [ProjectSummary] = []
        for dir in dirs {
            guard let id = UUID(uuidString: dir.lastPathComponent) else { continue }
            let paths = ProjectPaths(root: dir)
            if let loaded = try? read(paths, id: id) {
                let p = loaded.0
                result.append(ProjectSummary(id: id, name: p.name, modifiedAt: p.modifiedAt, aspect: p.canvas.aspect,
                                             duration: p.duration, clipCount: p.clips.count + p.overlayClips.count,
                                             thumbnailURL: paths.thumbnailFile, isCorrupted: false))
            } else {
                let date = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                result.append(ProjectSummary(id: id, name: "Damaged project", modifiedAt: date, aspect: .portrait9x16,
                                             duration: 0, clipCount: 0, thumbnailURL: paths.thumbnailFile, isCorrupted: true))
            }
        }
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }
}

@MainActor
@Observable
final class ProjectStore {
    private(set) var summaries: [ProjectSummary] = []
    private(set) var hasLoaded = false
    /// Bumped whenever thumbnails are rewritten, so cards reload them.
    private(set) var thumbnailRevision = 0

    let rootURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        rootURL = docs.appendingPathComponent("Projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    func paths(for id: UUID) -> ProjectPaths {
        ProjectPaths(root: rootURL.appendingPathComponent(id.uuidString, isDirectory: true))
    }

    func refresh() async {
        let root = rootURL
        let list = await Task.detached(priority: .userInitiated) { ProjectFileIO.scanSummaries(root: root) }.value
        summaries = list
        hasLoaded = true
    }

    func noteThumbnailChanged() {
        thumbnailRevision += 1
    }

    func nextProjectName() -> String {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        let base = "Edit · \(f.string(from: Date()))"
        let existing = Set(summaries.map(\.name))
        if !existing.contains(base) { return base }
        var n = 2
        while existing.contains("\(base) (\(n))") { n += 1 }
        return "\(base) (\(n))"
    }

    func createProject(aspect: AspectRatio) throws -> Project {
        let project = Project(name: nextProjectName(), aspect: aspect)
        let paths = paths(for: project.id)
        try paths.ensureDirectories()
        try ProjectFileIO.write(ProjectFileIO.encode(project), to: paths)
        return project
    }

    func load(_ id: UUID) throws -> (Project, Bool) {
        try ProjectFileIO.read(paths(for: id), id: id)
    }

    func rename(_ id: UUID, to name: String) async {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let loaded = try? load(id) else { return }
        var project = loaded.0
        project.name = trimmed
        project.modifiedAt = Date()
        if let data = try? ProjectFileIO.encode(project) {
            try? ProjectFileIO.write(data, to: paths(for: id))
        }
        await refresh()
    }

    func duplicate(_ id: UUID) async throws {
        let source = paths(for: id)
        let newID = UUID()
        let dest = paths(for: newID)
        let fm = FileManager.default
        try StorageGuard.ensure(directorySize(source.root))
        try fm.copyItem(at: source.root, to: dest.root)
        var (project, _) = try ProjectFileIO.read(dest, id: newID)
        project.id = newID
        project.name = project.name + " copy"
        project.createdAt = Date()
        project.modifiedAt = Date()
        try ProjectFileIO.write(ProjectFileIO.encode(project), to: dest)
        await refresh()
    }

    func delete(_ id: UUID) async {
        try? FileManager.default.removeItem(at: paths(for: id).root)
        await refresh()
    }

    func exists(_ id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: paths(for: id).root.path)
    }

    private func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in e {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
