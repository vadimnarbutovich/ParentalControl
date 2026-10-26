import Foundation

/// Routes an access-denied event to the foremost registered presentation surface.
/// The root stays a fallback even if SwiftUI calls its onAppear after a sheet's.
struct FamilyAccessPresentationStack {
    private var entries: [(id: UUID, isRoot: Bool)] = []

    mutating func register(_ id: UUID, isRoot: Bool) {
        unregister(id)
        entries.append((id, isRoot))
    }

    mutating func unregister(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    var presenter: UUID? {
        entries.last(where: { !$0.isRoot })?.id ?? entries.last?.id
    }
}
