import Foundation

/// DSH stores response usage twice; only assistant/message.data.usage is counted.
enum DSHLogReader {
    struct Scan {
        var buckets: [DailyTokenBucket]
        var unreadableFiles: Int
    }

    static func parse(_ data: Data) -> [DailyTokenBucket] {
        var days: [Date: (Int, Int)] = [:]
        var seen: Set<Int> = []
        for line in data.split(separator: 10) {
            guard let row = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  row["type"] as? String == "assistant/message",
                  let seq = row["seq"] as? Int,
                  !seen.contains(seq),
                  let time = row["time"] as? Double, time.isFinite,
                  let body = row["data"] as? [String: Any],
                  let usage = body["usage"] as? [String: Any],
                  let input = usage["inputTokens"] as? Int,
                  let output = usage["outputTokens"] as? Int,
                  input >= 0, output >= 0 else { continue }
            let cache = usage["cacheReadTokens"] as? Int ?? 0
            let total = usage["totalTokens"] as? Int ?? (input + output + cache)
            guard cache >= 0, total >= 0 else { continue }
            seen.insert(seq)
            let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: time / 1000))
            let previous = days[day] ?? (0, 0)
            days[day] = (previous.0 + total, previous.1 + input + output)
        }
        return days.keys.sorted().map {
            DailyTokenBucket(dayStart: $0, tokens: days[$0]!.0, billableTokens: days[$0]!.1)
        }
    }

    static func scan(root: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".dsh/sessions")) -> Scan {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return Scan(buckets: [], unreadableFiles: 0)
        }
        let executable = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd"].first { fm.isExecutableFile(atPath: $0) }
        var result = Scan(buckets: [], unreadableFiles: 0)
        var sessions: [URL: URL] = [:]
        for case let url as URL in files {
            guard ["session.v3.jsonl.zstd", "session.v4.jsonl.zstd"].contains(url.lastPathComponent) else { continue }
            let directory = url.deletingLastPathComponent()
            // Migration keeps the old log; v4 contains the migrated history plus new events.
            if sessions[directory] == nil || url.lastPathComponent == "session.v4.jsonl.zstd" {
                sessions[directory] = url
            }
        }
        for url in sessions.values {
            guard let executable else { result.unreadableFiles += 1; continue }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["-dc", "--", url.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else { result.unreadableFiles += 1; continue }
                result.buckets += parse(data)
            } catch { result.unreadableFiles += 1 }
        }
        return result
    }
}
