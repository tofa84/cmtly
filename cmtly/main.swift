//
//  main.swift
//  cmtly
//
//  Created by Falco Tomasetti on 08.10.25.
//

import Foundation
import FoundationModels
import Dispatch

private struct CLIOptions {
    let verbose: Bool
    let displayHelp: Bool

    static func parse(arguments: [String]) throws -> CLIOptions {
        var verbose = false
        var displayHelp = false

        for argument in arguments {
            switch argument {
            case "-v", "--verbose":
                verbose = true
            case "-h", "--help":
                displayHelp = true
            default:
                throw CLIError.invalidOption(argument)
            }
        }

        return CLIOptions(verbose: verbose, displayHelp: displayHelp)
    }
}

if #available(macOS 15, *) {
    Task {
        let exitCode = await runCmtly()
        Diagnostics.exit(with: exitCode)
    }
    dispatchMain()
} else {
    Diagnostics.print(CLIError.unsupportedOperatingSystem)
    Diagnostics.exit(with: CLIError.unsupportedOperatingSystem.exitCode)
}

@available(macOS 15, *)
private func runCmtly() async -> Int32 {
    do {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let options = try CLIOptions.parse(arguments: arguments)

        if options.displayHelp {
            Diagnostics.printUsage()
            return EXIT_SUCCESS
        }

        Logger.configure(verbose: options.verbose)
        Logger.debug("Verbose mode enabled")
        Logger.debug("Working directory: \(FileManager.default.currentDirectoryPath)")

        let git = GitClient()
        Logger.debug("Checking for Git repository...")
        guard try git.isInRepository() else {
            throw CLIError.notAGitRepository
        }
        Logger.debug("Git repository detected.")

        guard let diff = try git.stagedDiff(), diff.containsNonWhitespace else {
            throw CLIError.noStagedChanges
        }
        let diffLineCount = diff.components(separatedBy: .newlines).count
        Logger.debug("Captured staged diff (\(diff.count) chars, \(diffLineCount) lines).")

        let generator = CommitMessageGenerator()
        let spinner = Spinner(message: "Generating commit message…")
        if !Logger.isVerboseEnabled {
            spinner.start()
        }
        defer { spinner.stop() }

        let message = try await generator.generateCommitMessage(for: diff)
        spinner.stop()

        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        print("\(ANSI.green)✅ Commit summary:\(ANSI.reset) \(trimmed)")

        let commitCommand = "git commit -m \(trimmed.shellQuoted)"
        do {
            try Clipboard.copy(commitCommand)
            print("\(ANSI.blue)📋 Commit command copied to clipboard.\(ANSI.reset)")
        } catch {
            Diagnostics.print(ClipboardError.copyFailed)
        }
        return EXIT_SUCCESS
    } catch {
        Diagnostics.print(error)
        return (error as? CLIError)?.exitCode ?? EXIT_FAILURE
    }
}

private struct GitClient {
    private let executor = ProcessExecutor()

    func isInRepository() throws -> Bool {
        do {
            let output = try executor.run(
                command: "git",
                arguments: ["rev-parse", "--is-inside-work-tree"]
            )
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        } catch ProcessExecutor.Error.launchFailed {
            throw CLIError.gitMissing
        } catch {
            return false
        }
    }

    func stagedDiff() throws -> String? {
        do {
            let output = try executor.run(
                command: "git",
                arguments: ["diff", "--cached"]
            )
            let diff = output.stdout
            return diff.containsNonWhitespace ? diff : nil
        } catch ProcessExecutor.Error.nonZeroStatus(let status, let stderr) {
            if stderr.contains("fatal:") {
                throw CLIError.gitFatal(stderr)
            }
            throw CLIError.gitCommandFailed(status: status, stderr: stderr)
        }
    }
}

