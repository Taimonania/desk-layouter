import DeskLayouterMacOS
import Foundation

// Contract tests for the `--render-scene` Acceptance-Review render mode (issue #119).
//
// Two layers, matching the spec's "exercise external behaviour, not internals":
//   1. The pure `SceneRenderArguments.parse` seam — single-key selection, `all` vs
//      single, and the normal-launch (no-flag) case that proves `runIfRequested()`
//      returns false.
//   2. The built `DeskLayouter` binary driven as a subprocess — the observable
//      contract: a non-empty PNG for a key appears at the documented path and the
//      process exits 0; an unknown key exits non-zero and lists the keys; `all`
//      renders every catalog Scene.

@main
struct SceneRenderTestRunner {
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

        // MARK: - Pure argument parsing

        check(
            "no flag is a normal launch (runIfRequested returns false)",
            SceneRenderArguments.parse(["DeskLayouter"]) == nil
        )
        check(
            "an unrelated flag is still a normal launch",
            SceneRenderArguments.parse(["DeskLayouter", "--verbose"]) == nil
        )
        check(
            "a single key selects that Scene",
            SceneRenderArguments.parse(["DeskLayouter", "--render-scene", "whats-new"]) == .key("whats-new")
        )
        check(
            "a bare --render-scene selects the whole catalog",
            SceneRenderArguments.parse(["DeskLayouter", "--render-scene"]) == .all
        )
        check(
            "--render-scene all selects the whole catalog",
            SceneRenderArguments.parse(["DeskLayouter", "--render-scene", "all"]) == .all
        )
        check(
            "--render-scene followed by another flag selects the whole catalog",
            SceneRenderArguments.parse(["DeskLayouter", "--render-scene", "--other"]) == .all
        )

        // MARK: - Subprocess: the built binary's observable contract

        // The `DeskLayouter` binary is a sibling of this test binary in the same
        // build directory.
        let appBinary = URL(fileURLWithPath: CommandLine.arguments[0])
            .deletingLastPathComponent()
            .appendingPathComponent("DeskLayouter")

        if !FileManager.default.fileExists(atPath: appBinary.path) {
            failures.append("DeskLayouter binary not found at \(appBinary.path) — run `swift build` first")
            print("  FAIL: DeskLayouter binary not found at \(appBinary.path)")
            report(failures)
        }

        /// Runs the binary in a throwaway working directory so `.build/scene-renders`
        /// is isolated per case, and returns (exit code, stderr, list of PNG files,
        /// the render directory so a case can stat a specific PNG).
        func render(_ args: [String]) -> (code: Int32, stderr: String, pngs: [String], renderDir: URL) {
            let cwd = FileManager.default.temporaryDirectory
                .appendingPathComponent("scene-render-test-\(UUID().uuidString)", isDirectory: true)
            try? FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)

            let process = Process()
            process.executableURL = appBinary
            process.arguments = args
            process.currentDirectoryURL = cwd
            let stderrPipe = Pipe()
            process.standardError = stderrPipe
            process.standardOutput = Pipe()
            do {
                try process.run()
            } catch {
                return (-1, "failed to launch: \(error)", [], cwd)
            }
            process.waitUntilExit()

            let stderr = String(
                data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            ) ?? ""

            let renderDir = cwd.appendingPathComponent(".build/scene-renders")
            let contents = (try? FileManager.default.contentsOfDirectory(atPath: renderDir.path)) ?? []
            let pngs = contents.filter { $0.hasSuffix(".png") }.sorted()
            return (process.terminationStatus, stderr, pngs, renderDir)
        }

        /// The byte size of a PNG in a render directory, or 0 if it is missing.
        func pngByteSize(_ renderDir: URL, _ name: String) -> Int {
            let path = renderDir.appendingPathComponent(name).path
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return (attributes?[.size] as? Int) ?? 0
        }

        // Single-key selection writes exactly that Scene's non-empty PNG and exits 0.
        let whatsNewResult = render(["--render-scene", "whats-new"])
        check(
            "single-key render exits 0",
            whatsNewResult.code == 0,
            "exit \(whatsNewResult.code)"
        )
        check(
            "single-key render writes a non-empty whats-new.png at the documented path",
            whatsNewResult.pngs == ["whats-new.png"]
                && pngByteSize(whatsNewResult.renderDir, "whats-new.png") > 0,
            "pngs \(whatsNewResult.pngs), size \(pngByteSize(whatsNewResult.renderDir, "whats-new.png"))"
        )

        // `all` renders every catalog Scene (which includes whats-new).
        let allResult = render(["--render-scene", "all"])
        check("--render-scene all exits 0", allResult.code == 0, "exit \(allResult.code)")
        check(
            "--render-scene all renders every catalog Scene including whats-new",
            allResult.pngs.contains("whats-new.png"),
            "pngs \(allResult.pngs)"
        )

        // A bare --render-scene matches `all`.
        let bareResult = render(["--render-scene"])
        check("bare --render-scene exits 0", bareResult.code == 0, "exit \(bareResult.code)")
        check(
            "bare --render-scene renders the same catalog as all",
            bareResult.pngs == allResult.pngs,
            "bare \(bareResult.pngs) vs all \(allResult.pngs)"
        )

        // A single key renders a subset of what `all` renders (all ⊇ single) — reusing
        // the earlier single-key render.
        check(
            "a single key renders exactly one Scene, a subset of all",
            whatsNewResult.pngs == ["whats-new.png"]
                && Set(whatsNewResult.pngs).isSubset(of: Set(allResult.pngs)),
            "single \(whatsNewResult.pngs) vs all \(allResult.pngs)"
        )

        // An unknown key exits non-zero, lists the available keys plus `all`, and
        // writes nothing.
        let unknownResult = render(["--render-scene", "does-not-exist"])
        check(
            "an unknown key exits non-zero",
            unknownResult.code != 0,
            "exit \(unknownResult.code)"
        )
        check(
            "an unknown key lists the available keys plus all",
            unknownResult.stderr.contains("whats-new") && unknownResult.stderr.contains("all"),
            unknownResult.stderr
        )
        check(
            "an unknown key writes no PNG",
            unknownResult.pngs.isEmpty,
            "pngs \(unknownResult.pngs)"
        )

        report(failures)
    }

    static func report(_ failures: [String]) -> Never {
        if failures.isEmpty {
            print("All SceneRender tests passed.")
            exit(0)
        } else {
            print("\n\(failures.count) failure(s):")
            for failure in failures { print("  - \(failure)") }
            exit(1)
        }
    }
}
