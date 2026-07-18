import Foundation
import CommonCrypto

/// Plaud Open Platform API Service
///
/// Authentication:
/// - user_access_token (user-level): for SDK /open/partner/sdk/* and file upload /open/partner/files/*
/// - X-Client-Id + X-Client-Api-Key: for transcription endpoints /open/partner/ai/*
/// - X-Device-Signature: for metadata and version/latest (SDK internal)
final class PlaudAPIService {

    static let shared = PlaudAPIService()

    private let baseURL = "https://platform-us.plaud.ai/developer/api"
    private let session = URLSession.shared

    /// 5 MB chunk size (required by API)
    static let chunkSize = 5 * 1024 * 1024

    private init() {}

    // MARK: - Configuration

    private var clientId: String {
        Bundle.main.object(forInfoDictionaryKey: "PlaudClientId") as? String ?? ""
    }

    private var apiKey: String {
        Bundle.main.object(forInfoDictionaryKey: "PlaudApiKey") as? String ?? ""
    }

    /// User Access Token (for SDK endpoints and file upload)
    var userAccessToken: String {
        if let token = Bundle.main.object(forInfoDictionaryKey: "UserAccessToken") as? String, !token.isEmpty {
            return token
        }
        // Fallback to legacy PartnerToken
        return Bundle.main.object(forInfoDictionaryKey: "PartnerToken") as? String ?? ""
    }

    /// Transcription auth headers (X-Client-Id + X-Client-Api-Key)
    var transcriptionAuthHeaders: [String: String] {
        ["X-Client-Id": clientId, "X-Client-Api-Key": apiKey]
    }

    // MARK: - File Upload 3-Step Flow (S3 Multipart)

    /// Step 1: Request presigned URLs for multipart upload
    /// POST /open/partner/files/upload/generate-presigned-urls
    /// Auth: Bearer user_access_token
    func generatePresignedURLs(
        filesize: Int,
        filetype: String,
        token: String,
        completion: @escaping (Result<PresignedURLResponse, Error>) -> Void
    ) {
        let url = URL(string: "\(baseURL)/open/partner/files/upload/generate-presigned-urls")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body: [String: Any] = ["filesize": filesize, "filetype": filetype]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        perform(request, completion: completion)
    }

    /// Step 2: PUT chunk data directly to S3 (no auth needed, uses presigned URL)
    func uploadPartToS3(
        presignedURL: String,
        data: Data,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: presignedURL) else {
            completion(.failure(APIError.invalidURL(presignedURL)))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.httpBody = data
        request.timeoutInterval = 120

        #if DEBUG
        print("[PlaudAPI] >>> PUT S3 part (\(data.count) bytes)")
        #endif
        session.dataTask(with: request) { _, response, error in
            if let error = error {
                #if DEBUG
                print("[PlaudAPI] <<< S3 PUT error: \(error.localizedDescription)")
                #endif
                completion(.failure(error))
                return
            }
            guard let httpResponse = response as? HTTPURLResponse else {
                completion(.failure(APIError.noData))
                return
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                completion(.failure(APIError.httpError(httpResponse.statusCode, "S3 PUT failed")))
                return
            }
            let etag = httpResponse.value(forHTTPHeaderField: "ETag")?.replacingOccurrences(of: "\"", with: "") ?? ""
            #if DEBUG
            print("[PlaudAPI] <<< S3 PUT OK, ETag=\(etag)")
            #endif
            completion(.success(etag))
        }.resume()
    }

