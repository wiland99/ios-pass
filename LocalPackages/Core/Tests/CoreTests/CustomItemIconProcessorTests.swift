//
// CustomItemIconProcessorTests.swift
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

import Core
import CoreGraphics
import Entities
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

private let svgSource = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1 1"><rect width="1" height="1"/></svg>"#

struct CustomItemIconProcessorTests {
    @Test("Accepted MIME types mirror the web client")
    func acceptedMimeTypes() {
        #expect(CustomItemIcon.MimeType.allCases.map(\.rawValue) ==
            ["image/png", "image/jpeg", "image/webp", "image/svg+xml"])
    }

    @Test("Reject unaccepted MIME type",
          arguments: ["", "image/gif", "image/bmp", "image/heic", "text/html", "application/octet-stream",
                      "image/svg", "IMAGE/PNG"])
    func rejectMimeType(mimeType: String) throws {
        let data = try makeImageData(width: 8, height: 8, type: .png)
        #expect(throws: CustomItemIconError.type) {
            try CustomItemIconProcessor.process(data: data, mimeType: mimeType)
        }
    }

    @Test("Reject input larger than max input size", arguments: CustomItemIcon.MimeType.allCases)
    func rejectInputSize(mimeType: CustomItemIcon.MimeType) {
        let data = Data(repeating: 0, count: CustomItemIcon.maxInputSize + 1)
        #expect(throws: CustomItemIconError.size) {
            try CustomItemIconProcessor.process(data: data, mimeType: mimeType.rawValue)
        }
    }

    @Test("Check MIME type before size")
    func typeBeforeSize() {
        let data = Data(repeating: 0, count: CustomItemIcon.maxInputSize + 1)
        #expect(throws: CustomItemIconError.type) {
            try CustomItemIconProcessor.process(data: data, mimeType: "image/gif")
        }
    }

    @Test("Reject SVG whose data URI would exceed max length before decoding")
    func rejectLargeSvg() {
        // 32 KB of raw bytes encodes to ~43 KB of base64. Not an SVG either,
        // so a `size` error proves the length is checked before the content
        let data = Data(repeating: 0, count: CustomItemIcon.maxLength)
        #expect(throws: CustomItemIconError.size) {
            try CustomItemIconProcessor.process(data: data, mimeType: CustomItemIcon.MimeType.svg.rawValue)
        }
    }

    @Test("Keep SVG as vector data URI")
    func keepSvg() throws {
        let data = Data(svgSource.utf8)
        let icon = try CustomItemIconProcessor.process(data: data, mimeType: CustomItemIcon.MimeType.svg.rawValue)
        #expect(icon == "data:image/svg+xml;base64,\(data.base64EncodedString())")
        #expect(CustomItemIcon.isValid(icon))
    }

    @Test("Reject SVG that is not SVG markup",
          arguments: [Data(), Data("hello".utf8), Data([0xFF, 0xFE, 0x00])])
    func rejectInvalidSvg(data: Data) {
        #expect(throws: CustomItemIconError.decode) {
            try CustomItemIconProcessor.process(data: data, mimeType: CustomItemIcon.MimeType.svg.rawValue)
        }
    }

    @Test("Reject undecodable raster data", arguments: [CustomItemIcon.MimeType.png, .jpeg, .webp])
    func rejectUndecodableRaster(mimeType: CustomItemIcon.MimeType) {
        #expect(throws: CustomItemIconError.decode) {
            try CustomItemIconProcessor.process(data: Data("not an image".utf8), mimeType: mimeType.rawValue)
        }
    }

    @Test("Rasterize to a 64x64 PNG",
          arguments: [(UTType.png, 1, 1), (.png, 300, 100), (.png, 100, 300), (.jpeg, 1_000, 800), (.png, 64, 64)])
    func rasterize(type: UTType, width: Int, height: Int) throws {
        let data = try makeImageData(width: width, height: height, type: type)
        let mimeType = try #require(type.preferredMIMEType)

        let icon = try CustomItemIconProcessor.process(data: data, mimeType: mimeType)

        #expect(icon.hasPrefix("data:image/png;base64,"))
        #expect(icon.count <= CustomItemIcon.maxLength)
        #expect(CustomItemIcon.isValid(icon))
        let output = try decodeImage(icon)
        #expect(output.width == CustomItemIcon.rasterSize)
        #expect(output.height == CustomItemIcon.rasterSize)
    }

    @Test("Stay under max length for images that do not compress")
    func noisyImage() throws {
        var generator = SystemRandomNumberGenerator()
        let data = try makeImageData(width: 512, height: 512, type: .png) { context in
            for x in 0..<128 {
                for y in 0..<128 {
                    context.setFillColor(red: .random(in: 0...1, using: &generator),
                                         green: .random(in: 0...1, using: &generator),
                                         blue: .random(in: 0...1, using: &generator),
                                         alpha: .random(in: 0...1, using: &generator))
                    context.fill(CGRect(x: x * 4, y: y * 4, width: 4, height: 4))
                }
            }
        }
        try #require(data.count <= CustomItemIcon.maxInputSize)

        let icon = try CustomItemIconProcessor.process(data: data, mimeType: "image/png")
        #expect(icon.count <= CustomItemIcon.maxLength)
    }

    @Test("Center-crop landscape and portrait images", arguments: [(300, 100), (100, 300)])
    func centerCrop(width: Int, height: Int) throws {
        // Red square in the middle, blue on both long-side edges
        let data = try makeImageData(width: width, height: height, type: .png) { context in
            context.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            let side = min(width, height)
            context.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
            context.fill(CGRect(x: (width - side) / 2, y: (height - side) / 2, width: side, height: side))
        }

        let icon = try CustomItemIconProcessor.process(data: data, mimeType: "image/png")
        let output = try decodeImage(icon)

        let last = CustomItemIcon.rasterSize - 1
        for (x, y) in [(0, 0), (last, 0), (0, last), (last, last), (last / 2, last / 2)] {
            let pixel = try rgba(of: output, x: x, y: y)
            #expect(pixel.red > 200 && pixel.blue < 50, "Pixel at (\(x), \(y)) should be red: \(pixel)")
        }
    }

    @Test("Sniff MIME type from bytes")
    func sniffMimeType() throws {
        #expect(try CustomItemIconProcessor.sniffMimeType(of: makeImageData(width: 4, height: 4, type: .png)) ==
            "image/png")
        #expect(try CustomItemIconProcessor.sniffMimeType(of: makeImageData(width: 4, height: 4, type: .jpeg)) ==
            "image/jpeg")
        #expect(CustomItemIconProcessor.sniffMimeType(of: Data("not an image".utf8)) == nil)
    }

    @Test("Render valid raster icon")
    func renderRaster() throws {
        let data = try makeImageData(width: 300, height: 100, type: .png)
        let icon = try CustomItemIconProcessor.process(data: data, mimeType: "image/png")

        let image = try #require(CustomItemIconRenderer.image(from: icon, maxPixelSize: 180))
        #expect(image.width == CustomItemIcon.rasterSize)
        #expect(image.height == CustomItemIcon.rasterSize)
    }

    @Test("Downsample oversized icon when rendering")
    func renderDownsampled() throws {
        let data = try makeImageData(width: 200, height: 200, type: .png)
        let icon = CustomItemIcon.dataUri(mimeType: .png, data: data)
        try #require(CustomItemIcon.isValid(icon))

        let image = try #require(CustomItemIconRenderer.image(from: icon, maxPixelSize: 50))
        #expect(max(image.width, image.height) <= 50)
    }

    @Test("Do not render SVG, invalid or undecodable icons", arguments: [
        nil,
        "",
        "https://tracker.example.com/pixel.png",
        "data:image/svg+xml;base64,\(Data(svgSource.utf8).base64EncodedString())",
        "data:image/png;base64,QUJD",
        "data:image/png;base64,QUJD<script>"
    ])
    func doNotRender(icon: String?) {
        #expect(CustomItemIconRenderer.image(from: icon, maxPixelSize: 180) == nil)
    }
}

