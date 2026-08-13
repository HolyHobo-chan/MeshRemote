import Foundation
import Observation

/// Per-server device list preferences: favorites and which groups are collapsed.
/// Entirely local to this device — nothing here is sent to the MeshCentral
/// server or depends on any server-side configuration. Keys are namespaced by
/// profile so two servers with similar group names don't collide.
@Observable
final class DeviceListPreferences {
    private let favoritesKey: String
    private let collapsedKey: String

    private(set) var favorites: Set<String> = []          // node ids
    private(set) var collapsedGroups: Set<String> = []    // section ids

    init(profileId: UUID) {
        favoritesKey = "meshremote.favorites.\(profileId.uuidString)"
        collapsedKey = "meshremote.collapsed.\(profileId.uuidString)"
        favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        collapsedGroups = Set(UserDefaults.standard.stringArray(forKey: collapsedKey) ?? [])
    }

    func isFavorite(_ nodeId: String) -> Bool { favorites.contains(nodeId) }

    func toggleFavorite(_ nodeId: String) {
        if favorites.contains(nodeId) {
            favorites.remove(nodeId)
        } else {
            favorites.insert(nodeId)
        }
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
    }

    func isCollapsed(_ groupId: String) -> Bool { collapsedGroups.contains(groupId) }

    func toggleCollapsed(_ groupId: String) {
        if collapsedGroups.contains(groupId) {
            collapsedGroups.remove(groupId)
        } else {
            collapsedGroups.insert(groupId)
        }
        UserDefaults.standard.set(Array(collapsedGroups), forKey: collapsedKey)
    }

    func expandAll() {
        collapsedGroups.removeAll()
        UserDefaults.standard.set([String](), forKey: collapsedKey)
    }
}
