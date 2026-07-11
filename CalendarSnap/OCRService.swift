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

    /// 이미지에서 텍스트 + 바운딩 박스를 반환.
    /// 사진이 옆으로 저장된 경우(EXIF 누락 스크린샷 등)를 대비해
    /// 인식량이 적으면 다른 방향으로도 시도해 가장 좋은 결과를 사용합니다.
    static func recognizeLines(in image: UIImage) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        let base = CGImagePropertyOrientation(image.imageOrientation)

        var best = (try? await recognize(cgImage: cgImage, orientation: base)) ?? []
        if best.count < 15 {
            for orientation in [CGImagePropertyOrientation.up, .right, .left, .down] where orientation != base {
                if let alt = try? await recognize(cgImage: cgImage, orientation: orientation),
                   alt.count > best.count {
                    best = alt
                }
            }
        }
        guard !best.isEmpty else { throw OCRError.noText }
        return best
    }

    /// 인식된 텍스트를 읽기 순서(위→아래, 왼→오른쪽) 문자열 배열로 반환.
    static func recognizeText(in image: UIImage) async throws -> [String] {
        readingOrder(try await recognizeLines(in: image)).map(\.text)
    }

    /// 위→아래, 왼→오른쪽 순 정렬 (달력 셀 읽기 순서).
    static func readingOrder(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.sorted {
            let a = $0.box, b = $1.box
            if abs(a.midY - b.midY) > 0.02 { return a.midY > b.midY }
            return a.minX < b.minX
        }
    }

    private static func recognize(cgImage: CGImage,
                                  orientation: CGImagePropertyOrientation) async throws -> [RecognizedLine] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines = observations.compactMap { obs -> RecognizedLine? in
                    guard let candidate = obs.topCandidates(1).first else { return nil }
                    return RecognizedLine(text: candidate.string, box: obs.boundingBox)
                }
                continuation.resume(returning: lines)
            }

            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["ko-KR", "en-US"]
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation)
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
