// SponsorDetector — owner: Module D (PLAN.md §6.5 on-device sponsor detection).
//
// The FoundationModels adapter. Everything that can be pure is YTCore's SponsorDetection and
// Captions (tested on Linux): parsing, chunking, the keyword prefilter, the instructions and
// prompt, the answer schema (as data) and the answer's validation. This file only:
//   - maps SystemLanguageModel.default.availability to SponsorDetection.ModelStatus;
//   - builds a DynamicGenerationSchema from SponsorDetection.AnswerSchema (no @Generable/@Guide:
//     their macro plugin isn't available when building from Linux);
//   - asks the model about each chunk that passes the prefilter, one at a time, each in a fresh
//     LanguageModelSession so the context never grows. Every error (guardrails, context size,
//     unsupported locale, the model not ready, …) is caught and counted; that chunk just has no
//     detections.
// `detect` is @concurrent, so parsing and the model calls never run on the main actor. It checks
// for cancellation between chunks (the service cancels it when the video changes).

import Foundation
import FoundationModels
import YTCore

@available(iOS 26, *)
struct SponsorDetector: Sendable {
    /// What a run produced: the report for the summary line, plus each failed chunk's error.
    struct Outcome: Sendable {
        var cueCount: Int
        var report: SponsorDetection.Report
        var errors: [String]
    }

    var options: SponsorDetection.Options = .standard
    var chunkCharacters: Int = SponsorDetection.defaultChunkCharacters
    var overlapSeconds: Double = SponsorDetection.defaultOverlapSeconds
    /// Answers are short: at most `AnswerSchema.maximumSegments` small objects.
    var maximumResponseTokens = 400

    /// The on-device model's state, for Settings and to skip work when it can't run.
    /// (`SystemLanguageModel` is Observable, so a SwiftUI body reading this updates on change.)
    static var status: SponsorDetection.ModelStatus {
        switch SystemLanguageModel.default.availability {
        case .available:
            return .available
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return .appleIntelligenceOff
            case .modelNotReady: return .modelNotReady
            case .deviceNotEligible: return .deviceNotEligible
            @unknown default: return .unsupported
            }
        @unknown default:
            return .unsupported
        }
    }

    /// The model's context window in tokens (back-deployed to iOS 26.0; 4096 there).
    static var contextSize: Int { SystemLanguageModel.default.contextSize }

    /// Parses a json3 transcript and detects in it. Throws only if the body isn't json3.
    @concurrent
    func detect(json3 data: Data) async throws -> Outcome {
        let cues = try Captions.cues(fromJSON3: data)
        return await detect(cues: cues)
    }

    /// Runs the prefilter and the model over `cues`, chunk by chunk, and returns the validated,
    /// merged suggestions (category "sponsor"; also "selfpromo" if `options` allow it).
    @concurrent
    func detect(cues: [Captions.Cue]) async -> Outcome {
        let clock = ContinuousClock()
        let began = clock.now
        let chunks = SponsorDetection.chunks(cues, maxCharacters: chunkCharacters, overlapSeconds: overlapSeconds)
        var flagged = 0
        var errors: [String] = []
        var found: [SkipSegment] = []
        let schema: GenerationSchema?
        do {
            schema = try Self.makeSchema()
        } catch {
            schema = nil
            errors.append("schema: \(Self.describe(error))")
        }
        if let schema {
            for chunk in chunks {
                if Task.isCancelled { break }
                guard !SponsorDetection.prefilterMatches(chunk).isEmpty else { continue }
                flagged += 1
                do {
                    let json = try await ask(chunk, schema: schema)
                    found += SponsorDetection.segments(fromModelJSON: json, chunk: chunk, options: options)
                } catch {
                    errors.append("\(Int(chunk.start))–\(Int(chunk.end)) s: \(Self.describe(error))")
                }
            }
        }
        let elapsed = clock.now - began
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let report = SponsorDetection.Report(chunks: chunks.count, flagged: flagged,
                                             failed: errors.count,
                                             segments: SponsorDetection.merge(found), seconds: seconds)
        return Outcome(cueCount: cues.count, report: report, errors: errors)
    }

    /// One chunk, one fresh session; returns the answer as JSON (decoded by YTCore).
    private func ask(_ chunk: SponsorDetection.Chunk, schema: GenerationSchema) async throws -> String {
        let session = LanguageModelSession(model: .default, tools: [], instructions: SponsorDetection.instructions)
        let response = try await session.respond(
            to: SponsorDetection.prompt(for: chunk),
            schema: schema,
            includeSchemaInPrompt: true,
            options: GenerationOptions(samplingMode: .greedy, maximumResponseTokens: maximumResponseTokens)
        )
        return response.content.jsonString
    }

    /// `{segments: [{start: number, end: number, kind: one of …, confidence: number}]}`, built
    /// from YTCore's description so the names and descriptions are reviewed and tested there.
    static func makeSchema() throws -> GenerationSchema {
        let answer = SponsorDetection.AnswerSchema.self
        let properties = answer.segmentProperties.map { property in
            let schema: DynamicGenerationSchema
            switch property.kind {
            case .number:
                schema = DynamicGenerationSchema(type: Double.self)
            case .choice(let choices):
                schema = DynamicGenerationSchema(name: answer.kindName, anyOf: choices)
            }
            return DynamicGenerationSchema.Property(name: property.name, description: property.description, schema: schema)
        }
        let segment = DynamicGenerationSchema(name: answer.segmentName, description: answer.segmentDescription,
                                              properties: properties)
        let root = DynamicGenerationSchema(name: answer.rootName, description: answer.rootDescription, properties: [
            DynamicGenerationSchema.Property(
                name: answer.segmentsProperty, description: answer.segmentsDescription,
                schema: DynamicGenerationSchema(arrayOf: segment, minimumElements: 0,
                                                maximumElements: answer.maximumSegments)
            ),
        ])
        return try GenerationSchema(root: root, dependencies: [])
    }

    private static func describe(_ error: any Error) -> String {
        let text = String(describing: error)
        return text.count > 200 ? String(text.prefix(200)) + "…" : text
    }
}
