import SwiftUI
import UniformTypeIdentifiers
import VoiceEnhancerCore

/// Hands an already-written export file to `fileExporter`.
struct AudioFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.audio] }
    static var writableContentTypes: [UTType] { [.mpeg4Audio, .wav] }

    let url: URL

    init(url: URL) {
        self.url = url
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.featureUnsupported)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        try FileWrapper(url: url, options: .immediate)
    }
}

extension ExportFormat {
    var contentType: UTType {
        switch self {
        case .m4a: return .mpeg4Audio
        case .wav: return .wav
        }
    }
}
