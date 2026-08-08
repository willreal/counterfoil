import Foundation

// CLI harness: counterfoil-cli --transcribe <wav>
// Built separately from the app so the app binary stays a pure SwiftUI entry point.
@main
struct CLIMain {
    static func main() {
        let args = CommandLine.arguments
        if args.count >= 3 && args[1] == "--transcribe" {
            let wavPath = args[2]
            do {
                let transcriber = Transcriber.shared
                try transcriber.forceLoadSync()
                let text = try transcriber.transcribeTest(path: wavPath)
                print(text)
            } catch {
                print("Transcribe error: \(error.localizedDescription)")
                exit(1)
            }
            return
        }
        print("usage: counterfoil-cli --transcribe <wav>")
        exit(2)
    }
}
