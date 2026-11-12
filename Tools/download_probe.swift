// 下载加速探针：测量 Apple IPA 下载 URL 的单连接与多通道 Range 吞吐。
//
// 用法：
//   swiftc -O -o /tmp/download_probe Tools/download_probe.swift
//   /tmp/download_probe "<下载 URL>" [--channels 4] [--bytes 67108864] [--rounds 2] [--shared-session]
//
// 不传 URL 时从剪贴板读取（pbpaste），方便直接从 ipatool 日志里复制
// `[download] download URL: ...` 后面的地址。
//
// 说明：
// - 只做网络吞吐测量，收到的数据直接丢弃，不写盘；因此测的是 CDN 侧速度。
// - 先用 `Range: bytes=0-0` 探测是否支持 Range，并读取总大小。
// - 默认只采样前 64 MB，避免大文件测试耗时；`--bytes` 可调整。
// - 多通道默认每个通道使用独立 URLSession（独立连接池）；加 `--shared-session`
//   可观察 HTTP/2 复用下的表现。

import Foundation

// MARK: - 参数

struct Options {
    var url: URL
    var channels: Int
    var sampleBytes: Int64
    var rounds: Int
    var sharedSession: Bool
}

func printUsage() -> Never {
    let text = """
    用法: download_probe <下载 URL> [选项]

      --channels N        多通道数量，默认 4（1...16）
      --bytes N           采样字节数，默认 64 MiB
      --rounds N          测量轮数，默认 2（单/多通道交替先后顺序）
      --shared-session    多通道共用一个 URLSession（观察 HTTP/2 复用）
      --help              显示本帮助

    不传 URL 时从系统剪贴板读取。
    """
    print(text)
    exit(2)
}

func pasteboardText() -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/pbpaste")
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
        try process.run()
    } catch {
        return nil
    }

    process.waitUntilExit()

    let data = pipe.fileHandleForReading.readDataToEndOfFile()

    return String(data: data, encoding: .utf8)
}

func parseOptions() -> Options {
    let args = Array(CommandLine.arguments.dropFirst())

    if args.contains("--help") || args.contains("-h") {
        printUsage()
    }

    var urlString: String?
    var channels = 4
    var sampleBytes = Int64(64 << 20)
    var rounds = 2
    var sharedSession = false

    var index = 0
    while index < args.count {
        let argument = args[index]

        switch argument {
        case "--channels":
            index += 1
            guard index < args.count, let value = Int(args[index]) else {
                print("错误: --channels 需要整数"); exit(2)
            }
            channels = value
        case "--bytes":
            index += 1
            guard index < args.count, let value = Int64(args[index]) else {
                print("错误: --bytes 需要整数"); exit(2)
            }
            sampleBytes = value
        case "--rounds":
            index += 1
            guard index < args.count, let value = Int(args[index]) else {
                print("错误: --rounds 需要整数"); exit(2)
            }
            rounds = value
        case "--shared-session":
            sharedSession = true
        default:
            if argument.hasPrefix("-") {
                print("错误: 未知参数 \(argument)"); exit(2)
            }
            if urlString != nil {
                print("错误: 只接受一个 URL"); exit(2)
            }
            urlString = argument
        }

        index += 1
    }

    if urlString == nil {
        urlString = pasteboardText()
    }

    guard let raw = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
          !raw.isEmpty,
          let url = URL(string: raw) else {
        print("错误: 未提供有效的下载 URL"); printUsage()
    }

    guard (1...16).contains(channels) else {
        print("错误: --channels 取值范围为 1...16"); exit(2)
    }

    guard rounds >= 1 else {
        print("错误: --rounds 至少为 1"); exit(2)
    }

    guard sampleBytes >= (1 << 20) else {
        print("错误: --bytes 至少为 1 MiB"); exit(2)
    }

    return Options(url: url, channels: channels, sampleBytes: sampleBytes, rounds: rounds, sharedSession: sharedSession)
}

// MARK: - 单段测量

struct RunStats {
    let index: Int
    let bytes: Int64
    let startedAt: Date
    let finishedAt: Date
    let firstByteAt: Date?
    let statusCode: Int
    let totalBytes: Int64
    let acceptRanges: String
    let contentRange: String
    let rangeIgnored: Bool
    let error: Error?

    var seconds: Double { max(finishedAt.timeIntervalSince(startedAt), 0.000_001) }
    var megabytesPerSecond: Double { Double(bytes) / seconds / 1_048_576 }
    var timeToFirstByte: Double? { firstByteAt.map { $0.timeIntervalSince(startedAt) } }

    func summary() -> String {
        String(format: "%6.2f MB / %6.2f s = %6.2f MB/s", Double(bytes) / 1_048_576, seconds, megabytesPerSecond)
    }
}

final class RangeRun: NSObject, URLSessionDataDelegate {
    let index: Int
    let expectedBytes: Int64
    var startedAt = Date()

