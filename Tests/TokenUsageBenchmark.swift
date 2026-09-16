import Foundation

@main
enum TokenUsageBenchmark {
    static func main() {
        guard CommandLine.arguments.count > 1 else {
            fputs("Usage: token-benchmark SESSION_DIRECTORY [ITERATIONS]\n", stderr)
            exit(2)
        }
        #if INCREMENTAL_BENCHMARK
        let reader = TokenUsageScanner(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))
        #endif
        let iterations = Int(CommandLine.arguments.dropFirst(2).first ?? "2") ?? 2
        for iteration in 1...iterations {
            let start = ProcessInfo.processInfo.systemUptime
            #if INCREMENTAL_BENCHMARK
            let summary = reader.read()
            #else
            let summary = LocalTokenUsageReader.read()
            #endif
            let seconds = ProcessInfo.processInfo.systemUptime - start
            print("read=\(iteration) seconds=\(String(format: "%.3f", seconds)) yesterday=\(summary?.yesterdayTokens ?? -1) cumulative=\(summary?.cumulativeTokens ?? -1)")
            fflush(stdout)
        }
    }
}