// MARK: - Helpers

private struct RGBA: CustomStringConvertible {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let alpha: UInt8

    var description: String {
        "rgba(\(red), \(green), \(blue), \(alpha))"
    }
}

private func makeImageData(width: Int,
                           height: Int,
                           type: UTType,
                           draw: ((CGContext) -> Void)? = nil) throws -> Data {
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let context = try #require(CGContext(data: nil,
                                         width: width,
                                         height: height,
                                         bitsPerComponent: 8,
                                         bytesPerRow: 0,
                                         space: colorSpace,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    if let draw {
        draw(context)
    } else {
        context.setFillColor(red: 0, green: 1, blue: 0, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let image = try #require(context.makeImage())

    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData,
                                                                    type.identifier as CFString,
                                                                    1,
                                                                    nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return data as Data
}

private func decodeImage(_ icon: String) throws -> CGImage {
    let decoded = try #require(CustomItemIcon.decode(icon))
    let source = try #require(CGImageSourceCreateWithData(decoded.data as CFData, nil))
    return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
}

/// Reads a pixel by redrawing the image into a known RGBA buffer (top-left origin)
private func rgba(of image: CGImage, x: Int, y: Int) throws -> RGBA {
    let width = image.width
    let height = image.height
    var buffer = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    try buffer.withUnsafeMutableBytes { pointer in
        let context = try #require(CGContext(data: pointer.baseAddress,
                                             width: width,
                                             height: height,
                                             bitsPerComponent: 8,
                                             bytesPerRow: width * 4,
                                             space: colorSpace,
                                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    }
    let offset = (y * width + x) * 4
    return RGBA(red: buffer[offset],
                green: buffer[offset + 1],
                blue: buffer[offset + 2],
                alpha: buffer[offset + 3])
}
