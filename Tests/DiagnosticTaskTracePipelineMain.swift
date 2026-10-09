import Foundation

@main enum DiagnosticTaskTracePipelineMain {
    static func main() throws {
        try DiagnosticTaskTraceLegacyExportTests.main()
        try DiagnosticTaskTraceHookExportTests.main()
        try DiagnosticTaskTraceDisplayTests.main()
        try DiagnosticTaskTraceDeliveryTests.main()
    }
}
