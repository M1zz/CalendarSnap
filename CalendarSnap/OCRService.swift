import UIKit
import Vision

/// Vision 프레임워크로 달력 사진에서 텍스트를 추출합니다.
enum OCRService {
    enum OCRError: LocalizedError {
        case invalidImage
        case noText

        var errorDescription: String? {
            switch self {
            case .invalidImage: return "이미지를 처리할 수 없습니다."
            case .noText: return "사진에서 텍스트를 찾지 못했습니다."
            }
        }
    }

    /// 이미지에서 인식된 텍스트 라인 배열을 반환.
    /// 달력 레이아웃 특성상 위→아래, 왼→오른쪽 순으로 정렬됩니다.
    static func recognizeText(in image: UIImage) async throws -> [String] {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }

        return try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []

                // 위에서 아래, 왼쪽에서 오른쪽 순 정렬 (달력 셀 읽기 순서)
                let sorted = observations.sorted {
                    let a = $0.boundingBox, b = $1.boundingBox
                    if abs(a.midY - b.midY) > 0.02 { return a.midY > b.midY }
                    return a.minX < b.minX
                }

                let lines = sorted.compactMap { $0.topCandidates(1).first?.string }
                if lines.isEmpty {
                    continuation.resume(throwing: OCRError.noText)
                } else {
                    continuation.resume(returning: lines)
                }
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage,
                                                orientation: CGImagePropertyOrientation(image.imageOrientation))
            DispatchQueue.global(qos: .userInitiated).async {
                do { try handler.perform([request]) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }
}

extension CGImagePropertyOrientation {
    init(_ orientation: UIImage.Orientation) {
        switch orientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
