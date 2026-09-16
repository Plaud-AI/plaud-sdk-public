import Foundation
import Combine

/// Transcription state
enum TranscriptionState {
    case idle
    case uploading(Float)
    case submitting
    case processing(String)
    case completed([TranscriptionResult])  // Structured results
    case failed(String)
}

/// Transcription manager: upload -> submit -> poll complete flow
///
/// Auth notes (see PARTNER_API_GUIDE.md):
/// - File upload: Bearer user_access_token
/// - Transcription submit/query: X-Client-Id + X-Client-Api-Key
///
/// Single shared instance with one global `stateSubject`, so a new transcription must fully
/// supersede any earlier one. Each run captures a `generation`; every state emit and poll step
/// is gated on it being current, so a slow earlier task's poll (e.g. one stuck in PROGRESS while
/// the server queue was backed up) can no longer overwrite a newer task's completed result.
final class TranscriptionManager {

    static let shared = TranscriptionManager()

    private let api = PlaudAPIService.shared
    private let pollInterval: TimeInterval = 5
    /// 240 x 5s = 20 min — the server queue can back up, so leave generous headroom.
    private let maxPolls = 240

    let stateSubject = CurrentValueSubject<TranscriptionState, Never>(.idle)
    var statePublisher: AnyPublisher<TranscriptionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    /// Bumped on every transcribe()/reset(); stale in-flight tasks are identified by the
    /// generation they captured at start and are silently dropped once it is no longer current.
    private var activeGeneration = 0

    private init() {}

    /// Emit only if `gen` is still the active generation (drops stale-task updates).
    private func emit(_ state: TranscriptionState, _ gen: Int) {
        guard gen == activeGeneration else { return }
        stateSubject.send(state)
    }

    // MARK: - Complete Transcription Flow

    /// Start complete transcription flow from a local audio file
    func transcribe(audioPath: String, filetype: String? = nil) {
        activeGeneration += 1
        let gen = activeGeneration

        // 根据文件扩展名自动检测格式
        let actualType = filetype ?? (audioPath as NSString).pathExtension.lowercased()

        guard FileManager.default.fileExists(atPath: audioPath) else {
            emit(.failed("Audio file not found: \(audioPath)"), gen)
            return
        }

        emit(.uploading(0), gen)
        AppLog.log("[Transcription] Starting transcription flow (gen \(gen)): \(audioPath), type=\(actualType)")

        uploadFile(path: audioPath, filetype: actualType, gen: gen) { [weak self] result in
            switch result {
            case .success(let downloadUrl):
                AppLog.log("[Transcription] Upload complete, downloadUrl obtained")
                self?.submitAndPoll(fileURL: downloadUrl, gen: gen)
            case .failure(let error):
                AppLog.log("[Transcription] Upload failed: \(error.localizedDescription)")
                self?.emit(.failed("Upload failed: \(error.localizedDescription)"), gen)
            }
        }
    }

    // MARK: - Step 1: File Upload (S3 Multipart 3-step)