@available(macOS 15, *)
private struct CommitMessageGenerator {
    func generateCommitMessage(for diff: String) async throws -> String {
        let model = FoundationModels.SystemLanguageModel.default
        guard case .available = model.availability else {
            throw CLIError.foundationModelUnavailable(description(for: model.availability))
        }
        Logger.debug("Using model \(String(describing: model)) for single-pass generation.")

        let combinedPrompt = CommitMessagePrompt(diff: diff)

        do {
            let raw = try await respond(
                model: model,
                instructions: CommitMessagePrompt.instructions,
                prompt: combinedPrompt.render()
            )
            return sanitize(raw)
        } catch let error as FoundationModels.LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                return try await generateFromSplitDiff(diff: diff, model: model)
            }
            throw CLIError.foundationModelFailed(error.localizedDescription)
        } catch {
            throw CLIError.foundationModelFailed(String(describing: error))
        }
    }

    private func generateFromSplitDiff(diff: String, model: FoundationModels.SystemLanguageModel) async throws -> String {
        let segments = DiffSplitter.split(diff: diff)
        Logger.debug("Falling back to segmented generation (\(segments.count) segments).")
        let partialMessages = try await collectMessages(for: segments, using: model)

        guard !partialMessages.isEmpty else {
            return "chore: update changes"
        }

        do {
            let summaryRaw = try await respond(
                model: model,
                instructions: CommitSummaryPrompt.instructions,
                prompt: CommitSummaryPrompt(messages: partialMessages).render()
            )
            return sanitize(summaryRaw)
        } catch let error as FoundationModels.LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                return partialMessages.first ?? "chore: update changes"
            }
            throw CLIError.foundationModelFailed(error.localizedDescription)
        } catch {
            throw CLIError.foundationModelFailed(String(describing: error))
        }
    }

    private func collectMessages(for segments: [DiffSplitter.Segment], using model: FoundationModels.SystemLanguageModel) async throws -> [String] {
        guard !segments.isEmpty else { return [] }

        return try await withThrowingTaskGroup(of: (Int, [String]).self) { group in
            let concurrencyLimit = 3
            var iterator = segments.enumerated().makeIterator()

            func addNextTaskIfAvailable() {
                guard let (index, segment) = iterator.next() else { return }
                Logger.debug("Queued segment \(index + 1)/\(segments.count) for file '\(segment.path)'.")
                group.addTask {
                    Logger.debug("Requesting message for segment '\(segment.path)' (index \(index + 1)).")
                    let messages = try await collectMessages(for: segment, using: model)
                    Logger.debug("Segment '\(segment.path)' returned \(messages.count) message(s).")
                    return (index, messages)
                }
            }

            for _ in 0..<concurrencyLimit {
                addNextTaskIfAvailable()
            }

            var orderedResults = Array(repeating: [String](), count: segments.count)
            while let result = try await group.next() {
                let (index, messages) = result
                orderedResults[index] = messages
                Logger.debug("Completed segment \(index + 1)/\(segments.count).")
                addNextTaskIfAvailable()
            }

            return orderedResults.flatMap { $0 }
        }
    }

    private func collectMessages(for segment: DiffSplitter.Segment, using model: FoundationModels.SystemLanguageModel) async throws -> [String] {
        do {
            let raw = try await respond(
                model: model,
                instructions: CommitMessagePrompt.instructions,
                prompt: CommitMessagePrompt(diff: segment.diff, filePath: segment.path).render()
            )
            let message = sanitize(raw)
            return message.containsNonWhitespace ? [message] : []
        } catch let error as FoundationModels.LanguageModelSession.GenerationError {
            if case .exceededContextWindowSize = error {
                Logger.debug("Segment '\(segment.path)' exceeded context window. Chunking diff.")
                return try await collectChunkedMessages(for: segment, using: model)
            }
            throw CLIError.foundationModelFailed(error.localizedDescription)
        } catch {
            throw CLIError.foundationModelFailed(String(describing: error))
        }
    }

    private func collectChunkedMessages(for segment: DiffSplitter.Segment, using model: FoundationModels.SystemLanguageModel) async throws -> [String] {
        let chunks = DiffSplitter.chunk(segment: segment)
        guard chunks.count > 1 else {
            return []
        }
        Logger.debug("Split segment '\(segment.path)' into \(chunks.count) chunks.")

        var responses: [String] = []

        for (index, chunk) in chunks.enumerated() {
            do {
                let raw = try await respond(
                    model: model,
                    instructions: CommitMessagePrompt.instructions,
                    prompt: CommitMessagePrompt(
                        diff: chunk.diff,
                        filePath: chunk.path,
                        contextHint: "Chunk \(index + 1) of \(chunks.count)"
                    ).render()
                )
                let message = sanitize(raw)
                if message.containsNonWhitespace {
                    Logger.debug("Chunk \(index + 1)/\(chunks.count) for '\(segment.path)' produced a message.")
                    responses.append(message)
                }
            } catch let error as FoundationModels.LanguageModelSession.GenerationError {
                if case .exceededContextWindowSize = error {
                    Logger.debug("Chunk \(index + 1)/\(chunks.count) for '\(segment.path)' still exceeded context limits; skipping.")
                    continue
                }
                throw CLIError.foundationModelFailed(error.localizedDescription)
            } catch {
                throw CLIError.foundationModelFailed(String(describing: error))
            }
        }

        return responses
    }

    private func respond(model: FoundationModels.SystemLanguageModel, instructions: String, prompt: String) async throws -> String {
        let session = FoundationModels.LanguageModelSession(
            model: model,
            instructions: instructions
        )
        let seed = UInt64(Calendar.current.component(.dayOfYear, from: .now))
        let sampling = GenerationOptions.SamplingMode.random(top: 10, seed: seed)
        let options = GenerationOptions(sampling: sampling, temperature: 0.7)
        let response = try await session.respond(to: prompt, options: options)
        return response.content
    }

    private func sanitize(_ message: String) -> String {
        let firstLine = message
            .components(separatedBy: .newlines)
            .first?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard firstLine.containsNonWhitespace else {
            return "chore: update changes"
        }

        return firstLine
    }

    private func description(for availability: FoundationModels.SystemLanguageModel.Availability) -> String {
        switch availability {
        case .available:
            return "Model is marked as available."
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible:
                return "Device is not eligible to run Apple Intelligence models."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is not enabled. Enable it in System Settings."
            case .modelNotReady:
                return "Model assets are not ready. Check download progress in System Settings."
            @unknown default:
                return "Model availability is unknown."
            }
        }
    }
}

