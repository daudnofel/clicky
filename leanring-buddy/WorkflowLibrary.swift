//
//  WorkflowLibrary.swift
//  leanring-buddy
//
//  Disk-backed JSON store for learned workflow profiles.
//
//  Profiles live in `~/Library/Application Support/Clicky/workflows/<id>.json`
//  per § A.1 of the apprentice-mode plan, one file per workflow. This file
//  owns the in-memory `[SavedWorkflowProfile]` array that drives the
//  Workflows section of the menu bar panel, the file-system reads/writes,
//  and the Codable model that mirrors the on-disk JSON shape.
//
//  Filesystem layout:
//    ~/Library/Application Support/Clicky/workflows/
//      <uuid>.json            ← one per workflow
//      <uuid>.json
//      ...
//
//  We deliberately keep the on-disk shape snake_case (matching the wire
//  format the Cloudflare Worker produces) and use
//  JSONDecoder.keyDecodingStrategy = .convertFromSnakeCase so Swift code
//  keeps camelCase. This avoids littering the rest of the codebase with
//  snake_case property names.
//

import Combine
import Foundation
import SwiftUI

// MARK: - Model

/// One step in the procedure array of a workflow profile. § A.1.
struct WorkflowProfileStep: Codable, Equatable, Identifiable {
    var id: Int { stepIndex }
    let stepIndex: Int
    let intent: String
}

/// One parameter the workflow expects per replay run. § A.1.
struct WorkflowProfileParameter: Codable, Equatable, Identifiable {
    /// Stable identity for SwiftUI ForEach — parameter names are unique
    /// per profile by construction.
    var id: String { name }
    let name: String
    let type: String
    let exampleFromDemo: String?
}

/// A single verbatim_example entry inside the style_profile. § A.1.
struct WorkflowProfileStyleExample: Codable, Equatable {
    let question: String?
    let userAnswer: String?
}

/// Voice / style profile attached to the workflow when the demo involves
/// freeform writing. When the demo had no freeform writing, `applicable`
/// is false and the rest of the fields may be absent.
struct WorkflowProfileStyleProfile: Codable, Equatable {
    let applicable: Bool?
    let toneDescriptors: [String]?
    let avgSentenceLength: Double?
    let avoidsPhrases: [String]?
    let usesPhrases: [String]?
    let verbatimExamples: [WorkflowProfileStyleExample]?
}

/// Top-level workflow profile saved to disk. Mirrors the JSON the Worker
/// returns from POST /workflow/learn (§ A.1). Identity is the `id` field
/// (we don't put a separate uuid on the Swift side — the file on disk
/// is named `<id>.json`).
struct SavedWorkflowProfile: Codable, Equatable, Identifiable {
    let id: String
    let name: String?
    let createdFromDemoAt: String
    let sourceDemoUuid: String?
    let procedure: [WorkflowProfileStep]
    let parameters: [WorkflowProfileParameter]
    let decisionRules: [String]
    let referenceKeys: [String]
    let styleProfile: WorkflowProfileStyleProfile?
    let stopCondition: String
    let outputFormat: String
}

// MARK: - Library

/// @MainActor-isolated, ObservableObject-backed store of all saved
/// workflow profiles. Owned by CompanionManager; observed by
/// WorkflowListView in the menu bar panel.
///
/// We deliberately keep this very thin: read all profiles into memory on
/// startup (the list is small — handful of workflows at most), publish
/// changes via @Published, write through to disk on each save/delete.
/// No incremental indexing, no caching layer.
@MainActor
final class WorkflowLibrary: ObservableObject {
    @Published private(set) var workflowProfiles: [SavedWorkflowProfile] = []
    @Published private(set) var lastLibraryErrorMessage: String?

    init() {
        // Eager reload on construction so the first menu bar panel open
        // already shows any previously-saved workflows.
        reloadFromDisk()
    }

    /// Scans the workflows directory, decodes every `*.json`, and
    /// publishes the sorted result. Errors on individual files are
    /// logged + skipped (a corrupt single file shouldn't take down the
    /// whole library).
    func reloadFromDisk() {
        let directoryUrl = Self.workflowsDirectoryUrl()
        ensureDirectoryExists(at: directoryUrl)

        let fileManager = FileManager.default
        let entries: [URL]
        do {
            entries = try fileManager.contentsOfDirectory(
                at: directoryUrl,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        } catch {
            print("⚠️ WorkflowLibrary: failed to list \(directoryUrl.path): \(error)")
            lastLibraryErrorMessage = "Could not list workflows directory: \(error.localizedDescription)"
            workflowProfiles = []
            return
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase

        var decodedProfiles: [SavedWorkflowProfile] = []
        for fileUrl in entries where fileUrl.pathExtension.lowercased() == "json" {
            do {
                let fileData = try Data(contentsOf: fileUrl)
                let decodedProfile = try decoder.decode(SavedWorkflowProfile.self, from: fileData)
                decodedProfiles.append(decodedProfile)
            } catch {
                // Don't fail the whole reload — log and skip.
                print("⚠️ WorkflowLibrary: skipping \(fileUrl.lastPathComponent) (\(error))")
            }
        }

        // Sort by created_from_demo_at DESC. createdFromDemoAt is an ISO
        // string and lexicographic compare on ISO timestamps matches
        // chronological order, so we don't need to convert to Date first.
        decodedProfiles.sort { $0.createdFromDemoAt > $1.createdFromDemoAt }

        workflowProfiles = decodedProfiles
        lastLibraryErrorMessage = nil
    }

    /// Writes a profile to disk at `<dir>/<profile.id>.json` and reloads
    /// the in-memory list. Throws on filesystem failures so callers can
    /// surface the error to the user.
    func save(profile: SavedWorkflowProfile) throws {
        let directoryUrl = Self.workflowsDirectoryUrl()
        ensureDirectoryExists(at: directoryUrl)

        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        let fileUrl = directoryUrl.appendingPathComponent("\(profile.id).json")
        let payload = try encoder.encode(profile)
        try payload.write(to: fileUrl, options: [.atomic])

        reloadFromDisk()
    }

    /// Removes a profile from disk by id and reloads. No-ops if the file
    /// is already absent (idempotent — useful if the user double-taps
    /// delete on a list row).
    func delete(profileId: String) throws {
        let fileUrl = Self.workflowsDirectoryUrl().appendingPathComponent("\(profileId).json")
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: fileUrl.path) {
            try fileManager.removeItem(at: fileUrl)
        }
        reloadFromDisk()
    }

    // MARK: - Paths

    /// `~/Library/Application Support/Clicky/workflows/`.
    static func workflowsDirectoryUrl() -> URL {
        let applicationSupportUrl = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return applicationSupportUrl
            .appendingPathComponent("Clicky", isDirectory: true)
            .appendingPathComponent("workflows", isDirectory: true)
    }

    private func ensureDirectoryExists(at directoryUrl: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryUrl.path) {
            do {
                try fileManager.createDirectory(
                    at: directoryUrl,
                    withIntermediateDirectories: true,
                    attributes: nil
                )
            } catch {
                print("⚠️ WorkflowLibrary: failed to create \(directoryUrl.path): \(error)")
            }
        }
    }
}
