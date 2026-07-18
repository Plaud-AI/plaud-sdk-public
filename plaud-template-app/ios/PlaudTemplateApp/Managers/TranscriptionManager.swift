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
final class TranscriptionManager {

    static let shared = TranscriptionManager()

    private let api = PlaudAPIService.shared
    private let pollInterval: TimeInterval = 5
    private let maxPolls = 60

    let stateSubject = CurrentValueSubject<TranscriptionState, Never>(.idle)
    var statePublisher: AnyPublisher<TranscriptionState, Never> {
        stateSubject.eraseToAnyPublisher()
    }

    private init() {}

    // MARK: - Complete Transcription Flow

    /// Start complete transcription flow from a local audio file
    func transcribe(audioPath: String, filetype: String? = nil) {
        // 根据文件扩展名自动检测格式
        let actualType = filetype ?? (audioPath as NSString).pathExtension.lowercased()

        guard FileManager.default.fileExists(atPath: audioPath) else {
            stateSubject.send(.failed("Audio file not found: \(audioPath)"))
            return
        }

        stateSubject.send(.uploading(0))
        print("[Transcription] Starting transcription flow: \(audioPath), type=\(actualType)")

        uploadFile(path: audioPath, filetype: actualType) { [weak self] result in
            switch result {
            case .success(let downloadUrl):
                print("[Transcription] Upload complete, downloadUrl obtained")
                self?.submitAndPoll(fileURL: downloadUrl)
            case .failure(let error):
                print("[Transcription] Upload failed: \(error.localizedDescription)")
                self?.stateSubject.send(.failed("Upload failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Step 1: File Upload (S3 Multipart 3-step)

    private func uploadFile(path: String, filetype: String, completion: @escaping (Result<String, Error>) -> Void) {
        guard let fileData = FileManager.default.contents(atPath: path) else {
            completion(.failure(APIError.noData))
            return
        }
        let filesize = fileData.count
        let fileMd5 = PlaudAPIService.fileMD5(at: path)
        let token = api.userAccessToken

        print("[Transcription] Step 1: generate-presigned-urls (size=\(filesize), type=\(filetype))")

        api.generatePresignedURLs(filesize: filesize, filetype: filetype, token: token) { [weak self] result in
            switch result {
            case .success(let presigned):
                let chunkSize = presigned.chunkSize ?? PlaudAPIService.chunkSize
                print("[Transcription] Got \(presigned.parts.count) part URLs, fileId=\(presigned.fileId)")
                self?.uploadParts(
                    fileData: fileData, parts: presigned.parts, chunkSize: chunkSize,
                    fileId: presigned.fileId, uploadId: presigned.uploadId,
                    filetype: filetype, fileMd5: fileMd5, token: token,
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
        token: String, completion: @escaping (Result<String, Error>) -> Void
    ) {
        var partResults: [[String: Any]] = []
        let totalParts = parts.count

        func uploadNext(index: Int) {
            guard index < totalParts else {
                print("[Transcription] Step 3: complete-upload (\(totalParts) parts)")
                self.completeUpload(
                    fileId: fileId, uploadId: uploadId, partList: partResults,
                    filetype: filetype, fileMd5: fileMd5, token: token,
                    completion: completion
                )
                return
            }

            let part = parts[index]
            let start = index * chunkSize
            let end = min(start + chunkSize, fileData.count)
            let chunk = fileData[start..<end]

            let progress = Float(index) / Float(totalParts)
            stateSubject.send(.uploading(progress))
            print("[Transcription] Step 2: PUT part \(part.partNumber)/\(totalParts) (\(chunk.count) bytes)")

            api.uploadPartToS3(presignedURL: part.presignedUrl, data: Data(chunk)) { [weak self] result in
                switch result {
                case .success(let etag):
                    partResults.append(["PartNumber": part.partNumber, "ETag": etag])
                    uploadNext(index: index + 1)
                case .failure(let error):
                    self?.stateSubject.send(.failed("Part \(part.partNumber) upload failed"))
                    completion(.failure(error))
                }
            }
        }

        uploadNext(index: 0)
    }

    private func completeUpload(
        fileId: String, uploadId: String, partList: [[String: Any]],
        filetype: String, fileMd5: String?, token: String,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        stateSubject.send(.uploading(1.0))

        api.completeUpload(fileId: fileId, uploadId: uploadId, partList: partList,
                           filetype: filetype, fileMd5: fileMd5, token: token) { result in
            switch result {
            case .success(let resp):
                guard let downloadUrl = resp.downloadUrl, !downloadUrl.isEmpty else {
                    completion(.failure(APIError.noData))
                    return
                }
                print("[Transcription] complete-upload success, DownloadUrl valid for 24h")
                completion(.success(downloadUrl))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }

    // MARK: - Step 2: Submit Transcription + Polling

    private func submitAndPoll(fileURL: String) {
        stateSubject.send(.submitting)

        resolveTranscriptionAuth { [weak self] result in
            switch result {
            case .success(let headers):
                self?.doSubmit(fileURL: fileURL, headers: headers)
            case .failure(let error):
                self?.stateSubject.send(.failed("Failed to get transcription auth: \(error.localizedDescription)"))
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

    private func doSubmit(fileURL: String, headers: [String: String]) {
        print("[Transcription] Submitting transcription task...")

        api.submitTranscription(fileURL: fileURL, params: nil, authHeaders: headers) { [weak self] result in
            switch result {
            case .success(let resp):
                // Backend returns top-level transcription_id
                let tid = resp.transcriptionId ?? resp.data?.taskId ?? ""
                guard !tid.isEmpty else {
                    let msg = resp.message ?? resp.statusString ?? "unknown error"
                    print("[Transcription] Submit failed: status=\(resp.statusString ?? "?"), message=\(resp.message ?? "?"), full response printed above")
                    self?.stateSubject.send(.failed("Transcription submit failed: \(msg)"))
                    return
                }
                print("[Transcription] Transcription task submitted: transcription_id=\(tid), status=\(resp.statusString ?? "?")")
                self?.stateSubject.send(.processing("PENDING"))
                self?.pollResult(transcriptionId: tid, headers: headers, attempt: 1)
            case .failure(let error):
                self?.stateSubject.send(.failed("Submit transcription failed: \(error.localizedDescription)"))
            }
        }
    }

    // MARK: - Polling

    private func pollResult(transcriptionId: String, headers: [String: String], attempt: Int) {
        guard attempt <= maxPolls else {
            stateSubject.send(.failed("Transcription timed out after \(maxPolls) polls"))
            return
        }

        DispatchQueue.global().asyncAfter(deadline: .now() + pollInterval) { [weak self] in
            guard let self = self else { return }

            self.api.getTranscriptionResult(transcriptionId: transcriptionId, authHeaders: headers) { [weak self] result in
                guard let self = self else { return }

                switch result {
                case .success(let resp):
                    // status at top level: PENDING / RECEIVED / STARTED / PROGRESS / SUCCESS / FAILURE / REVOKED
                    let status = resp.statusString ?? resp.data?.taskStatus ?? ""
                    print("[Transcription] Poll \(attempt)/\(self.maxPolls): status=\(status)")

                    switch status.uppercased() {
                    case "SUCCESS":
                        let results = resp.data?.results ?? []
                        let fullText = resp.data?.fullText ?? ""
                        print("[Transcription] Transcription complete! textLength=\(fullText.count), resultsCount=\(results.count)")
                        self.stateSubject.send(.completed(results))

                    case "FAILURE", "REVOKED":
                        self.stateSubject.send(.failed("Transcription failed: \(resp.message ?? status)"))

                    case "PENDING", "RECEIVED", "STARTED", "PROGRESS":
                        self.stateSubject.send(.processing(status))
                        self.pollResult(transcriptionId: transcriptionId, headers: headers, attempt: attempt + 1)

                    default:
                        // Unknown status, continue polling
                        self.stateSubject.send(.processing(status))
                        self.pollResult(transcriptionId: transcriptionId, headers: headers, attempt: attempt + 1)
                    }

                case .failure(let error):
                    self.stateSubject.send(.failed("Failed to query transcription result: \(error.localizedDescription)"))
                }
            }
        }
    }

    /// Reset state
    func reset() {
        stateSubject.send(.idle)
    }
}
