import Foundation

enum EnvLoader {
    private static var cached: [String: String]?

    static func loadEnv() -> [String: String] {
        if let cached { return cached }
        var result: [String: String] = [:]

        for basePath in searchPaths() {
            let fileURL = URL(fileURLWithPath: basePath).appendingPathComponent(".env")
            guard let content = try? String(contentsOf: fileURL, encoding: .utf8) else { continue }

            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

                let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard parts.count == 2 else { continue }

                let key = parts[0].trimmingCharacters(in: .whitespaces)
                var value = String(parts[1]).trimmingCharacters(in: .whitespaces)
                if value.hasPrefix("\"") && value.hasSuffix("\"") {
                    value = String(value.dropFirst().dropLast())
                } else if value.hasPrefix("'") && value.hasSuffix("'") {
                    value = String(value.dropFirst().dropLast())
                }
                result[key] = value
            }
            break
        }

        cached = result
        return result
    }

    static func value(for key: String) -> String? {
        loadEnv()[key]
    }

    private static func searchPaths() -> [String] {
        var paths: [String] = []

        // Current working directory (project root when running from Xcode or `swift run`)
        paths.append(FileManager.default.currentDirectoryPath)

        // Directory containing the executable (project root when executable is in .build/debug/)
        if let execPath = Bundle.main.executablePath {
            let execDir = (execPath as NSString).deletingLastPathComponent
            paths.append(execDir)
            // Go up to project root (executable is in .build/debug/ or .build/release/)
            let buildDir = (execDir as NSString).deletingLastPathComponent
            paths.append(buildDir)
            let projectRoot = (buildDir as NSString).deletingLastPathComponent
            paths.append(projectRoot)
            // gateway/ subdirectory (where whisper_gateway.py and its .env live)
            paths.append(projectRoot + "/gateway")
        }

        // User config directory
        paths.append(NSHomeDirectory() + "/.wisprclaw")

        return paths
    }
}
