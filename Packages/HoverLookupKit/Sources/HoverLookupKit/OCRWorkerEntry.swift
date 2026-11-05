import AppKit
import Darwin

public extension ScreenTextService {
    internal static let workerArgument = "--odict-ocr-worker"

    static var isOCRWorker: Bool {
        CommandLine.arguments.count == 2 && CommandLine.arguments[1] == workerArgument
    }

    /// Opt in only in the application entry point. Library/test hosts continue
    /// to use the in-process engine and cannot accidentally launch themselves.
    static func enableProcessIsolation() {
        guard !isOCRWorker, !isRecoveryWorker, let executable = Bundle.main.executableURL else { return }
        OCRWorkerRuntime.shared.enable(executable: executable)
    }

    static func stopProcessIsolation() { OCRWorkerRuntime.shared.stop() }

    /// Runs before SwiftUI/AppKit application startup, with no coordinator,
    /// account, history, event monitor, screen capture or network services.
    static func runOCRWorker() async -> Int32 {
        let parentPID = getppid()
        guard isOCRWorker, parentPID > 1 else { return 1 }
        let parentExit = DispatchSource.makeProcessSource(identifier: parentPID, eventMask: .exit,
                                                         queue: .global(qos: .utility))
        parentExit.setEventHandler { _exit(1) }
        parentExit.resume()
        defer { parentExit.cancel() }
        // Also bound a child whose parent or IPC channel disappears during Vision.
        let watchdog = DispatchWorkItem { _exit(1) }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 65, execute: watchdog)
        defer { watchdog.cancel() }
        let io = BlockingWorkQueue(label: "HoverLookupKit.ocr-worker-io")
        do {
            let (request, image) = try await io.perform {
                try OCRWorkerChannel.configure(STDIN_FILENO)
                let request = try OCRWorkerChannel.receiveMessage(OCRWorkerRequest.self, from: STDIN_FILENO,
                                                                  limit: OCRWorkerChannel.requestLimit)
                _ = try request.pixelCount
                if request.mode == .verify { return (request, Optional<CGImage>.none) }
                let pixels = try OCRWorkerChannel.receive(count: request.pixelCount, from: STDIN_FILENO)
                return (request, Optional(try request.image(from: pixels)))
            }
            let response: OCRWorkerResponse
            do {
                let service = ScreenTextService()
                switch request.mode {
                case .verify:
                    response = OCRWorkerResponse(status: await verifyRecoveredModels() ? .success : .unavailable)
                case .text:
                    guard let image else { return 1 }
                    response = OCRWorkerResponse(status: .success,
                        text: try await service.recognize(image, maximumCount: request.maximumCount))
                case .word:
                    guard let image, let region = request.region, let point = request.point else { return 1 }
                    let hit = try await service.recognizeWord(image, region: region, point: point)
                    response = OCRWorkerResponse(status: .success, text: hit?.text, anchor: hit?.anchor)
                }
            } catch let failure as OCRFailure {
                response = OCRWorkerResponse(status: .failure, failure: failure)
            } catch HoverLookupError.noText {
                response = OCRWorkerResponse(status: .noText)
            } catch HoverLookupError.tooLong {
                response = OCRWorkerResponse(status: .tooLong)
            } catch {
                response = OCRWorkerResponse(status: .unavailable)
            }
            try await io.perform {
                try OCRWorkerChannel.sendMessage(response, to: STDOUT_FILENO, limit: OCRWorkerChannel.responseLimit)
            }
            return 0
        } catch { return 1 }
    }
}