    private let lock = NSLock()
    private var received: Int64 = 0
    private var firstByteAt: Date?
    private var finishedAt = Date()
    private var statusCode = 0
    private var totalBytes: Int64 = -1
    private var acceptRanges = ""
    private var contentRange = ""
    private var rangeIgnored = false
    private var failure: Error?
    private var reachedLimit = false
    private let done = DispatchSemaphore(value: 0)

    init(index: Int, expectedBytes: Int64) {
        self.index = index
        self.expectedBytes = expectedBytes
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        if let http = response as? HTTPURLResponse {
            statusCode = http.statusCode
            acceptRanges = http.value(forHTTPHeaderField: "Accept-Ranges") ?? ""
            contentRange = http.value(forHTTPHeaderField: "Content-Range") ?? ""
            if let total = RangeRun.totalSize(fromContentRange: contentRange) {
                totalBytes = total
            }
            // 服务器忽略 Range 时返回 200，此时必须限流拉取，避免下载整包。
            rangeIgnored = http.statusCode == 200
        }
        lock.unlock()

        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        if firstByteAt == nil {
            firstByteAt = Date()
        }
        received += Int64(data.count)
        let limitReached = received >= expectedBytes
        if limitReached {
            reachedLimit = true
        }
        lock.unlock()

        if limitReached {
            dataTask.cancel()
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock()
        finishedAt = Date()
        if let nsError = error as NSError?,
           nsError.code != NSURLErrorCancelled {
            failure = error
        }
        lock.unlock()
        done.signal()
    }

    func wait() -> RunStats {
        done.wait()

        lock.lock()
        defer { lock.unlock() }

        return RunStats(
            index: index,
            bytes: received,
            startedAt: startedAt,
            finishedAt: finishedAt,
            firstByteAt: firstByteAt,
            statusCode: statusCode,
            totalBytes: totalBytes,
            acceptRanges: acceptRanges,
            contentRange: contentRange,
            rangeIgnored: rangeIgnored,
            error: failure
        )
    }

    private static func totalSize(fromContentRange value: String) -> Int64? {
        guard let totalPart = value.split(separator: "/").last,
              let total = Int64(totalPart.trimmingCharacters(in: .whitespaces)) else {
            return nil
        }

        return total > 0 ? total : nil
    }
}

/// 多通道共用一个 URLSession 时，把回调按 task 转发给对应的 RangeRun。
final class DelegateRouter: NSObject, URLSessionDataDelegate {
    private let lock = NSLock()
    private var runs: [Int: RangeRun] = [:]

    func register(_ run: RangeRun, for task: URLSessionTask) {
        lock.lock()
        runs[task.taskIdentifier] = run
        lock.unlock()
    }

    private func run(for task: URLSessionTask) -> RangeRun? {
        lock.lock()
        defer { lock.unlock() }

        return runs[task.taskIdentifier]
    }

