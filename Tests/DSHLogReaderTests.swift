import Foundation

@main struct DSHLogReaderTests {
    static func main() throws {
        let row = #"{"type":"assistant/message","seq":1,"time":1789115012356,"data":{"usage":{"inputTokens":357,"outputTokens":178,"totalTokens":9111,"cacheReadTokens":8576,"reasoningTokens":16},"stream":[{"chunk":{"usage":{"totalTokens":9111}}}]}}"#
        let ignored = #"{"type":"other","seq":2,"time":1789115012356,"data":{"usage":{"inputTokens":1,"outputTokens":2,"totalTokens":3}}}"#
        let parsed = DSHLogReader.parse(Data((row + "\n" + row + "\n" + ignored + "\n{broken").utf8))
        precondition(parsed.count == 1)
        precondition(parsed[0].tokens == 9111, "Do not double-count stream usage, repeated seq, or reasoning")
        precondition(parsed[0].billableTokens == 535)
        precondition(Calendar.current.isDate(parsed[0].dayStart, inSameDayAs: Date(timeIntervalSince1970: 1789115012.356)))
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let zstd = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first { fm.isExecutableFile(atPath: $0) }
        guard let zstd else {
            print("DSH parser tests passed; compressed scan tests skipped (zstd unavailable)")
            return
        }
        func write(_ session: String, _ version: Int, _ content: String) throws {
            let directory = root.appendingPathComponent(session)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let source = directory.appendingPathComponent("fixture.jsonl")
            try Data(content.utf8).write(to: source)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: zstd)
            process.arguments = ["-q", "-f", source.path, "-o", directory.appendingPathComponent("session.v\(version).jsonl.zstd").path]
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        let newRow = row.replacingOccurrences(of: #""seq":1"#, with: #""seq":2"#)
        try write("legacy", 3, row)
        try write("gui", 4, row)
        try write("migrated", 3, row)
        try write("migrated", 4, row + "\n" + newRow)
        try write("unsupported", 5, row)
        let scan = DSHLogReader.scan(root: root)
        precondition(scan.unreadableFiles == 0)
        precondition(scan.buckets.reduce(0) { $0 + $1.tokens } == 4 * 9111,
                     "Count CLI, GUI and migrated sessions once, preserving new v4 events")
        precondition(scan.buckets.reduce(0) { $0 + $1.billableTokens } == 4 * 535)
        try Data("broken".utf8).write(to: root.appendingPathComponent("migrated/session.v4.jsonl.zstd"))
        let broken = DSHLogReader.scan(root: root)
        precondition(broken.unreadableFiles == 1, "Unreadable v4 must surface an error rather than silently use stale v3")
        print("DSH parser and compressed v3/v4 scan tests passed")
    }
}
