import Foundation
public struct PageGeometry: Codable, Sendable, Equatable {
    public var version = 1
    public var width: Double = 720
    public var height: Double = 1000
    public var horizontalMargin: Double = 56
    public var verticalMargin: Double = 64
    public var ruling: Double = 40
    public init() {}
}
public struct PageRect: Codable, Sendable, Equatable {
    public var x: Double; public var y: Double; public var width: Double; public var height: Double
    public init(x: Double, y: Double, width: Double, height: Double) { self.x=x; self.y=y; self.width=width; self.height=height }
    public var isValid: Bool { [x,y,width,height].allSatisfy(\.isFinite) && x >= 0 && y >= 0 && width > 0 && height > 0 && x+width <= 720 && y+height <= 1000 }
}
public struct WritingRegion: Codable, Sendable, Equatable, Identifiable {
    public let id: UUID
    public var frame: PageRect
    public var baselines: [Double]
    public var storedBaselineStep: Double?
    public var label: String?
    public init(id: UUID = UUID(), frame: PageRect = .init(x:56,y:64,width:608,height:872), baselines: [Double] = stride(from:104.0,through:904.0,by:40).map { $0 }, baselineStep: Double? = nil, label: String? = nil) { self.id=id; self.frame=frame; self.baselines=baselines; self.storedBaselineStep=baselineStep;self.label=label }
}

extension WritingRegion {
    public var baselineOrigin: Double? { baselines.first }
    public var baselineStep: Double? {
        if let storedBaselineStep { return storedBaselineStep }
        guard baselines.count > 1 else { return nil }
        let step=baselines[1]-baselines[0]
        return zip(baselines.dropFirst(),baselines).allSatisfy { abs(($0-$1)-step)<0.0001 } ? step : nil
    }
}
