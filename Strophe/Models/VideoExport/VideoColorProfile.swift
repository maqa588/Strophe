import AVFoundation
import CoreImage
import CoreVideo
import Foundation

/// The color encodings supported by the hard-subtitle pipeline.
/// Dolby Vision/HDR10+ dynamic metadata cannot survive a rendered re-encode,
/// but their PQ base layer can still be exported as standards-compliant HDR10.
nonisolated enum VideoColorProfile: Sendable, Equatable {
    case sdr709
    case hdrPQ
    case hdrHLG

    var isHDR: Bool {
        self != .sdr709
    }

    var pixelFormat: OSType {
        isHDR
            ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
            : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    }

    var avVideoColorProperties: [String: Any] {
        [
            AVVideoColorPrimariesKey: isHDR
                ? AVVideoColorPrimaries_ITU_R_2020
                : AVVideoColorPrimaries_ITU_R_709_2,
            AVVideoTransferFunctionKey: avTransferFunction,
            AVVideoYCbCrMatrixKey: isHDR
                ? AVVideoYCbCrMatrix_ITU_R_2020
                : AVVideoYCbCrMatrix_ITU_R_709_2
        ]
    }

    var outputColorSpace: CGColorSpace {
        let name: CFString
        switch self {
        case .sdr709:
            name = CGColorSpace.sRGB
        case .hdrPQ:
            name = CGColorSpace.itur_2100_PQ
        case .hdrHLG:
            name = CGColorSpace.itur_2100_HLG
        }
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }

    var workingColorSpace: CGColorSpace {
        let name = isHDR ? CGColorSpace.extendedLinearITUR_2020 : CGColorSpace.extendedLinearSRGB
        return CGColorSpace(name: name) ?? CGColorSpaceCreateDeviceRGB()
    }

    private var avTransferFunction: String {
        switch self {
        case .sdr709:
            return AVVideoTransferFunction_ITU_R_709_2
        case .hdrPQ:
            return AVVideoTransferFunction_SMPTE_ST_2084_PQ
        case .hdrHLG:
            return AVVideoTransferFunction_ITU_R_2100_HLG
        }
    }

    private var cvTransferFunction: CFString {
        switch self {
        case .sdr709:
            return kCVImageBufferTransferFunction_ITU_R_709_2
        case .hdrPQ:
            return kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
        case .hdrHLG:
            return kCVImageBufferTransferFunction_ITU_R_2100_HLG
        }
    }

    static func detect(in formatDescriptions: [CMFormatDescription]) -> VideoColorProfile {
        for description in formatDescriptions {
            if let transfer = CMFormatDescriptionGetExtension(
                description,
                extensionKey: kCMFormatDescriptionExtension_TransferFunction
            ) as? String,
               let profile = profile(forTransferFunction: transfer as CFString) {
                return profile
            }
        }
        return .sdr709
    }

    static func detect(in pixelBuffer: CVPixelBuffer) -> VideoColorProfile {
        guard let value = CVBufferCopyAttachment(
            pixelBuffer,
            kCVImageBufferTransferFunctionKey,
            nil
        ), let transfer = value as? String else {
            return .sdr709
        }
        return profile(forTransferFunction: transfer as CFString) ?? .sdr709
    }

    /// FFmpeg's stable AVColorTransferCharacteristic numeric values.
    /// 16 is SMPTE ST 2084 (PQ), 18 is ARIB STD-B67 (HLG).
    init(ffmpegTransferRawValue: Int32) {
        switch ffmpegTransferRawValue {
        case 16:
            self = .hdrPQ
        case 18:
            self = .hdrHLG
        default:
            self = .sdr709
        }
    }

    func attachColorMetadata(
        to output: CVPixelBuffer,
        copyingStaticHDRMetadataFrom source: CVPixelBuffer? = nil
    ) {
        let primaries = isHDR
            ? kCVImageBufferColorPrimaries_ITU_R_2020
            : kCVImageBufferColorPrimaries_ITU_R_709_2
        let matrix = isHDR
            ? kCVImageBufferYCbCrMatrix_ITU_R_2020
            : kCVImageBufferYCbCrMatrix_ITU_R_709_2

        CVBufferSetAttachment(output, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey, cvTransferFunction, .shouldPropagate)
        CVBufferSetAttachment(output, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)

        guard isHDR, let source else { return }
        for key in [
            kCVImageBufferMasteringDisplayColorVolumeKey,
            kCVImageBufferContentLightLevelInfoKey,
            kCVImageBufferAmbientViewingEnvironmentKey
        ] {
            if let value = CVBufferCopyAttachment(source, key, nil) {
                CVBufferSetAttachment(output, key, value, .shouldPropagate)
            }
        }
    }

    private static func profile(forTransferFunction value: CFString) -> VideoColorProfile? {
        if value == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ {
            return .hdrPQ
        }
        if value == kCVImageBufferTransferFunction_ITU_R_2100_HLG {
            return .hdrHLG
        }
        return nil
    }
}
