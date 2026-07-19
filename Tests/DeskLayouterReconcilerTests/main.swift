import DeskLayouterCore

@main
struct PersistentBindingReconcilerTestRunner {
    static func main() {
        var failures: [String] = []

        func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
            if condition {
                print("  ok: \(name)")
            } else {
                let detailText = detail()
                let suffix = detailText.isEmpty ? "" : " — \(detailText)"
                failures.append("\(name)\(suffix)")
                print("  FAIL: \(name)\(suffix)")
            }
        }

        // The complete post-change dictionary is a pure function of three inputs,
        // all already normalized by the adapter: the full existing store
        // dictionary, the desired managed bindings, and the set of managed-owned
        // keys. Its contract: preserve unmanaged entries exactly, add/change the
        // desired managed entries, and delete only managed-owned keys that are no
        // longer desired.

        // Empty everything yields an empty dictionary.
        do {
            let result = PersistentBindingReconciler.completeBindings(
                existing: [:],
                desiredManaged: [:],
                managedOwnedKeys: []
            )
            check("empty inputs yield an empty dictionary", result == [:], "got \(result)")
        }

        // Unmanaged entries are preserved untouched when nothing is managed.
        do {
            let result = PersistentBindingReconciler.completeBindings(
                existing: ["com.other.a": "U1", "com.other.b": "U2"],
                desiredManaged: [:],
                managedOwnedKeys: []
            )
            check(
                "unmanaged entries survive when no keys are owned",
                result == ["com.other.a": "U1", "com.other.b": "U2"],
                "got \(result)"
            )
        }

        // Add: a managed Assignment with no prior entry is added.
        do {
            let result = PersistentBindingReconciler.completeBindings(
                existing: [:],
                desiredManaged: ["com.example.a": "U1"],
                managedOwnedKeys: ["com.example.a"]
            )
            check("adds a new managed binding", result == ["com.example.a": "U1"], "got \(result)")
        }

        // Change: a managed key with an existing value is repointed to the new
        // Desktop UUID.
        do {
            let result = PersistentBindingReconciler.completeBindings(
                existing: ["com.example.a": "U1"],
                desiredManaged: ["com.example.a": "U2"],
                managedOwnedKeys: ["com.example.a"]
            )
            check("changes an existing managed binding", result == ["com.example.a": "U2"], "got \(result)")
        }

        // Remove: an owned key that is no longer desired is deleted, while an
        // unmanaged sibling stays.
        do {
            let result = PersistentBindingReconciler.completeBindings(
                existing: ["com.example.a": "U1", "com.other.keep": "UX"],
                desiredManaged: [:],
                managedOwnedKeys: ["com.example.a"]
            )
            check(
                "removes a no-longer-desired owned key but keeps unmanaged",
                result == ["com.other.keep": "UX"],
                "got \(result)"
            )
        }

        // Mixed: add/change one owned key, delete another owned key, preserve an
        // unmanaged entry — all in one pass.
        do {
            let result = PersistentBindingReconciler.completeBindings(
                existing: [
                    "com.other.unmanaged": "UX",
                    "com.example.a": "U1",
                    "com.example.b": "U2",
                ],
                desiredManaged: ["com.example.a": "U3"],
                managedOwnedKeys: ["com.example.a", "com.example.b"]
            )
            check(
                "changes one owned key, deletes another, preserves unmanaged",
                result == ["com.other.unmanaged": "UX", "com.example.a": "U3"],
                "got \(result)"
            )
        }

        // A skipped Assignment (out-of-range Desktop, so not in desiredManaged)
        // is still owned, so its stale key is deleted rather than left behind.
        do {
            let result = PersistentBindingReconciler.completeBindings(
                existing: ["com.example.a": "STALE"],
                desiredManaged: [:],
                managedOwnedKeys: ["com.example.a"]
            )
            check(
                "deletes an owned key whose Assignment was skipped",
                result == [:],
                "got \(result)"
            )
        }

        // An owned key that is neither present nor desired is a no-op; unmanaged
        // entries are still preserved.
        do {
            let result = PersistentBindingReconciler.completeBindings(
                existing: ["com.other.keep": "UX"],
                desiredManaged: [:],
                managedOwnedKeys: ["com.example.missing"]
            )
            check(
                "owning an absent, undesired key changes nothing",
                result == ["com.other.keep": "UX"],
                "got \(result)"
            )
        }

        // An unmanaged key that happens to share a UUID with a managed target is
        // still preserved — ownership, not value, decides what we touch.
        do {
            let result = PersistentBindingReconciler.completeBindings(
                existing: ["com.other.shares": "U1", "com.example.a": "U1"],
                desiredManaged: ["com.example.a": "U2"],
                managedOwnedKeys: ["com.example.a"]
            )
            check(
                "ownership, not value, decides what is preserved",
                result == ["com.other.shares": "U1", "com.example.a": "U2"],
                "got \(result)"
            )
        }

        if failures.isEmpty {
            print("Persistent binding reconciler tests passed")
        } else {
            fatalError("Persistent binding reconciler tests failed: \(failures.count) failing — \(failures.joined(separator: "; "))")
        }
    }
}
