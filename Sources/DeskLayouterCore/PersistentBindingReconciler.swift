/// Store-aware Apply classification. Unlike the semantic Assignment plan, this
/// is built after reading macOS and can therefore name unmanaged bindings
/// explicitly rather than treating their retention as an implicit merge detail.
public struct PersistentBindingApplyPlan: Equatable, Sendable {
    public let updates: [String: String]
    public let explicitDeletions: Set<String>
    public let unavailableDisplayPreservations: [String: String]
    public let unmanagedPreservations: [String: String]

    public var completeBindings: [String: String] {
        var complete = unmanagedPreservations
        for (key, value) in unavailableDisplayPreservations { complete[key] = value }
        for (key, value) in updates { complete[key] = value }
        return complete
    }
}

/// Computes the complete post-change persistent `app-bindings` dictionary that
/// Apply must write, without touching the real store, Dock, or WindowServer.
///
/// This is the pure seam for issue #7's core rule: Apply must build the whole
/// dictionary — preserving unmanaged entries, adding or changing the current
/// managed Assignments, and deleting only the keys owned by managed apps whose
/// Assignments were removed. Because a plain `defaults ... -dict-add` can only
/// add or replace keys, the adapter needs the full target dictionary computed
/// here so it can delete removed-managed keys too (ADR-0001).
///
/// All three inputs are expected to be pre-normalized by the adapter to the
/// lowercase key form macOS/Dock use. This function performs no normalization of
/// its own; it is deliberately pure dictionary arithmetic so it can be
/// exhaustively unit-tested with fabricated dictionaries.
public enum PersistentBindingReconciler {
    /// Classifies every existing binding against the semantic Assignment plan.
    /// Inputs use the normalized key form macOS stores. Explicit deletions win
    /// over preservation if a malformed caller overlaps categories; updates win
    /// over old stored values.
    public static func applyPlan(
        existing: [String: String],
        assignmentPlan: AssignmentApplyPlan
    ) -> PersistentBindingApplyPlan {
        let deletionKeys = assignmentPlan.deletions
        let updateKeys = Set(assignmentPlan.updates.keys)
        let unavailableKeys = assignmentPlan.preservations
            .subtracting(deletionKeys)
            .subtracting(updateKeys)
        let unavailable = existing.filter { unavailableKeys.contains($0.key) }
        let managedKeys = deletionKeys.union(updateKeys).union(unavailableKeys)
        let unmanaged = existing.filter { !managedKeys.contains($0.key) }
        return PersistentBindingApplyPlan(
            updates: assignmentPlan.updates,
            explicitDeletions: deletionKeys,
            unavailableDisplayPreservations: unavailable,
            unmanagedPreservations: unmanaged
        )
    }

    /// Multi-Display reconciliation: preserve every existing key except an
    /// explicit deletion, then overlay every resolvable update.
    public static func completeBindings(
        existing: [String: String],
        updates: [String: String],
        deletions: Set<String>
    ) -> [String: String] {
        var result = existing.filter { key, _ in !deletions.contains(key) }
        for (key, value) in updates { result[key] = value }
        return result
    }

    /// - Parameters:
    ///   - existing: the full current `app-bindings` dictionary read back from
    ///     the store (bundle-ID key → Desktop UUID).
    ///   - desiredManaged: the managed Assignments that resolved to an existing
    ///     Desktop (bundle-ID key → Desktop UUID). Its keys are always a subset
    ///     of `managedOwnedKeys`.
    ///   - managedOwnedKeys: every key the app manages — a superset of
    ///     `desiredManaged`'s keys. Owned keys absent from `desiredManaged` were
    ///     either removed by the user or skipped (Desktop no longer exists) and
    ///     must therefore be deleted.
    /// - Returns: the complete dictionary to persist: unmanaged entries
    ///   untouched, desired managed entries applied, removed-managed keys gone.
    public static func completeBindings(
        existing: [String: String],
        desiredManaged: [String: String],
        managedOwnedKeys: Set<String>
    ) -> [String: String] {
        // Start from the existing store with every managed-owned key dropped, so
        // only unmanaged entries survive from the prior state.
        var result = existing.filter { key, _ in !managedOwnedKeys.contains(key) }
        // Re-add the currently desired managed bindings (adds and changes).
        for (key, desktopUUID) in desiredManaged {
            result[key] = desktopUUID
        }
        return result
    }
}
