//
// CustomItemIconProcessor.swift
// Proton Pass - Created on 29/09/2026.
// Copyright (c) 2026 Proton Technologies AG
//
// This file is part of Proton Pass.
//
// Proton Pass is free software: you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// Proton Pass is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with Proton Pass. If not, see https://www.gnu.org/licenses/.
//

import CoreGraphics
import Entities
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum CustomItemIconError: Error, Equatable, Sendable {
    /// Not one of `CustomItemIcon.MimeType`
    case type
    /// Input or output exceeds the size limits
    case size
    /// The image could not be decoded or encoded
    case decode
}

public enum CustomItemIconProcessor {
    /// Converts image bytes to a `CustomItemIcon` data URI.
    /// - SVG: kept as vector (original bytes base64-encoded).
    /// - Raster: center-cropped and scaled to `CustomItemIcon.rasterSize`, exported as PNG.
    /// - Throws: `CustomItemIconError` on unaccepted type, oversize input/output or decoding failure.
    public static func process(data: Data, mimeType: String) throws -> String {
        guard let type = CustomItemIcon.MimeType(rawValue: mimeType) else {
            throw CustomItemIconError.type
        }

        guard data.count <= CustomItemIcon.maxInputSize else {
            throw CustomItemIconError.size
        }

        let icon: String
        if type.isRaster {
            icon = try CustomItemIcon.dataUri(mimeType: .png, data: rasterize(data))
        } else {
            // SVGs are stored as-is: fail early if the encoded data URI would be too long
            guard CustomItemIcon.dataUriLength(mimeType: type, byteCount: data.count)
                <= CustomItemIcon.maxLength else {
                throw CustomItemIconError.size
            }
            // Unlike the web client we cannot render SVGs to prove they are images
            guard let svg = String(data: data, encoding: .utf8),
                  svg.range(of: "<svg", options: .caseInsensitive) != nil else {
                throw CustomItemIconError.decode
            }
            icon = CustomItemIcon.dataUri(mimeType: type, data: data)
        }

        guard icon.utf8.count <= CustomItemIcon.maxLength else {
            throw CustomItemIconError.size
        }

        guard CustomItemIcon.isValid(icon) else {
            throw CustomItemIconError.decode
        }

        return icon
    }

    /// MIME type sniffed from the image bytes rather than trusting the declared type
    public static func sniffMimeType(of data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let identifier = CGImageSourceGetType(source) as String?,
              let type = UTType(identifier) else {
            return nil
        }
        return type.preferredMIMEType
    }
}

private extension CustomItemIconProcessor {
    /// Upper bound of the intermediate decoded image so that a small file with huge
    /// dimensions (decompression bomb) is never fully decoded in memory
    static let maxDecodedPixelSize = 4_096

    static func rasterize(_ data: Data) throws -> Data {
        let size = CustomItemIcon.rasterSize

        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let sourceWidth = properties[kCGImagePropertyPixelWidth] as? Int,
              let sourceHeight = properties[kCGImagePropertyPixelHeight] as? Int,
              sourceWidth > 0, sourceHeight > 0 else {
            throw CustomItemIconError.decode
        }

        // Downsample while decoding, keeping enough pixels on the short side to crop a sharp square
        let aspectRatio = Double(max(sourceWidth, sourceHeight)) / Double(min(sourceWidth, sourceHeight))
        let maxPixelSize = min(maxDecodedPixelSize, Int((Double(size * 2) * aspectRatio).rounded(.up)))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              image.width > 0, image.height > 0 else {
            throw CustomItemIconError.decode
        }

        let side = min(image.width, image.height)
        let cropRect = CGRect(x: (image.width - side) / 2,
                              y: (image.height - side) / 2,
                              width: side,
                              height: side)

        guard let cropped = image.cropping(to: cropRect),
              let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil,
                                      width: size,
                                      height: size,
                                      bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw CustomItemIconError.decode
        }

        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: size, height: size))

        guard let output = context.makeImage() else {
            throw CustomItemIconError.decode
        }

        return try pngData(of: output)
    }

    static func pngData(of image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData,
                                                                 UTType.png.identifier as CFString,
                                                                 1,
                                                                 nil) else {
            throw CustomItemIconError.decode
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw CustomItemIconError.decode
        }
        return data as Data
    }
}

public enum CustomItemIconRenderer {
    /// Decodes a raster `CustomItemIcon` for display, downsampled to `maxPixelSize`.
    /// Returns `nil` for invalid icons, SVGs (not supported) and undecodable data.
    public static func image(from icon: String?, maxPixelSize: Int) -> CGImage? {
        guard let decoded = CustomItemIcon.decode(icon),
              decoded.mimeType.isRaster,
              let source = CGImageSourceCreateWithData(decoded.data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            return nil
        }

        // Always go through the thumbnail API so that an oversized image
        // coming from an untrusted shared item is never fully decoded
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
