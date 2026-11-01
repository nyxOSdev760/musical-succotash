import Foundation
import Observation

/// Unlimited snapshot-based undo/redo for project edits.
@Observable
final class ProjectUndoManager {
    private struct Entry {
        let name: String
        let project: Project
    }

    private var undoStack: [Entry] = []
    private var redoStack: [Entry] = []
    @ObservationIgnored private var lastCoalesceKey: String?
    @ObservationIgnored private var lastRecordDate = Date.distantPast

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var undoName: String? { undoStack.last?.name }
    var redoName: String? { redoStack.last?.name }

    /// Records the state *before* an edit. Rapid edits with the same coalesce key
    /// (e.g. dragging a slider) collapse into one undo step.
    func record(_ before: Project, name: String, coalesceKey: String? = nil) {
        let now = Date()
        if let key = coalesceKey, key == lastCoalesceKey, now.timeIntervalSince(lastRecordDate) < 1.5 {
            lastRecordDate = now
            return
        }
        undoStack.append(Entry(name: name, project: before))
        redoStack.removeAll()
        lastCoalesceKey = coalesceKey
        lastRecordDate = now
    }

    func breakCoalescing() {
        lastCoalesceKey = nil
    }

    func undo(current: Project) -> (Project, String)? {
        guard let entry = undoStack.popLast() else { return nil }
        redoStack.append(Entry(name: entry.name, project: current))
        lastCoalesceKey = nil
        return (entry.project, entry.name)
    }

    func redo(current: Project) -> (Project, String)? {
        guard let entry = redoStack.popLast() else { return nil }
        undoStack.append(Entry(name: entry.name, project: current))
        lastCoalesceKey = nil
        return (entry.project, entry.name)
    }
}