private struct CommitMessagePrompt {
    static let instructions = """
    You are a release assistant that crafts terse Git commit messages.
    Respond with a single-line conventional commit summary no longer than 72 characters.
    Capture the most important change with clear, specific wording.
    Do not add additional lines, bullets, or decorative punctuation.
    Never include code fences or diff markers in the response.
    """

    let diff: String
    let filePath: String?
    let contextHint: String?

    init(diff: String, filePath: String? = nil, contextHint: String? = nil) {
        self.diff = diff
        self.filePath = filePath
        self.contextHint = contextHint
    }

    func render() -> String {
        var context = "Analyze the following git diff of staged changes and produce a concise commit message that highlights the most important impact."
        if let filePath {
            context += "\nThe diff corresponds to file: \(filePath). Focus on the behavior change this file introduces."
        }
        if let contextHint {
            context += "\n\(contextHint)."
        }

        return """
        \(context)

        <git_diff>
        \(diff)
        </git_diff>
        """
    }
}

private struct CommitSummaryPrompt {
    static let instructions = """
    You are a release assistant that crafts terse Git commit messages.
    Respond with a single-line conventional commit summary no longer than 72 characters.
    Capture the combined impact across the provided file-level messages with clear, specific wording.
    Do not add additional lines, bullets, or decorative punctuation.
    Never include code fences in the response.
    """

    let messages: [String]

    func render() -> String {
        let entries = messages.enumerated().map { index, message in
            "\(index + 1). \(message)"
        }.joined(separator: "\n")

        return """
        Combine the following file-level summaries into one overall commit message that highlights the most important impact.

        <file_summaries>
        \(entries)
        </file_summaries>
        """
    }
}

private enum DiffSplitter {
    struct Segment {
        let path: String
        let diff: String
    }

    static func split(diff: String) -> [Segment] {
        var segments: [Segment] = []
        var currentLines: [String] = []
        var currentPath = "changes"

        func flush() {
            guard !currentLines.isEmpty else { return }
            let combined = currentLines.joined(separator: "\n")
            if combined.containsNonWhitespace {
                segments.append(Segment(path: currentPath, diff: combined))
            }
            currentLines.removeAll(keepingCapacity: true)
        }

        let lines = diff.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

        for line in lines {
            if line.hasPrefix("diff --git ") {
                flush()
                currentPath = extractPath(from: line)
                currentLines.append(line)
            } else {
                currentLines.append(line)
            }
        }

        flush()
        return segments
    }

    static func chunk(segment: Segment, maxChunkLines: Int = 200) -> [Segment] {
        let lines = segment.diff
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)

        guard !lines.isEmpty else {
            return [segment]
        }

