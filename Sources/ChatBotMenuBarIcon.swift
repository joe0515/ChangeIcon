import SwiftUI

struct ChatBotMenuBarIcon: View {
    var body: some View {
        Canvas { context, size in
            let white = Color.white
            
            var outerFrame1 = Path()
            outerFrame1.addRoundedRect(in: CGRect(x: 0.5, y: 0.5, width: 15, height: 15),
                cornerSize: .init(width: 3.0, height: 3.0))
            context.stroke(outerFrame1, with: .color(white), lineWidth: 0.25)
            
            var outerFrame2 = Path()
            outerFrame2.addRoundedRect(in: CGRect(x: 1.2, y: 1.2, width: 13.6, height: 13.6),
                cornerSize: .init(width: 2.3, height: 2.3))
            context.stroke(outerFrame2, with: .color(white), lineWidth: 0.25)
            
            var leftBubble = Path()
            leftBubble.addRoundedRect(in: CGRect(x: 1.2, y: 4.0, width: 6.4, height: 6.6),
                cornerSize: .init(width: 0.4, height: 0.4))
            leftBubble.move(to: .init(x: 3.4, y: 10.6))
            leftBubble.addLine(to: .init(x: 2.6, y: 11.4))
            leftBubble.addLine(to: .init(x: 3.0, y: 10.6))
            context.stroke(leftBubble, with: .color(white), lineWidth: 0.28)
            
            let dotPositions: [(CGFloat, CGFloat)] = [
                (2.4, 5.0), (3.6, 5.0), (4.8, 5.0),
                (2.4, 6.6), (3.6, 6.6), (4.8, 6.6),
                (2.4, 8.2), (3.6, 8.2), (4.8, 8.2)
            ]
            dotPositions.forEach { x, y in
                var dot = Path()
                dot.addEllipse(in: CGRect(x: x-0.3, y: y-0.3, width: 0.6, height: 0.6))
                context.stroke(dot, with: .color(white), lineWidth: 0.18)
            }
            
            var rightBubbleOuter = Path()
            rightBubbleOuter.addRoundedRect(in: CGRect(x: 8.4, y: 4.0, width: 6.4, height: 6.6),
                cornerSize: .init(width: 0.4, height: 0.4))
            rightBubbleOuter.move(to: .init(x: 10.6, y: 10.6))
            rightBubbleOuter.addLine(to: .init(x: 9.8, y: 11.4))
            rightBubbleOuter.addLine(to: .init(x: 10.2, y: 10.6))
            context.stroke(rightBubbleOuter, with: .color(white), lineWidth: 0.28)
            
            var rightBubbleMiddle = Path()
            rightBubbleMiddle.addRoundedRect(in: CGRect(x: 10.0, y: 4.8, width: 3.6, height: 3.6),
                cornerSize: .init(width: 0.8, height: 0.8))
            context.stroke(rightBubbleMiddle, with: .color(white), lineWidth: 0.18)
            
            var rightBubbleInner = Path()
            rightBubbleInner.addRoundedRect(in: CGRect(x: 10.8, y: 5.6, width: 2.0, height: 2.0),
                cornerSize: .init(width: 0.4, height: 0.4))
            context.stroke(rightBubbleInner, with: .color(white), lineWidth: 0.18)
            
            var bottomLine = Path()
            bottomLine.move(to: .init(x: 5.4, y: 11.4))
            bottomLine.addQuadCurve(to: .init(x: 8.6, y: 11.4), control: .init(x: 7.0, y: 13.0))
            bottomLine.addQuadCurve(to: .init(x: 11.8, y: 11.4), control: .init(x: 10.2, y: 13.0))
            context.stroke(bottomLine, with: .color(white), lineWidth: 0.28)
            
            var centerDot = Path()
            centerDot.addEllipse(in: CGRect(x: 7.7, y: 11.3, width: 0.2, height: 0.2))
            context.stroke(centerDot, with: .color(white), lineWidth: 0.18)
        }
        .frame(width: 16, height: 16)
        .background(Color.clear)
    }
    
    @MainActor static var nsImage: NSImage {
        let renderer = ImageRenderer(content: ChatBotMenuBarIcon())
        renderer.scale = NSScreen.screens.first?.backingScaleFactor ?? 2.0
        return renderer.nsImage ?? NSImage()
    }
}
