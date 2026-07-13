import Foundation
import KairosCLI

@main
struct KairosMain {
    static func main() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let args = Array(CommandLine.arguments.dropFirst())
        do {
            try await CLI.run(
                args: args,
                socketPath: "\(home)/.kairos/daemon.sock",
                spoolDir: "\(home)/.kairos/spool"
            )
        } catch {
            FileHandle.standardError.write(Data("kairos: \(error)\n".utf8))
            exit(1)
        }
    }
}
