import Darwin
import Foundation

enum NativeValidationOutputError: Error, Equatable {
    case empty
    case relative
    case restricted
    case symlink
    case missingParent
    case invalidTarget
    case system(Int32)
}

struct NativeValidationOutputPath: Equatable, Sendable {
    let url: URL

    static let nestedRepositoryRoot = ancestor(
        of: URL(fileURLWithPath: #filePath),
        count: 5
    )
    static let outerDocsRoot = nestedRepositoryRoot
        .deletingLastPathComponent()
        .appendingPathComponent("docs", isDirectory: true)
        .standardizedFileURL
    static let restrictedRoots = [nestedRepositoryRoot, outerDocsRoot]

    static func validate(
        _ rawPath: String,
        restrictedRoots: [URL] = restrictedRoots
    ) throws -> Self {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { throw NativeValidationOutputError.empty }
        guard NSString(string: trimmed).isAbsolutePath else {
            throw NativeValidationOutputError.relative
        }

        let url = URL(fileURLWithPath: trimmed).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        for root in restrictedRoots {
            let standardizedRoot = root.standardizedFileURL
            let resolvedRoot = standardizedRoot.resolvingSymlinksInPath().standardizedFileURL
            guard contains(url, root: standardizedRoot) == false,
                  contains(resolved, root: resolvedRoot) == false
            else { throw NativeValidationOutputError.restricted }
        }
        try rejectSymlinkComponents(of: url)
        return Self(url: url)
    }

    private static func ancestor(of url: URL, count: Int) -> URL {
        (0..<count).reduce(url) { value, _ in value.deletingLastPathComponent() }
            .standardizedFileURL
    }

    private static func contains(_ url: URL, root: URL) -> Bool {
        url.path == root.path || url.path.hasPrefix(root.path + "/")
    }

    private static func rejectSymlinkComponents(of url: URL) throws {
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        let components = url.pathComponents.dropFirst()
        for (index, component) in components.enumerated() {
            current.appendPathComponent(component)
            var value = stat()
            if lstat(current.path, &value) != 0 {
                if errno == ENOENT, index == components.count - 1 { return }
                throw errno == ENOENT
                    ? NativeValidationOutputError.missingParent
                    : NativeValidationOutputError.system(errno)
            }
            guard value.st_mode & S_IFMT != S_IFLNK else {
                throw NativeValidationOutputError.symlink
            }
            if index < components.count - 1 {
                guard value.st_mode & S_IFMT == S_IFDIR else {
                    throw NativeValidationOutputError.missingParent
                }
            } else {
                guard value.st_mode & S_IFMT == S_IFREG else {
                    throw NativeValidationOutputError.invalidTarget
                }
            }
        }
    }
}

enum NativeAtomicOutputWriter {
    static func write(_ data: Data, to output: NativeValidationOutputPath) throws {
        let parent = output.url.deletingLastPathComponent()
        let targetName = output.url.lastPathComponent
        let directory = open(parent.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard directory >= 0 else { throw NativeValidationOutputError.system(errno) }
        defer { close(directory) }

        var targetInfo = stat()
        if fstatat(directory, targetName, &targetInfo, AT_SYMLINK_NOFOLLOW) == 0 {
            guard targetInfo.st_mode & S_IFMT != S_IFLNK else {
                throw NativeValidationOutputError.symlink
            }
        } else if errno != ENOENT {
            throw NativeValidationOutputError.system(errno)
        }

        let temporaryName = ".macactivity-native-validation-\(UUID().uuidString).tmp"
        let file = openat(
            directory,
            temporaryName,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard file >= 0 else { throw NativeValidationOutputError.system(errno) }
        var shouldRemoveTemporary = true
        defer {
            close(file)
            if shouldRemoveTemporary {
                unlinkat(directory, temporaryName, 0)
            }
        }

        try data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(
                    file,
                    baseAddress.advanced(by: written),
                    bytes.count - written
                )
                guard count > 0 else { throw NativeValidationOutputError.system(errno) }
                written += count
            }
        }
        guard fsync(file) == 0 else { throw NativeValidationOutputError.system(errno) }
        guard renameat(directory, temporaryName, directory, targetName) == 0 else {
            throw NativeValidationOutputError.system(errno)
        }
        shouldRemoveTemporary = false
    }
}
