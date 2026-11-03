import Foundation

public enum FontBuildError: Error, Equatable, Sendable {
    case invalidOutline, missingGlyphs([UInt32]), invalidGlyphs([UInt32]), unsupportedInk, invalidMetrics, invalidFont, tooComplex, invalidDrawing, missingMetrics, registration
}

/// Coordinates use an upward Y axis in a 1000-unit em; contours are closed implicitly.
public struct GlyphOutline: Sendable, Equatable {
    public struct Point: Sendable, Equatable {
        public let x: Int; public let y: Int
        public init(_ x: Int, _ y: Int) { self.x=x;self.y=y }
    }
    public let contours: [[Point]]
    public let advanceWidth: Int
    public init(contours: [[Point]], advanceWidth: Int) { self.contours=contours;self.advanceWidth=advanceWidth }
}

public enum FontCoverage {
    public static let required: [UInt32] = ((32...126).map(UInt32.init)+[196,214,220,223,228,246,252,8364]).sorted()
}

public struct FontMetrics: Codable, Sendable, Equatable {
    public let unitsPerEm: Int
    public let ascent: Int
    public let descent: Int
    public let lineGap: Int
    public init(unitsPerEm: Int = 1000, ascent: Int = 850, descent: Int = -250, lineGap: Int = 0) {
        self.unitsPerEm=unitsPerEm;self.ascent=ascent;self.descent=descent;self.lineGap=lineGap
    }
    public func validate() throws {
        guard (16...16384).contains(unitsPerEm), (1...32767).contains(ascent), (-32768...0).contains(descent), (0...32767).contains(lineGap) else { throw FontBuildError.invalidMetrics }
    }
}

/// Measured capture coordinates, persisted alongside the original PKDrawing asset.
public struct GlyphCaptureMetrics: Codable, Sendable, Equatable {
    public var baselineY: Double
    public var emSize: Double
    public var xHeight: Double
    public var capHeight: Double
    public var advanceWidth: Double
    public var leftBearing: Double
    public init(baselineY: Double, emSize: Double, xHeight: Double, capHeight: Double, advanceWidth: Double, leftBearing: Double) {
        self.baselineY=baselineY;self.emSize=emSize;self.xHeight=xHeight;self.capHeight=capHeight;self.advanceWidth=advanceWidth;self.leftBearing=leftBearing
    }
    public func validate() throws {
        guard [baselineY,emSize,xHeight,capHeight,advanceWidth,leftBearing].allSatisfy({ $0.isFinite && abs($0) <= 10000 }), emSize >= 10, xHeight > 0, xHeight <= capHeight, capHeight <= emSize, advanceWidth > 0, advanceWidth/emSize <= 2.4, abs(leftBearing/emSize) <= 0.2 else { throw FontBuildError.invalidMetrics }
    }
}

extension GlyphOutline {
    func validate(space: Bool) throws {
        guard (1...2400).contains(advanceWidth) else { throw FontBuildError.invalidOutline }
        guard contours.count <= 128, contours.reduce(0, { $0+$1.count }) <= 8192 else { throw FontBuildError.tooComplex }
        guard space ? contours.isEmpty : !contours.isEmpty else { throw FontBuildError.invalidOutline }
        for contour in contours {
            guard contour.count >= 3, contour.allSatisfy({ (-200...2200).contains($0.x) && (-250...850).contains($0.y) }) else { throw FontBuildError.invalidOutline }
            let area=zip(contour,contour.dropFirst()+[contour[0]]).reduce(0) { $0+$1.0.x*$1.1.y-$1.1.x*$1.0.y }
            guard area != 0 else { throw FontBuildError.invalidOutline }
        }
    }
    var bounds: [Int] {
        let points=contours.flatMap { $0 }
        return [points.map(\.x).min() ?? 0,points.map(\.y).min() ?? 0,points.map(\.x).max() ?? 0,points.map(\.y).max() ?? 0]
    }
}

extension GlyphOutline {
    public func validateForFont() throws { try validate(space:false) }
}
