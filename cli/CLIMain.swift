import Foundation

@main
struct CLIMain {
    static func main() {
        let args = CommandLine.arguments
        var wavPath: String?
        var modelName: String = "Parakeet V2"

        var i = 1
        while i < args.count {
            switch args[i] {
            case "--transcribe":
                if i + 1 < args.count { wavPath = args[i + 1]; i += 2 }
                else { i += 1 }
            case "--model":
                if i + 1 < args.count { modelName = args[i + 1]; i += 2 }
                else { i += 1 }
            default:
                i += 1
            }
        }

        if let path = wavPath {
            do {
                let transcriber = Transcriber.shared
                SettingsStore.shared.selectedModel = modelName
                try transcriber.forceLoadSync()
                let text = try transcriber.transcribeTest(path: path)
                print(text)
            } catch {
                print("Transcribe error: \(error.localizedDescription)")
                exit(1)
            }
            return
        }
        print("usage: counterfoil-cli --transcribe <wav> [--model <name>]")
        exit(2)
    }
}
