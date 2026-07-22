import Foundation

/// The stable, persisted identity of a physical Display.
///
/// ColorSync's UUID is the primary key. The remaining fields are last-known
/// presentation and hardware facts retained solely for a future, explicit
/// recovery flow. Runtime roles and topology facts deliberately do not belong
/// here: a Core Graphics display ID, Display number, Main role, private Spaces
/// monitor key, and geometry can all change without changing the physical
/// Display the user chose.
public struct DisplayIdentity: Codable, Equatable, Hashable, Sendable {
    public let colorSyncUUID: String
    public let lastKnownName: String
    public let vendorID: UInt32?
    public let modelID: UInt32?
    public let serialNumber: UInt32?

    public init(
        colorSyncUUID: String,
        lastKnownName: String,
        vendorID: UInt32? = nil,
        modelID: UInt32? = nil,
        serialNumber: UInt32? = nil
    ) {
        self.colorSyncUUID = colorSyncUUID
        self.lastKnownName = lastKnownName
        self.vendorID = vendorID
        self.modelID = modelID
        self.serialNumber = serialNumber
    }

    /// Physical matching intentionally uses only the primary ColorSync key.
    /// Last-known metadata may change presentation without changing the user's
    /// semantic destination.
    public func identifiesSameDisplay(as other: DisplayIdentity) -> Bool {
        colorSyncUUID.caseInsensitiveCompare(other.colorSyncUUID) == .orderedSame
    }
}

/// The semantic destination stored by one Assignment.
public struct DesktopAddress: Codable, Equatable, Sendable {
    public let display: DisplayIdentity
    public let desktopNumber: Int

    public init(display: DisplayIdentity, desktopNumber: Int) {
        self.display = display
        self.desktopNumber = desktopNumber
    }
}

/// What the most recent successful Apply wrote for one managed application.
///
/// The semantic destination lets the board detect user edits. The concrete UUID
/// lets it separately detect that macOS reminted or reordered the effective
/// Desktop while the saved Assignment itself stayed unchanged.
public struct AppliedAssignment: Codable, Equatable, Sendable {
    public let display: DisplayIdentity?
    public let desktopNumber: Int
    public let concreteDesktopUUID: String?

    public init(
        display: DisplayIdentity?,
        desktopNumber: Int,
        concreteDesktopUUID: String?
    ) {
        self.display = display
        self.desktopNumber = desktopNumber
        self.concreteDesktopUUID = concreteDesktopUUID
    }
}
