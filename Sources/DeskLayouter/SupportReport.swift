import Foundation

/// Builds the single, public support route used by Settings and the README.
/// Keeping URL construction at this pure seam makes the prefilled diagnostic
/// prompts testable without opening a browser.
public enum SupportReport {
    public static let newIssueURL = URL(
        string: "https://github.com/Taimonania/desk-layouter/issues/new"
    )!

    public static func githubIssueURL(
        appVersion: String,
        macOSVersion: String
    ) -> URL {
        var components = URLComponents(url: newIssueURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "title", value: "Problem: "),
            URLQueryItem(
                name: "body",
                value: """
                ## Desk Layouter version
                \(appVersion)

                ## macOS version
                \(macOSVersion)

                ## Expected behavior
                <!-- What did you expect Desk Layouter to do? -->

                ## Actual behavior
                <!-- What happened instead? Include steps to reproduce if possible. -->
                """
            ),
        ]
        return components.url!
    }
}