        var headerLines: [String] = []
        var hunks: [[String]] = []
        var currentHunk: [String] = []
        var hasSeenHunk = false

        for line in lines {
            if line.hasPrefix("@@") {
                if !currentHunk.isEmpty {
                    hunks.append(currentHunk)
                    currentHunk.removeAll(keepingCapacity: true)
                }
                currentHunk.append(line)
                hasSeenHunk = true
            } else if hasSeenHunk {
                currentHunk.append(line)
            } else {
                headerLines.append(line)
            }
        }

        if !currentHunk.isEmpty {
            hunks.append(currentHunk)
        }

        guard !hunks.isEmpty else {
            return [segment]
        }

        var chunks: [Segment] = []
        var currentBody: [String] = []
        var currentLineCount = 0

        func flushBody() {
            guard !currentBody.isEmpty else { return }
            let combined = (headerLines + currentBody).joined(separator: "\n")
            chunks.append(Segment(path: segment.path, diff: combined))
            currentBody.removeAll(keepingCapacity: true)
            currentLineCount = 0
        }

        for hunk in hunks {
            let hunkCount = hunk.count
            if currentLineCount > 0 && currentLineCount + hunkCount > maxChunkLines {
                flushBody()
            }

            currentBody.append(contentsOf: hunk)
            currentLineCount += hunkCount

            if currentLineCount >= maxChunkLines {
                flushBody()
            }
        }

        flushBody()

        return chunks.isEmpty ? [segment] : chunks
    }

    private static func extractPath(from header: String) -> String {
        let prefix = "diff --git "
        guard header.hasPrefix(prefix) else {
            return "changes"
        }

        let remainder = header.dropFirst(prefix.count)

        if remainder.first == "\"" {
            var paths: [String] = []
            var current = ""
            var inQuote = false

            for character in remainder {
                if character == "\"" {
                    if inQuote {
                        paths.append(current)
                        current = ""
                    }
                    inQuote.toggle()
                    continue
                }

                if inQuote {
                    current.append(character)
                }
            }

            if let last = paths.last {
                return normalize(path: last)
            }
        }

        let components = remainder.split(separator: " ")
        if let last = components.last {
            return normalize(path: String(last))
        }

        return "changes"
    }

    private static func normalize(path: String) -> String {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "\""))

        if trimmed.hasPrefix("b/") {
            return String(trimmed.dropFirst(2))
        }

        if trimmed.hasPrefix("a/") {
            return String(trimmed.dropFirst(2))
        }

        return trimmed
    }
}

private struct ProcessExecutor {
    enum Error: Swift.Error {
        case launchFailed
        case nonZeroStatus(Int32, String)
    }

    struct Output {
        let stdout: String
        let stderr: String
    }

    func run(command: String, arguments: [String]) throws -> Output {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = [command] + arguments
        Logger.debug("Executing command: \(process.arguments?.joined(separator: " ") ?? command)")

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw Error.launchFailed
        }

        let stdoutHandle = stdoutPipe.fileHandleForReading
        let stderrHandle = stderrPipe.fileHandleForReading

        var stdoutData = Data()
        var stderrData = Data()
        let captureGroup = DispatchGroup()

        captureGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { captureGroup.leave() }
            stdoutData = stdoutHandle.readDataToEndOfFile()
            stdoutHandle.closeFile()
        }

        captureGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { captureGroup.leave() }
            stderrData = stderrHandle.readDataToEndOfFile()
            stderrHandle.closeFile()
        }

        process.waitUntilExit()
        Logger.debug("Command finished with status \(process.terminationStatus).")
        captureGroup.wait()

        let stdoutString = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderrString = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            if !stderrString.isEmpty {
                Logger.debug("Command stderr: \(stderrString)")
            }
            throw Error.nonZeroStatus(process.terminationStatus, stderrString)
        }

        return Output(stdout: stdoutString, stderr: stderrString)
    }
}

private enum CLIError: Error {
    case gitMissing
    case notAGitRepository
    case noStagedChanges
    case gitFatal(String)
    case gitCommandFailed(status: Int32, stderr: String)
    case unsupportedOperatingSystem
    case foundationModelUnavailable(String)
    case foundationModelFailed(String)
    case invalidOption(String)

