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
    /// 달력을 옆으로 눕혀 찍은 사진(EXIF 회전정보 없는 스크린샷 포함)은
    /// 잘못된 방향에서도 글자 수는 꽤 나오지만 날짜 숫자가 거의 안 읽힙니다.
    /// 그래서 "줄 수"가 아니라 달력 격자로 얼마나 잘 읽혔는지(`calendarScore`)로
    /// 방향을 고르고, 달력이 아닌 사진(통신문 등)일 때만 줄 수로 판단합니다.
    static func recognizeLines(in image: UIImage) async throws -> [RecognizedLine] {
        guard let cgImage = image.cgImage else { throw OCRError.invalidImage }
        let base = CGImagePropertyOrientation(image.imageOrientation)

        var best = (try? await recognize(cgImage: cgImage, orientation: base)) ?? []
        var bestScore = CalendarGridParser.calendarScore(lines: best)

        // 이미 달력으로 잘 읽혔으면 추가 인식 없이 그대로 사용
        if !CalendarGridParser.isConfidentCalendar(score: bestScore) {
            for orientation in [CGImagePropertyOrientation.up, .right, .left, .down] where orientation != base {
                guard let alt = try? await recognize(cgImage: cgImage, orientation: orientation) else { continue }
                let altScore = CalendarGridParser.calendarScore(lines: alt)
                // 달력으로 읽힌 방향이 있으면 그중 최고점, 아니면 종전대로 줄 수로 비교
                let better = (altScore > 0 || bestScore > 0)
                    ? altScore > bestScore
                    : alt.count > best.count
                if better {
                    best = alt
                    bestScore = altScore
                }
                if CalendarGridParser.isConfidentCalendar(score: bestScore) { break }
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