    func urlSession(_ session: URLSession,
                    dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let run = run(for: dataTask) else {
            completionHandler(.cancel)
            return
        }

        run.urlSession(session, dataTask: dataTask, didReceive: response, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        run(for: dataTask)?.urlSession(session, dataTask: dataTask, didReceive: data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        run(for: task)?.urlSession(session, task: task, didCompleteWithError: error)
    }
}

// MARK: - 测量执行

func makeSession(delegate: URLSessionDelegate?) -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpMaximumConnectionsPerHost = 16
    configuration.timeoutIntervalForRequest = 30
    configuration.timeoutIntervalForResource = 3600
    configuration.waitsForConnectivity = true

    return URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
}

/// 按 `segments` 并发发起 Range 请求，返回每段结果。
func runSegments(url: URL, segments: [(start: Int64, end: Int64)], sharedSession: Bool) -> [RunStats] {
    var sessions: [URLSession] = []
    let router: DelegateRouter? = sharedSession ? DelegateRouter() : nil
    var shared: URLSession?

    if let router = router {
        shared = makeSession(delegate: router)
        sessions.append(shared!)
    }

    var runs: [RangeRun] = []
    var tasks: [URLSessionDataTask] = []

    for (index, segment) in segments.enumerated() {
        let length = segment.end - segment.start + 1
        let run = RangeRun(index: index, expectedBytes: length)
        let session: URLSession

        if let shared = shared {
            session = shared
        } else {
            session = makeSession(delegate: run)
            sessions.append(session)
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("bytes=\(segment.start)-\(segment.end)", forHTTPHeaderField: "Range")

        let task = session.dataTask(with: request)
        router?.register(run, for: task)

        runs.append(run)
        tasks.append(task)
    }

    for run in runs {
        run.startedAt = Date()
    }
    for task in tasks {
        task.resume()
    }

    var stats = runs.map { $0.wait() }

    for session in sessions {
        session.finishTasksAndInvalidate()
    }

    // 以最早开始时间作为整体起点，结果按分段顺序返回。
    if let earliest = stats.map({ $0.startedAt }).min() {
        stats = stats.map { stat in
            RunStats(index: stat.index, bytes: stat.bytes, startedAt: earliest,
                     finishedAt: stat.finishedAt, firstByteAt: stat.firstByteAt,
                     statusCode: stat.statusCode, totalBytes: stat.totalBytes,
                     acceptRanges: stat.acceptRanges, contentRange: stat.contentRange,
                     rangeIgnored: stat.rangeIgnored, error: stat.error)
        }
    }

    return stats.sorted { $0.index < $1.index }
}

func splitSegments(total: Int64, channels: Int) -> [(start: Int64, end: Int64)] {
    // 每段至少 1 MiB，避免小文件切片过多。
    let count = Int64(max(1, min(channels, Int(total / 1_048_576))))
    let base = total / count
    let remainder = total % count

    var segments: [(Int64, Int64)] = []
    var start: Int64 = 0

    for index in 0..<count {
        let length = base + (Int64(index) < remainder ? 1 : 0)
        segments.append((start, start + length - 1))
        start += length
    }

    return segments
}

// MARK: - 主流程

let options = parseOptions()

print("URL: \(options.url.absoluteString.prefix(120))\(options.url.absoluteString.count > 120 ? "…" : "")")
print("Host: \(options.url.host ?? "<unknown>")")

// 1. 探测 Range 支持与总大小
let probe = runSegments(url: options.url, segments: [(0, 0)], sharedSession: false)[0]

if let error = probe.error {
    print("探测失败: \(error.localizedDescription)")
    exit(1)
}

let totalText = probe.totalBytes > 0
    ? String(format: "%.1f MB", Double(probe.totalBytes) / 1_048_576)
    : "<unknown>"

print("探测: HTTP \(probe.statusCode), Accept-Ranges: \(probe.acceptRanges.isEmpty ? "<none>" : probe.acceptRanges), " +
      "Content-Range: \(probe.contentRange.isEmpty ? "<none>" : probe.contentRange), 总大小: \(totalText)")

guard probe.statusCode == 206, probe.totalBytes > 0 else {
    print("该 URL 未按 Range 响应（HTTP \(probe.statusCode)），无法多通道；请确认 URL 未过期。")
    exit(1)
}

let sample = min(options.sampleBytes, probe.totalBytes)
guard sample >= 1_048_576 else {
    print("文件太小（\(probe.totalBytes) 字节），无需测速。")
    exit(0)
}

print(String(format: "采样: %.1f MB，通道: %d，轮数: %d%s",
             Double(sample) / 1_048_576, options.channels, options.rounds,
             options.sharedSession ? "，共用 session" : ""))

var bestSingle: Double = 0
var bestMulti: Double = 0

func report(_ label: String, _ stats: [RunStats]) -> Double {
    let bytes = stats.reduce(Int64(0)) { $0 + $1.bytes }
    guard let earliest = stats.map({ $0.startedAt }).min(),
          let latest = stats.map({ $0.finishedAt }).max() else {
        return 0
    }

    let seconds = max(latest.timeIntervalSince(earliest), 0.000_001)
    let mbps = Double(bytes) / seconds / 1_048_576
    let firstByte = stats.compactMap { $0.timeToFirstByte }.min()

    let ttfbText = firstByte.map { String(format: " TTFB %.0f ms", $0 * 1000) } ?? ""
    print(String(format: "  %@ %6.2f MB / %6.2f s = %6.2f MB/s%@",
                 label, Double(bytes) / 1_048_576, seconds, mbps, ttfbText))

    if stats.count > 1 {
        let perSegment = stats.map { String(format: "%.1f", $0.megabytesPerSecond) }.joined(separator: ", ")
        print("    分段速率(MB/s): \(perSegment)")

        if let failure = stats.first(where: { $0.error != nil })?.error {
            print("    警告: \(failure.localizedDescription)")
        }
    }

    return mbps
}

for round in 1...options.rounds {
    print("第 \(round) 轮")

    let runSingle = {
        let stats = runSegments(url: options.url, segments: [(0, sample - 1)], sharedSession: false)
        bestSingle = max(bestSingle, report("单连接:", stats))
    }

    let runMulti = {
        let stats = runSegments(url: options.url,
                                segments: splitSegments(total: sample, channels: options.channels),
                                sharedSession: options.sharedSession)
        bestMulti = max(bestMulti, report("\(options.channels) 通道:", stats))
    }

    // 交替先后顺序，抵消连接预热带来的偏差。
    if round % 2 == 1 {
        runSingle()
        runMulti()
    } else {
        runMulti()
        runSingle()
    }
}

print("")
if bestSingle > 0, bestMulti > 0 {
    print(String(format: "汇总: 单连接最佳 %.2f MB/s，%d 通道最佳 %.2f MB/s，加速比 %.2fx",
                 bestSingle, options.channels, bestMulti, bestMulti / bestSingle))
} else {
    print("测量未取得有效结果。")
}
