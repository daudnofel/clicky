//
//  ResultsListCard.swift
//  leanring-buddy
//
//  Review-queue card variant for workflows whose
//  `output_format == "results-list"`. Renders the agent's halt payload
//  as a scrollable list of rows (one per result) with a Save / Discard
//  footer. § A.4 amendment 2026-05-23.
//
//  Visual idioms intentionally mirror ApplicationCard.swift so the two
//  variants feel like siblings: same outer surface fill, same border
//  treatment, same header/body/footer rhythm. The differences are:
//
//    * Body is a `LazyVStack` of result rows (not a TextEditor body).
//    * No inline-editable text — results are immutable.
//    * Footer is `Save as Markdown` + `Discard` (no Approve & Submit;
//      a search-and-find workflow has nothing to submit).
//
//  The list is decoded once on `onAppear` from `queueItem.resultsJson`.
//  We do NOT round-trip the JSON on each render — the parent will rebuild
//  this view if the queue row changes via the standard SwiftUI diff.
//

import AppKit
import SwiftUI

@MainActor
struct ResultsListCard: View {
    /// Snapshot of the queue row. Re-supplied by the parent on every
    /// QueueStoreObservable refresh, matching the ApplicationCard pattern.
    let queueItem: QueueItem

    /// Closure fired when the user taps Discard. The parent owns the
    /// status-flip + ws message, mirroring ApplicationCard.
    var onDiscard: (QueueItem) -> Void

    /// Decoded results. Computed once on `onAppear` and cached in @State
    /// so SwiftUI doesn't re-run JSONDecoder on every diff pass.
    @State private var decodedResults: [ResultsListItem] = []
    @State private var didAttemptDecode: Bool = false
    @State private var decodeErrorMessage: String?

    /// Title shown in the card header. We don't have a friendly workflow
    /// name on the queue row today (`workflowId` is often empty during
    /// V1), so we fall back to a generic label. When that plumbing lands
    /// it'll surface here automatically.
    private var headerTitle: String {
        if !queueItem.workflowId.isEmpty {
            return queueItem.workflowId
        }
        return "Search results"
    }

