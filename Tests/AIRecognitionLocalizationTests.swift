import Foundation

@main
struct AIRecognitionLocalizationTests {
    static func main() throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let locales = ["en", "zh-Hans", "zh-Hant", "ja", "ko", "ar"]
        let requiredKeys = [
            "local_recognition",
            "local_recognition_detail",
            "cloud_connection_success_format",
            "status_checking_device_compatibility",
            "status_preparing_cloud_recognition",
            "status_cloud_recognizing",
            "status_cloud_results_received",
            "status_generation_failed_format",
            "status_recovering_parakeet_gaps_format",
        ]

        for locale in locales {
            let url = root
                .appendingPathComponent("Strophe/App")
                .appendingPathComponent("\(locale).lproj")
                .appendingPathComponent("Localizable.strings")
            let data = try Data(contentsOf: url)
            guard let strings = try PropertyListSerialization.propertyList(
                from: data,
                format: nil
            ) as? [String: String] else {
                fail("could not parse \(url.path)")
            }

            for key in requiredKeys {
                expect(
                    strings[key]?.isEmpty == false,
                    "\(locale) is missing \(key)"
                )
            }

            testFormats(strings: strings, locale: locale)
        }

        print("AIRecognitionLocalizationTests: 6/6 locales passed")
    }

    private static func testFormats(strings: [String: String], locale: String) {
        let stringKeys = [
            "cloud_connection_success_format",
            "status_generation_failed_format",
            "status_downloading_asr_model_format",
            "status_downloading_coreml_asr_format",
            "status_downloading_aligner_format",
            "error_named_model_download_failed_format",
            "status_downloading_speaker_model_format",
            "error_unknown_aligner_format",
            "cloud_response_detail_format",
            "cloud_route_unconfirmed_format",
            "error_cloud_status_format",
        ]
        for key in stringKeys {
            format(strings, locale: locale, key: key, arguments: ["Sample"])
        }

        let integerKeys = [
            "status_local_generation_complete_format",
            "status_cloud_generation_complete_format",
        ]
        for key in integerKeys {
            format(strings, locale: locale, key: key, arguments: [12])
        }

        format(
            strings,
            locale: locale,
            key: "status_downloading_named_model_format",
            arguments: ["Model", "2.2 MB"]
        )
        format(
            strings,
            locale: locale,
            key: "status_cloud_generation_complete_language_format",
            arguments: [12, "Japanese"]
        )
        format(
            strings,
            locale: locale,
            key: "status_cloud_recognizing_segment_format",
            arguments: [7, 13]
        )
        format(
            strings,
            locale: locale,
            key: "status_recovering_parakeet_gaps_format",
            arguments: [2, 4]
        )
        format(
            strings,
            locale: locale,
            key: "cloud_service_not_ready_format",
            arguments: ["Model", 503, ": detail"]
        )
        format(
            strings,
            locale: locale,
            key: "error_cloud_model_mismatch_format",
            arguments: ["actual", "requested"]
        )
        format(
            strings,
            locale: locale,
            key: "error_cloud_http_status_format",
            arguments: [500, ": detail"]
        )
        format(
            strings,
            locale: locale,
            key: "error_cloud_endpoint_http_format",
            arguments: ["/health", 500, ": detail"]
        )
    }

    private static func format(
        _ strings: [String: String],
        locale: String,
        key: String,
        arguments: [CVarArg]
    ) {
        guard let value = strings[key] else {
            fail("\(locale) is missing format key \(key)")
        }
        let output = String(format: value, arguments: arguments)
        expect(!output.isEmpty, "\(locale) produced empty output for \(key)")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { fail(message) }
    }

    private static func fail(_ message: String) -> Never {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}
