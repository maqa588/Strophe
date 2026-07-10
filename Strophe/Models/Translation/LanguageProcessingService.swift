import Foundation
import CoreFoundation
import Combine

enum LanguageProcessingService {
    static func pinyinWithToneMarks(_ text: String) -> String {
        var result = ""
        var hanBuffer = ""

        func flushHan() -> String {
            guard !hanBuffer.isEmpty else { return "" }
            let mutable = NSMutableString(string: hanBuffer)
            CFStringTransform(mutable, nil, kCFStringTransformMandarinLatin, false)
            hanBuffer = ""
            return mutable as String
        }

        for character in text {
            if character.unicodeScalars.contains(where: isHanScalar) {
                hanBuffer.append(character)
            } else {
                let converted = flushHan()
                result = append(converted, to: result)
                result.append(character)
            }
        }
        return append(flushHan(), to: result)
    }

    static func wrappedLines(
        _ text: String,
        maximumLength: Int,
        mode: AutoWrapLanguageMode
    ) -> [String] {
        let limit = max(1, maximumLength)
        return text
            .components(separatedBy: .newlines)
            .flatMap { paragraph in
                switch mode {
                case .words: return wrapWords(paragraph, limit: limit)
                case .continuous: return wrapCharacters(paragraph, limit: limit)
                }
            }
            .filter { !$0.isEmpty }
    }

    private static func wrapWords(_ text: String, limit: Int) -> [String] {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return [] }
        var lines: [String] = []
        var current = ""
        for word in words {
            if current.isEmpty {
                current = word
            } else if current.count + 1 + word.count <= limit {
                current += " \(word)"
            } else {
                lines.append(current)
                current = word
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    private static func wrapCharacters(_ text: String, limit: Int) -> [String] {
        let characters = Array(text)
        guard !characters.isEmpty else { return [] }
        return stride(from: 0, to: characters.count, by: limit).map { start in
            String(characters[start..<min(start + limit, characters.count)])
        }
    }

    private static func append(_ converted: String, to existing: String) -> String {
        guard !converted.isEmpty else { return existing }
        var result = existing
        if let last = result.last,
           let first = converted.first,
           last.isLetter || last.isNumber,
           first.isLetter || first.isNumber {
            result.append(" ")
        }
        result.append(converted)
        return result
    }

    private static func isHanScalar(_ scalar: UnicodeScalar) -> Bool {
        switch scalar.value {
        case 0x3400...0x4DBF,
             0x4E00...0x9FFF,
             0xF900...0xFAFF,
             0x20000...0x2FA1F:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class CommonTranslationPhrasesStore: ObservableObject {
    static let shared = CommonTranslationPhrasesStore()

    @Published private(set) var phrases: [String]
    private let key = "translation.commonPhrases"

    private init() {
        phrases = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ phrase: String) {
        let value = phrase.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !phrases.contains(value) else { return }
        phrases.append(value)
        persist()
    }

    func remove(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) where phrases.indices.contains(index) {
            phrases.remove(at: index)
        }
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(phrases, forKey: key)
    }
}
