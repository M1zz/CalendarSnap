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
    ///
    /// 달력을 옆으로 눕혀 찍은 사진(EXIF 회전정보 없는 스크린샷 포함)은 네 방향
    /// 모두 시도해 가장 잘 읽힌 방향을 씁니다. 이때 "요일 헤더·날짜 숫자가 몇 개
    /// 읽혔나"만 보면 안 됩니다 — 180° 뒤집힌 방향도 헤더와 숫자는 멀쩡히 읽히지만
    /// 헤더가 격자 아래에 오고 요일 순서가 좌우 반대라 일정은 하나도 안 나옵니다.
    /// 그래서 방향마다 실제로 격자 파싱까지 해보고 **일정이 가장 많이 나온 방향**을
    /// 고릅니다. 달력이 아닌 사진(통신문 등)은 예전처럼 줄 수로 판단합니다.
    static func recognizeLines(in image: UIImage) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        let base = CGImagePropertyOrientation(image.imageOrientation)
        let orientations = [base] + [CGImagePropertyOrientation.up, .right, .left, .down]
            .filter { $0 != base }

        var best: [RecognizedLine] = []
        var bestQuality: CalendarGridParser.Quality?

        for orientation in orientations {
            guard let lines = try? await recognize(cgImage: cgImage, orientation: orientation),
                  !lines.isEmpty else { continue }
            let quality = CalendarGridParser.quality(of: lines)
            if bestQuality.map({ quality > $0 }) ?? true {
                best = lines
                bestQuality = quality
            }
            // 이미 달력으로 잘 읽혔으면 나머지 방향은 볼 필요 없음
            if let bestQuality, CalendarGridParser.isConfidentCalendar(bestQuality) { break }
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