    /// Subtitle: "N results · M minutes ago". Pluralized like the rest of
    /// the app's row subtitles for consistency.
    private var headerSubtitle: String {
        let resultsCount = decodedResults.count
        let resultsCountFragment: String = {
            switch resultsCount {
            case 0: return "No results"
            case 1: return "1 result"
            default: return "\(resultsCount) results"
            }
        }()
        let relativeTimeFragment = Self.relativeTimeAgoString(from: queueItem.updatedAt)
        return "\(resultsCountFragment) · \(relativeTimeFragment)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            cardHeader

            if let decodeErrorMessage {
                cardDecodeErrorState(decodeErrorMessage)
            } else if decodedResults.isEmpty && didAttemptDecode {
                cardEmptyState
            } else {
                cardResultRowsList
            }

            cardActionButtonsRow
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .fill(DS.Colors.surface1)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DS.CornerRadius.large, style: .continuous)
                .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
        )
        .onAppear(perform: decodeResultsFromQueueItem)
        // Re-decode if the parent supplies a new resultsJson (e.g. a
        // late re-emission with more rows). Keeps the card in lockstep
        // with the persisted row.
        .onChange(of: queueItem.resultsJson ?? "") { _ in
            decodeResultsFromQueueItem()
        }
    }

    // MARK: - Header

    private var cardHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(headerTitle)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(DS.Colors.textPrimary)
                    .lineLimit(1)
                Text(headerSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(DS.Colors.textTertiary)
                    .lineLimit(1)
            }
            Spacer()
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textTertiary)
        }
    }

    // MARK: - Body States

    private var cardResultRowsList: some View {
        // LazyVStack so a 15-row card materializes lazily when scrolling
        // inside the panel. Spacing matches the inter-card gap one level
        // up for visual harmony.
        LazyVStack(alignment: .leading, spacing: 8) {
            ForEach(decodedResults) { resultItem in
                resultRow(for: resultItem)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cardEmptyState: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("No results in this run")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.textSecondary)
            Text("The agent finished but found nothing to list. Discard or re-run with different parameters.")
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    private func cardDecodeErrorState(_ errorMessage: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Couldn't decode results")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(DS.Colors.destructiveText)
            Text(errorMessage)
                .font(.system(size: 11))
                .foregroundColor(DS.Colors.textTertiary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    /// One row in the results list. Visual rhythm:
    ///   * Title in primary text (accent-tinted as load-bearing per spec).
    ///   * Fields rendered as `key: value · key: value · ...` in secondary
    ///     text on a single line, truncated if it overflows.
    ///   * "Open" button on the right if `item.url != nil`.
    private func resultRow(for resultItem: ResultsListItem) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(resultItem.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(DS.Colors.accentText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                if !resultItem.fields.isEmpty {
                    Text(Self.fieldsDisplayString(for: resultItem.fields))
                        .font(.system(size: 11))
                        .foregroundColor(DS.Colors.textSecondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let urlString = resultItem.url, !urlString.isEmpty {
                Button(action: { handleOpenUrlButtonTap(urlString: urlString) }) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 10, weight: .medium))
                        Text("Open")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundColor(DS.Colors.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule()
                            .stroke(DS.Colors.borderSubtle, lineWidth: 0.5)
                    )
                }
                .buttonStyle(.plain)
                .pointerCursor()
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                .fill(DS.Colors.surface2)
        )
    }

    // MARK: - Footer

    private var cardActionButtonsRow: some View {
        HStack(spacing: 8) {
            Button(action: handleSaveAsMarkdownButtonTap) {
                HStack(spacing: 6) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Save as Markdown")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundColor(DS.Colors.textOnAccent)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                        .fill(DS.Colors.accent)
                )
            }
            .buttonStyle(.plain)
            .pointerCursor()
            // Disable when there's nothing to write — keeps the user from
            // generating an empty file by accident.
            .disabled(decodedResults.isEmpty)
            .opacity(decodedResults.isEmpty ? 0.6 : 1.0)

            Spacer()

            Button(action: { onDiscard(queueItem) }) {
                Text("Discard")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(DS.Colors.destructiveText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: DS.CornerRadius.medium, style: .continuous)
                            .stroke(DS.Colors.destructive.opacity(0.30), lineWidth: 0.5)
                    )
            }
            .buttonStyle(.plain)
            .pointerCursor()
        }
    }

    // MARK: - Actions

    /// Open the result row's URL via `NSWorkspace`. We don't `await` or
    /// surface any error UI — opening a URL is best-effort, and a bad
    /// URL just no-ops with a log line.
    private func handleOpenUrlButtonTap(urlString: String) {
        // The model sometimes extracts relative hrefs like "/job/foo/123"
        // instead of absolute URLs. NSWorkspace can't open those — it'll
        // return Launch Services error -50 (paramErr) and show a Finder
        // "application can't be opened" dialog. Detect that case and
        // prepend the host from the parameters_json job_url we stored
        // when the agent started, so the link points back at the right
        // origin (e.g. https://builtin.com).
        let resolvedUrlString = absoluteUrlByResolvingAgainstQueueParameters(
            rawUrlString: urlString,
            queueParametersJson: queueItem.parametersJson
        )
        guard let parsedUrl = URL(string: resolvedUrlString),
              parsedUrl.scheme == "http" || parsedUrl.scheme == "https" else {
            print("⚠️ ResultsListCard: Open tapped on unparseable / relative URL: \(urlString) (resolved: \(resolvedUrlString))")
            return
        }
        openUrlPreferringChrome(parsedUrl)
    }

    /// Open `urlToOpen` in Google Chrome specifically when it's installed,
    /// falling back to the macOS default browser otherwise. The user often
    /// has Brave or another browser set as the system default but is
    /// actively recording / demoing in Chrome — popping a different
    /// browser mid-demo is jarring. Chrome is the most common dev choice
    /// so we hard-prefer it; Safari / Brave / Arc users get the same
    /// behavior they had before (system default) since Chrome won't exist
    /// at the path.
    private func openUrlPreferringChrome(_ urlToOpen: URL) {
        let chromeAppUrl = URL(fileURLWithPath: "/Applications/Google Chrome.app")
        if FileManager.default.fileExists(atPath: chromeAppUrl.path) {
            let openConfiguration = NSWorkspace.OpenConfiguration()
            openConfiguration.activates = true
            NSWorkspace.shared.open(
                [urlToOpen],
                withApplicationAt: chromeAppUrl,
                configuration: openConfiguration
            ) { _, openError in
                if let openError {
                    print("⚠️ ResultsListCard: Chrome refused to open \(urlToOpen.absoluteString): \(openError)")
                }
            }
            return
        }
        // No Chrome installed — fall back to whatever the OS-default
        // browser is. This is the path most non-Chrome users hit.
        let didOpen = NSWorkspace.shared.open(urlToOpen)
        if !didOpen {
            print("⚠️ ResultsListCard: NSWorkspace refused to open \(urlToOpen.absoluteString)")
        }
    }

    /// If `rawUrlString` already has an absolute scheme (http/https), return
    /// it untouched. Otherwise look at the queue item's stored parameters
    /// for a `job_url` (or any URL-shaped value) and reuse its origin so
    /// `/job/foo/123` becomes `https://builtin.com/job/foo/123`.
    private func absoluteUrlByResolvingAgainstQueueParameters(
        rawUrlString: String,
        queueParametersJson: String
    ) -> String {
        if rawUrlString.hasPrefix("http://") || rawUrlString.hasPrefix("https://") {
            return rawUrlString
        }
        guard let parametersData = queueParametersJson.data(using: .utf8),
              let parametersObject = try? JSONSerialization.jsonObject(with: parametersData) as? [String: Any] else {
            return rawUrlString
        }
        // Find any URL-shaped value in the parameters dict — usually job_url.
        for parameterValue in parametersObject.values {
            guard let candidateString = parameterValue as? String,
                  let candidateUrl = URL(string: candidateString),
                  let candidateScheme = candidateUrl.scheme,
                  let candidateHost = candidateUrl.host else { continue }
            let originString = "\(candidateScheme)://\(candidateHost)"
            if rawUrlString.hasPrefix("/") {
                return originString + rawUrlString
            }
            return originString + "/" + rawUrlString
        }
        return rawUrlString
    }

    /// Save the rendered list as a Markdown file on the Desktop. Layout:
    ///   # <header title>
    ///   _<header subtitle>_
    ///
    ///   ## <result.title>
    ///   - key: value
    ///   - key: value
    ///   [Open](<url>)
    ///
    /// On failure we just print — the spec asked for minimal error UI.
    private func handleSaveAsMarkdownButtonTap() {
        let markdownBody = Self.buildMarkdownExport(
            headerTitle: headerTitle,
            headerSubtitle: headerSubtitle,
            results: decodedResults
        )
        let workflowSlugForFilename = Self.slugForFilename(headerTitle)
        let timestampForFilename = Self.compactTimestampStringForFilename()
        let filename = "clicky-results-\(workflowSlugForFilename)-\(timestampForFilename).md"

        let desktopUrl = FileManager.default
            .urls(for: .desktopDirectory, in: .userDomainMask)
            .first
        guard let desktopUrl else {
            print("⚠️ ResultsListCard: could not resolve Desktop directory")
            return
        }
        let fileUrl = desktopUrl.appendingPathComponent(filename)
        do {
            try markdownBody.write(to: fileUrl, atomically: true, encoding: .utf8)
            print("📝 ResultsListCard: saved \(fileUrl.path)")
        } catch {
            print("⚠️ ResultsListCard: failed to write \(fileUrl.path): \(error)")
        }
    }

    // MARK: - Decode

    private func decodeResultsFromQueueItem() {
        didAttemptDecode = true
        decodeErrorMessage = nil

        guard let resultsJson = queueItem.resultsJson, !resultsJson.isEmpty,
              let resultsData = resultsJson.data(using: .utf8) else {
            decodedResults = []
            return
        }
        do {
            let decoded = try JSONDecoder().decode([ResultsListItem].self, from: resultsData)
            decodedResults = decoded
        } catch {
            print("⚠️ ResultsListCard: failed to decode resultsJson for \(queueItem.id): \(error)")
            decodedResults = []
            decodeErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Helpers

    /// Joins the result fields into a human-readable "key: value · key: value"
    /// string. Sorted by key so the order is reproducible across renders.
    static func fieldsDisplayString(for fields: [String: String]) -> String {
        fields
            .sorted(by: { $0.key < $1.key })
            .map { "\($0.key): \($0.value)" }
            .joined(separator: " · ")
    }

    /// "5 minutes ago" / "just now" / "2 hours ago" style relative string.
    /// We use a fresh formatter per call — the cost is trivial compared to
    /// the alternative of holding a @StateObject for one piece of text.
    static func relativeTimeAgoString(from referenceDate: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: referenceDate, relativeTo: Date())
    }

    /// Slugifies a free-text title into something safe for a filename:
    /// lowercase, alphanumeric + hyphens only, trimmed of duplicate
    /// hyphens, capped to a reasonable length.
    static func slugForFilename(_ rawTitle: String) -> String {
        let lowercased = rawTitle.lowercased()
        let allowedScalars = lowercased.unicodeScalars.map { scalar -> Character in
            if scalar.value < 0x80,
               CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return "-"
        }
        var collapsedHyphenString = String(allowedScalars)
        // Collapse runs of "-" into a single hyphen.
        while collapsedHyphenString.contains("--") {
            collapsedHyphenString = collapsedHyphenString.replacingOccurrences(of: "--", with: "-")
        }
        let trimmedString = collapsedHyphenString.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let cappedString = String(trimmedString.prefix(48))
        return cappedString.isEmpty ? "results" : cappedString
    }

    /// "20260523-1734" style compact timestamp used in the export filename.
    static func compactTimestampStringForFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    /// Renders the results list into a Markdown document.
    static func buildMarkdownExport(
        headerTitle: String,
        headerSubtitle: String,
        results: [ResultsListItem]
    ) -> String {
        var output = ""
        output.append("# \(headerTitle)\n")
        output.append("_\(headerSubtitle)_\n\n")
        for resultItem in results {
            output.append("## \(resultItem.title)\n")
            // Sort fields so the rendered Markdown is reproducible across
            // saves; matches the on-screen sort order.
            let sortedFields = resultItem.fields.sorted(by: { $0.key < $1.key })
            for (fieldKey, fieldValue) in sortedFields {
                output.append("- \(fieldKey): \(fieldValue)\n")
            }
            if let urlString = resultItem.url, !urlString.isEmpty {
                output.append("\n[Open](\(urlString))\n")
            }
            output.append("\n")
        }
        return output
    }
}