    private func uploadFile(path: String, filetype: String, gen: Int, completion: @escaping (Result<String, Error>) -> Void) {
        guard let fileData = FileManager.default.contents(atPath: path) else {
            completion(.failure(APIError.noData))
            return
        }
        let filesize = fileData.count
        let fileMd5 = PlaudAPIService.fileMD5(at: path)
        let token = api.userAccessToken

        AppLog.log("[Transcription] Step 1: generate-presigned-urls (size=\(filesize), type=\(filetype))")

        api.generatePresignedURLs(filesize: filesize, filetype: filetype, token: token) { [weak self] result in
            switch result {
            case .success(let presigned):
                let chunkSize = presigned.chunkSize ?? PlaudAPIService.chunkSize
                AppLog.log("[Transcription] Got \(presigned.parts.count) part URLs, fileId=\(presigned.fileId)")
                self?.uploadParts(
                    fileData: fileData, parts: presigned.parts, chunkSize: chunkSize,
                    fileId: presigned.fileId, uploadId: presigned.uploadId,
                    filetype: filetype, fileMd5: fileMd5, token: token, gen: gen,
                    completion: completion
                )
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    /// PUT parts to S3 one by one, collect ETags
    private func uploadParts(
        fileData: Data, parts: [PresignedPart], chunkSize: Int,
        fileId: String, uploadId: String, filetype: String, fileMd5: String?,
        token: String, gen: Int, completion: @escaping (Result<String, Error>) -> Void
    ) {
        var partResults: [[String: Any]] = []
        let totalParts = parts.count

        func uploadNext(index: Int) {
            guard index < totalParts else {
                AppLog.log("[Transcription] Step 3: complete-upload (\(totalParts) parts)")
                self.completeUpload(
                    fileId: fileId, uploadId: uploadId, partList: partResults,
                    filetype: filetype, fileMd5: fileMd5, token: token, gen: gen,
                    completion: completion
                )
                return
            }

            let part = parts[index]
            let start = index * chunkSize
            let end = min(start + chunkSize, fileData.count)
            let chunk = fileData[start..<end]

            let progress = Float(index) / Float(totalParts)
            emit(.uploading(progress), gen)
            AppLog.log("[Transcription] Step 2: PUT part \(part.partNumber)/\(totalParts) (\(chunk.count) bytes)")

            api.uploadPartToS3(presignedURL: part.presignedUrl, data: Data(chunk)) { [weak self] result in
                switch result {
                case .success(let etag):
                    partResults.append(["PartNumber": part.partNumber, "ETag": etag])
                    uploadNext(index: index + 1)
                case .failure(let error):
                    self?.emit(.failed("Part \(part.partNumber) upload failed"), gen)
                    completion(.failure(error))
                }
            }
        }

        uploadNext(index: 0)
    }

    private func completeUpload(
        fileId: String, uploadId: String, partList: [[String: Any]],
        filetype: String, fileMd5: String?, token: String, gen: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        emit(.uploading(1.0), gen)

        api.completeUpload(fileId: fileId, uploadId: uploadId, partList: partList,
                           filetype: filetype, fileMd5: fileMd5, token: token) { result in
            switch result {
            case .success(let resp):
                guard let downloadUrl = resp.downloadUrl, !downloadUrl.isEmpty else {
                    completion(.failure(APIError.noData))
                    return
                }
                AppLog.log("[Transcription] complete-upload success, DownloadUrl valid for 24h")
                completion(.success(downloadUrl))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Step 2: Submit Transcription + Polling

    private func submitAndPoll(fileURL: String, gen: Int) {
        emit(.submitting, gen)

        resolveTranscriptionAuth { [weak self] result in
            switch result {
            case .success(let headers):
                self?.doSubmit(fileURL: fileURL, headers: headers, gen: gen)
            case .failure(let error):
                self?.emit(.failed("Failed to get transcription auth: \(error.localizedDescription)"), gen)
            }
        }
    }

    /// Transcription auth headers (X-Client-Id + X-Client-Api-Key)
    private func resolveTranscriptionAuth(completion: @escaping (Result<[String: String], Error>) -> Void) {
        let headers = api.transcriptionAuthHeaders
        guard !headers["X-Client-Id"]!.isEmpty, !headers["X-Client-Api-Key"]!.isEmpty else {
            completion(.failure(APIError.missingCredentials("PLAUD_CLIENT_ID or PLAUD_API_KEY not configured")))
            return
        }
        completion(.success(headers))
    }

    private func doSubmit(fileURL: String, headers: [String: String], gen: Int) {
        AppLog.log("[Transcription] Submitting transcription task...")

        api.submitTranscription(fileURL: fileURL, params: nil, authHeaders: headers) { [weak self] result in
            switch result {
            case .success(let resp):
                // Backend returns top-level transcription_id
                let tid = resp.transcriptionId ?? resp.data?.taskId ?? ""
                guard !tid.isEmpty else {
                    let msg = resp.message ?? resp.statusString ?? "unknown error"
                    AppLog.log("[Transcription] Submit failed: status=\(resp.statusString ?? "?"), message=\(resp.message ?? "?"), full response printed above")
                    self?.emit(.failed("Transcription submit failed: \(msg)"), gen)
                    return
                }
                AppLog.log("[Transcription] Transcription task submitted: transcription_id=\(tid), status=\(resp.statusString ?? "?")")
                self?.emit(.processing("PENDING"), gen)
                self?.pollResult(transcriptionId: tid, headers: headers, attempt: 1, gen: gen)
            case .failure(let error):
                self?.emit(.failed("Submit transcription failed: \(error.localizedDescription)"), gen)
            }
        }
    }

    // MARK: - Polling

    private func pollResult(transcriptionId: String, headers: [String: String], attempt: Int, gen: Int) {
        // Superseded by a newer transcription — stop this poll loop entirely.
        guard gen == activeGeneration else { return }
        guard attempt <= maxPolls else {
            emit(.failed("Transcription timed out after \(maxPolls) polls"), gen)
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            guard let self = self else { return }
            // Dropped while waiting — don't even fire the network request.
            guard gen == self.activeGeneration else { return }

            self.api.getTranscriptionResult(transcriptionId: transcriptionId, authHeaders: headers) { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let resp):
                    // status at top level: PENDING / RECEIVED / STARTED / PROGRESS / SUCCESS / FAILURE / REVOKED
                    let status = resp.statusString ?? resp.data?.taskStatus ?? ""
                    AppLog.log("[Transcription] Poll \(attempt)/\(self.maxPolls) (gen \(gen)): status=\(status)")

                    switch status.uppercased() {
                    case "SUCCESS":
                        let results = resp.data?.results ?? []
                        let fullText = resp.data?.fullText ?? ""
                        AppLog.log("[Transcription] Transcription complete! textLength=\(fullText.count), resultsCount=\(results.count)")
                        self.emit(.completed(results), gen)

                    case "FAILURE", "REVOKED":
                        self.emit(.failed("Transcription failed: \(resp.message ?? status)"), gen)

                    case "PENDING", "RECEIVED", "STARTED", "PROGRESS":
                        self.emit(.processing(status), gen)
                        self.pollResult(transcriptionId: transcriptionId, headers: headers, attempt: attempt + 1, gen: gen)

                    default:
                        // Unknown status, continue polling
                        self.emit(.processing(status), gen)
                        self.pollResult(transcriptionId: transcriptionId, headers: headers, attempt: attempt + 1, gen: gen)
                    }

                case .failure(let error):
                    self.emit(.failed("Failed to query transcription result: \(error.localizedDescription)"), gen)
                }
            }
        }
    }

    /// Reset state — also invalidates any in-flight task so its polls stop emitting.
    func reset() {
        activeGeneration += 1
        stateSubject.send(.idle)
    }
}
