import Darwin

final class MediaCommandLock {
    private var descriptor: Int32

    // Retain the original microphone path so every action also serializes with older binaries.
    static var defaultPath: String { "/tmp/teams-cli-microphone-\(getuid()).lock" }

    init(path: String = MediaCommandLock.defaultPath) throws {
        descriptor = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw MicrophoneCommandError.lockUnavailable }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_uid == getuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_mode & mode_t(0o077) == 0 else {
            close(descriptor)
            descriptor = -1
            throw MicrophoneCommandError.lockUnavailable
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let busy = errno == EWOULDBLOCK
            close(descriptor)
            descriptor = -1
            throw busy ? MicrophoneCommandError.commandInProgress : .lockUnavailable
        }
    }

    func release() {
        if descriptor >= 0 {
            close(descriptor)
            descriptor = -1
        }
    }

    // Keep the inode when releasing, so waiting processes cannot acquire different files.
    deinit { release() }
}