    /// Step 3: Notify server to merge chunks
    /// POST /open/partner/files/upload/complete-upload
    func completeUpload(
        fileId: String,
        uploadId: String,
        partList: [[String: Any]],
        filetype: String,
        fileMd5: String?,
        token: String,
        completion: @escaping (Result<CompleteUploadResponse, Error>) -> Void
    ) {
        let url = URL(string: "\(baseURL)/open/partner/files/upload/complete-upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 120

        var body: [String: Any] = [
            "file_id": fileId,
            "upload_id": uploadId,
            "part_list": partList,
            "filetype": filetype,
        ]
        if let md5 = fileMd5 { body["file_md5"] = md5 }
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        perform(request, completion: completion)
    }

    // MARK: - Transcription (Auth: X-Client-Id + X-Client-Api-Key)

    /// Submit transcription task
    /// POST /open/partner/ai/transcriptions/
    func submitTranscription(
        fileURL: String,
        params: [String: Any]?,
        authHeaders: [String: String],
        completion: @escaping (Result<TranscriptionSubmitResponse, Error>) -> Void
    ) {
        let url = URL(string: "\(baseURL)/open/partner/ai/transcriptions/")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        for (key, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let defaultParams: [String: Any] = [
            "transcribe": ["language": "auto", "model": "plaud-fast-whisper"],
            "vad": ["decode_silence": false],
            "diarization": ["enabled": false, "return_embedding": false],
        ]

        let body: [String: Any] = [
            "file_url": fileURL,
            "params": params ?? defaultParams,
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        perform(request, completion: completion)
    }

    /// Get transcription result
    /// GET /open/partner/ai/transcriptions/{transcription_id}
    func getTranscriptionResult(
        transcriptionId: String,
        authHeaders: [String: String],
        completion: @escaping (Result<TranscriptionResultResponse, Error>) -> Void
    ) {
        let url = URL(string: "\(baseURL)/open/partner/ai/transcriptions/\(transcriptionId)")!
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        for (key, value) in authHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }

        perform(request, completion: completion)
    }

    // MARK: - Utilities

    /// Calculate file MD5
    static func fileMD5(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        _ = data.withUnsafeBytes { CC_MD5($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Generic Request

    private func perform<T: Decodable>(_ request: URLRequest, completion: @escaping (Result<T, Error>) -> Void) {
        let method = request.httpMethod ?? "GET"
        let urlStr = request.url?.absoluteString ?? "?"
        let isS3 = urlStr.contains("amazonaws.com")
        #if DEBUG
        if !isS3 {
            print("[PlaudAPI] >>> \(method) \(urlStr)")
        }
        #endif

        session.dataTask(with: request) { data, response, error in
            if let error = error {
                #if DEBUG
                print("[PlaudAPI] <<< NETWORK ERROR: \(error.localizedDescription)")
                #endif
                completion(.failure(error))
                return
            }
            guard let data = data else {
                completion(.failure(APIError.noData))
                return
            }
            let httpResponse = response as? HTTPURLResponse
            let statusCode = httpResponse?.statusCode ?? 0

            guard (200...299).contains(statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? ""
                #if DEBUG
                print("[PlaudAPI] <<< HTTP \(statusCode): \(body)")
                #endif
                completion(.failure(APIError.httpError(statusCode, body)))
                return
            }
            do {
                let decoded = try JSONDecoder().decode(T.self, from: data)
                completion(.success(decoded))
            } catch {
                if T.self == EmptyResponse.self, let empty = EmptyResponse() as? T {
                    completion(.success(empty))
                } else {
                    #if DEBUG
                    print("[PlaudAPI] <<< Decode error: \(error)")
                    #endif
                    completion(.failure(error))
                }
            }
        }.resume()
    }
}

// MARK: - Response Models

struct EmptyResponse: Decodable {
    init() {}
}

/// generate-presigned-urls response
/// { FileId, UploadId, ChunkSize, Parts: [{PartNumber, PresignedUrl}] }
struct PresignedURLResponse: Decodable {
    let fileId: String
    let uploadId: String
    let chunkSize: Int?
    let parts: [PresignedPart]

    enum CodingKeys: String, CodingKey {
        case fileId = "FileId"
        case uploadId = "UploadId"
        case chunkSize = "ChunkSize"
        case parts = "Parts"
    }
}

struct PresignedPart: Decodable {
    let partNumber: Int
    let presignedUrl: String

    enum CodingKeys: String, CodingKey {
        case partNumber = "PartNumber"
        case presignedUrl = "PresignedUrl"
    }
}

/// complete-upload response
/// { FileId, FileType, DownloadUrl, FileMd5 }
struct CompleteUploadResponse: Decodable {
    let fileId: String?
    let fileType: String?
    let downloadUrl: String?
    let fileMd5: String?

    enum CodingKeys: String, CodingKey {
        case fileId = "FileId"
        case fileType = "FileType"
        case downloadUrl = "DownloadUrl"
        case fileMd5 = "FileMd5"
    }
}

struct TranscriptionSubmitResponse: Decodable {
    let status: AnyCodable?
    let message: String?
    let data: TranscriptionSubmitData?
    let topTranscriptionId: String?  // top-level transcription_id

    var transcriptionId: String? { topTranscriptionId ?? data?.taskId }
    var statusString: String? {
        if let s = status?.value as? String { return s }
        if let n = status?.value as? Int { return "\(n)" }
        return nil
    }
    var isSuccess: Bool {
        if let n = status?.value as? Int { return n == 0 || n == 200 }
        if let s = status?.value as? String { return s == "SUCCESS" || s == "0" }
        // Consider success if transcription_id is present
        if transcriptionId != nil { return true }
        return false
    }

    enum CodingKeys: String, CodingKey {
        case status, message, data
        case topTranscriptionId = "transcription_id"
    }
}

struct TranscriptionSubmitData: Decodable {
    let taskId: String?

    enum CodingKeys: String, CodingKey {
        case taskId = "task_id"
    }
}

/// GET /api/v1/tob/transcribe/:task_id response
struct TranscriptionResultResponse: Decodable {
    let status: AnyCodable?
    let message: String?
    let data: TranscriptionData?

    var statusString: String? {
        if let s = status?.value as? String { return s }
        if let n = status?.value as? Int { return "\(n)" }
        return nil
    }
}

struct TranscriptionData: Decodable {
    let text: String?           // may contain text directly
    let segments: [TranscriptionSegment]?
    let results: [TranscriptionResult]?  // actual response uses results array
    let taskStatus: String?

    /// Concatenate text from all results
    var fullText: String {
        if let t = text, !t.isEmpty { return t }
        return results?.map { $0.text ?? "" }.joined(separator: "\n\n") ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case text, segments, results
        case taskStatus = "task_status"
    }
}

struct TranscriptionResult: Codable {
    let speakerId: String?
    let start: Double?
    let end: Double?
    let text: String?
    let language: String?

    enum CodingKeys: String, CodingKey {
        case start, end, text, language
        case speakerId = "speaker_id"
    }
}

struct TranscriptionSegment: Decodable {
    let start: Double?
    let end: Double?
    let text: String?
    let speaker: String?
}

/// Decodes arbitrary JSON values
struct AnyCodable: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let string = try? container.decode(String.self) {
            value = string
        } else {
            value = NSNull()
        }
    }
}

enum APIError: LocalizedError {
    case noData
    case httpError(Int, String)
    case invalidURL(String)
    case missingCredentials(String)

    var errorDescription: String? {
        switch self {
        case .noData: return "No data received"
        case .httpError(let code, let body): return "HTTP \(code): \(body)"
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .missingCredentials(let msg): return msg
        }
    }
}