    var exitCode: Int32 {
        switch self {
        case .noStagedChanges:
            return EXIT_FAILURE
        case .unsupportedOperatingSystem:
            return EXIT_FAILURE
        case .foundationModelUnavailable:
            return EXIT_FAILURE
        case .foundationModelFailed:
            return EXIT_FAILURE
        case .invalidOption:
            return EXIT_FAILURE
        case .gitMissing:
            return EXIT_FAILURE
        case .notAGitRepository:
            return EXIT_FAILURE
        case .gitFatal:
            return EXIT_FAILURE
        case .gitCommandFailed:
            return EXIT_FAILURE
        }
    }
}

extension CLIError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .gitMissing:
            return "git executable not found. Install Git to use cmtly."
        case .notAGitRepository:
            return "This directory is not a Git repository. Run cmtly inside a repository with staged changes."
        case .noStagedChanges:
            return "No staged changes detected. Stage files with `git add` before running cmtly."
        case .gitFatal(let message):
            return "Git reported an error: \(message)"
        case .gitCommandFailed(let status, let stderr):
            return "Git command failed with exit code \(status). \(stderr)"
        case .unsupportedOperatingSystem:
            return "Apple Foundation Models require macOS 15 or newer. Update your system to run cmtly."
        case .foundationModelUnavailable(let reason):
            return "Apple Foundation Model is unavailable: \(reason)"
        case .foundationModelFailed(let description):
            return "Apple Foundation Model request failed: \(description)"
        case .invalidOption(let option):
            return "Unknown option '\(option)'. Run `cmtly --help` for usage."
        }
    }
}

private enum Diagnostics {
    static func print(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func printUsage() {
        let usage = """
        Usage: cmtly [options]

          -v, --verbose    Enable verbose logging
          -h, --help       Show this help information
        """
        FileHandle.standardOutput.write(Data((usage + "\n").utf8))
    }

    static func exit(with code: Int32) -> Never {
        Darwin.exit(code)
    }
}

private final class Spinner {
    private let frames = ["|", "/", "-", "\\"]
    private let message: String
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private let queue = DispatchQueue(label: "cmtly.spinner")
    private let enabled: Bool
    private let lock = NSLock()
    private var running = false

    init(message: String) {
        self.message = message
        self.enabled = isatty(FileHandle.standardError.fileDescriptor) != 0
    }

    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, !running else { return }
        running = true

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(120))
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let frame = self.frames[self.frameIndex % self.frames.count]
            self.frameIndex += 1
            let line = "\r\(frame) \(self.message)"
            FileHandle.standardError.write(Data(line.utf8))
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard enabled, running else { return }
        running = false
        timer?.cancel()
        timer = nil
        frameIndex = 0
        let clearLine = "\r\u{001B}[K"
        FileHandle.standardError.write(Data(clearLine.utf8))
    }
}

private enum Logger {
    private static var isVerbose = false

    static func configure(verbose: Bool) {
        isVerbose = verbose
    }

    static var isVerboseEnabled: Bool {
        isVerbose
    }

    static func debug(_ message: @autoclosure () -> String) {
        guard isVerbose else { return }
        FileHandle.standardError.write(Data(("[cmtly] \(message())\n").utf8))
    }
}

private extension String {
    var containsNonWhitespace: Bool {
        rangeOfCharacter(from: .whitespacesAndNewlines.inverted) != nil
    }

    var shellQuoted: String {
        guard !contains("'") else {
            let escaped = replacingOccurrences(of: "'", with: "'\"'\"'")
            return "'\(escaped)'"
        }
        return "'\(self)'"
    }
}

private enum ClipboardError: LocalizedError {
    case copyFailed

    var errorDescription: String? {
        switch self {
        case .copyFailed:
            return "⚠️ Failed to copy commit command to clipboard."
        }
    }
}

private enum Clipboard {
    static func copy(_ value: String) throws {
        let process = Process()
        process.launchPath = "/usr/bin/env"
        process.arguments = ["pbcopy"]

        let inputPipe = Pipe()
        process.standardInput = inputPipe

        do {
            try process.run()
        } catch {
            throw ClipboardError.copyFailed
        }

        inputPipe.fileHandleForWriting.write(Data(value.utf8))
        inputPipe.fileHandleForWriting.closeFile()

        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw ClipboardError.copyFailed
        }
    }
}

private enum ANSI {
    static let reset = "\u{001B}[0m"
    static let green = "\u{001B}[32m"
    static let blue = "\u{001B}[34m"
}
