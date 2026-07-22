import AppKit
import DeskLayouterCore
import DeskLayouterMacOS
import Foundation

private let frameBudgetMilliseconds = 16.0
private let representativeCatalogSize = 240
private let visibleRowCount = 6

@MainActor
private final class BenchmarkProvider: InstalledApplicationsProviding {
    private let systemProvider = SystemInstalledApplicationsProvider()
    private let catalog: [InstalledApplication]

    private(set) var applicationsCallCount = 0
    private(set) var iconCallCount = 0

    init(catalog: [InstalledApplication]) {
        self.catalog = catalog
    }

    func applications() -> [InstalledApplication] {
        applicationsCallCount += 1
        return catalog
    }

    func icon(forBundleIdentifier bundleIdentifier: String) -> NSImage? {
        iconCallCount += 1
        return systemProvider.icon(forBundleIdentifier: bundleIdentifier)
    }
}

private struct PresentedRow {
    let name: String
    let bundleIdentifier: String
    let isRunning: Bool
}

private struct KeystrokeMeasurement {
    let filtering: Double
    let presentation: Double
    let iconResolution: Double

    var total: Double { filtering + presentation + iconResolution }
}

private func measure<Result>(_ operation: () -> Result) -> (result: Result, milliseconds: Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let result = operation()
    let elapsed = start.duration(to: clock.now).components
    let milliseconds = Double(elapsed.seconds) * 1_000
        + Double(elapsed.attoseconds) / 1_000_000_000_000_000
    return (result, milliseconds)
}

private func percentile(_ values: [Double], _ fraction: Double) -> Double {
    let sorted = values.sorted()
    let index = min(Int((Double(sorted.count - 1) * fraction).rounded(.up)), sorted.count - 1)
    return sorted[index]
}

private func formatted(_ value: Double) -> String {
    String(format: "%.3f", value)
}

private func printStage(_ name: String, values: [Double]) {
    print(
        "  \(name): median \(formatted(percentile(values, 0.5))) ms, "
            + "p95 \(formatted(percentile(values, 0.95))) ms, "
            + "max \(formatted(values.max() ?? 0)) ms"
    )
}

@main
private struct ApplicationPickerBenchmark {
    @MainActor
    static func main() {
        // Real installed apps supply realistic names and NSWorkspace icon work.
        // Deterministic synthetic entries fill smaller machines to 240 entries,
        // keeping the filtering workload representative and repeatable.
        let systemProvider = SystemInstalledApplicationsProvider()
        let discovery = measure { systemProvider.applications() }
        var catalog = Array(discovery.result.prefix(representativeCatalogSize))
        while catalog.count < representativeCatalogSize {
            let index = catalog.count
            catalog.append(
                InstalledApplication(
                    displayName: String(format: "Representative Application %03d.app", index),
                    bundleIdentifier: "com.example.representative.\(index)",
                    isRunning: index.isMultiple(of: 3)
                )
            )
        }

        let provider = BenchmarkProvider(catalog: catalog)

        // This deliberately reproduces the pre-fix path: every visible row asks
        // NSWorkspace for its icon during the keystroke update. It remains in the
        // diagnostic so a future regression exposes the cost the cache removed.
        let baselineMatches = ApplicationCatalog.filtered(catalog, searchText: "a")
        let uncachedIconBaseline = measure {
            for application in baselineMatches.prefix(visibleRowCount) {
                _ = provider.icon(forBundleIdentifier: application.bundleIdentifier)
            }
        }

        let store = ApplicationPickerStore(provider: provider)
        let initialLoad = measure { store.refresh() }
        let providerIconCallsAfterLoad = provider.iconCallCount

        let queries = ["a", "ap", "app", "appl", "application"]
        var measurements: [KeystrokeMeasurement] = []
        var resultChecksum = 0
        for _ in 0..<20 {
            for query in queries {
                let filtering = measure {
                    ApplicationCatalog.filtered(store.applications, searchText: query)
                }
                let presentation = measure {
                    filtering.result.prefix(visibleRowCount).map {
                        PresentedRow(
                            name: $0.presentedName,
                            bundleIdentifier: $0.bundleIdentifier,
                            isRunning: $0.isRunning
                        )
                    }
                }
                let icons = measure {
                    for row in presentation.result {
                        _ = store.icon(forBundleIdentifier: row.bundleIdentifier)
                        resultChecksum &+= row.name.count + (row.isRunning ? 1 : 0)
                    }
                }
                measurements.append(
                    KeystrokeMeasurement(
                        filtering: filtering.milliseconds,
                        presentation: presentation.milliseconds,
                        iconResolution: icons.milliseconds
                    )
                )
            }
        }

        let filteringValues = measurements.map(\.filtering)
        let presentationValues = measurements.map(\.presentation)
        let iconValues = measurements.map(\.iconResolution)
        let totalValues = measurements.map(\.total)
        let catalogWasNotRediscovered = provider.applicationsCallCount == 1
        let iconsStayedCached = provider.iconCallCount == providerIconCallsAfterLoad
        let worstKeystroke = totalValues.max() ?? .infinity

        print("Application picker input-to-results benchmark")
        print("  catalog: \(catalog.count) applications (\(discovery.result.count) discovered on this Mac)")
        print("  initial system discovery: \(formatted(discovery.milliseconds)) ms")
        print("  initial snapshot + icon preload: \(formatted(initialLoad.milliseconds)) ms")
        print("  uncached visible-row icons (pre-fix path): \(formatted(uncachedIconBaseline.milliseconds)) ms")
        print("  measured keystrokes: \(measurements.count); visible rows: \(visibleRowCount)")
        printStage("in-memory filtering", values: filteringValues)
        printStage("result presentation", values: presentationValues)
        printStage("cached icon lookup", values: iconValues)
        printStage("full application-owned update", values: totalValues)
        print("  catalog discovery calls during load + typing: \(provider.applicationsCallCount)")
        print("  icon resolver calls added during typing: \(provider.iconCallCount - providerIconCallsAfterLoad)")

        guard catalogWasNotRediscovered else {
            fatalError("Catalog discovery reran while measuring search keystrokes")
        }
        guard iconsStayedCached else {
            fatalError("Application icons were resolved again while measuring search keystrokes")
        }
        guard worstKeystroke < frameBudgetMilliseconds else {
            fatalError(
                "Picker update exceeded the \(formatted(frameBudgetMilliseconds)) ms frame budget: "
                    + "\(formatted(worstKeystroke)) ms"
            )
        }
        precondition(resultChecksum > 0)
        print("PASS: every measured application-owned update stayed within the 16 ms frame budget")
    }
}
