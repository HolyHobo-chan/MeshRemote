import Foundation
import CoreGraphics
import UIKit

/// The remote framebuffer bitmap. All mutation happens on a private serial queue,
/// so callers may use it from any thread.
final class KVMFramebuffer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "meshremote.desktop.framebuffer", qos: .userInteractive)
    private var canvas: CGContext?
    private var size: CGSize = .zero

    func resize(_ newSize: CGSize) {
        queue.async { [self] in
            guard newSize.width > 0, newSize.height > 0 else { return }
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            canvas = CGContext(data: nil,
                               width: Int(newSize.width), height: Int(newSize.height),
                               bitsPerComponent: 8, bytesPerRow: 0,
                               space: colorSpace,
                               bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
            size = newSize
            canvas?.setFillColor(CGColor(red: 0.06, green: 0.07, blue: 0.09, alpha: 1))
            canvas?.fill(CGRect(origin: .zero, size: newSize))
        }
    }

    /// Decodes and draws one tile, then invokes `onDrawn` (on the render queue).
    func drawTile(_ imageData: Data, at point: CGPoint, onDrawn: @escaping @Sendable () -> Void) {
        queue.async { [self] in
            guard let canvas,
                  let image = UIImage(data: imageData)?.cgImage else { return }
            // CGContext is bottom-left origin; tile coordinates are top-left.
            let rect = CGRect(x: point.x,
                              y: size.height - point.y - CGFloat(image.height),
                              width: CGFloat(image.width),
                              height: CGFloat(image.height))
            canvas.draw(image, in: rect)
            onDrawn()
        }
    }

    /// Snapshot of the current contents.
    func makeImage() -> CGImage? {
        queue.sync { canvas?.makeImage() }
    }
}
