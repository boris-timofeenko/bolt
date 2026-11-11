import CoreGraphics
import Testing
@testable import BoltCore

struct ViewportTests {
    let image = CGSize(width: 4000, height: 3000)
    let view = CGSize(width: 800, height: 800)

    @Test func fitCentresTheWholeImage() {
        let frame = Viewport().imageFrame(image: image, view: view, backingScale: 2)

        #expect(frame == CGRect(x: 0, y: 100, width: 800, height: 600))
    }

    @Test func fitNeverEnlargesSmallImagesPastOnePointPerPixel() {
        let frame = Viewport().imageFrame(image: CGSize(width: 200, height: 100), view: view, backingScale: 2)

        #expect(frame.size == CGSize(width: 200, height: 100))
    }

    @Test func hundredPercentIsOneImagePixelPerScreenPixel() {
        let frame = Viewport(mode: .ratio(1)).imageFrame(image: image, view: view, backingScale: 2)

        #expect(frame.width == 2000)
    }

    @Test func zoomKeepsThePointUnderTheCursor() {
        var viewport = Viewport()
        let anchor = CGPoint(x: 600, y: 300)
        let before = viewport.imageFrame(image: image, view: view, backingScale: 1)
        let pixelUnderCursor = (anchor.x - before.minX) / before.width

        viewport.zoom(to: 0.5, anchor: anchor, image: image, view: view, backingScale: 1)
        let after = viewport.imageFrame(image: image, view: view, backingScale: 1)

        #expect(abs((anchor.x - after.minX) / after.width - pixelUnderCursor) < 0.0001)
    }

    @Test func panStopsAtTheImageEdge() {
        var viewport = Viewport(mode: .ratio(1))

        viewport.pan(by: CGSize(width: 100_000, height: 0), image: image, view: view, backingScale: 1)

        #expect(viewport.imageFrame(image: image, view: view, backingScale: 1).minX == 0)
    }

    @Test func zoomStepsWalkTheLadder() {
        #expect(Viewport.nextStep(after: 1, zoomingIn: true) == 1.5)
        #expect(Viewport.nextStep(after: 1, zoomingIn: false) == 0.667)
        #expect(Viewport.nextStep(after: 0.3, zoomingIn: true) == 0.333)
        #expect(Viewport.nextStep(after: 32, zoomingIn: true) == 32)
    }
}

struct PrefetchPlanTests {
    @Test func forwardWindowPutsNextThenPreviousFirst() {
        #expect(PrefetchPlan.indices(around: 10, count: 100, direction: 1) == [10, 11, 9, 12, 13, 14, 8])
    }

    @Test func backwardWindowMirrors() {
        #expect(PrefetchPlan.indices(around: 10, count: 100, direction: -1) == [10, 9, 11, 8, 7, 6, 12])
    }

    @Test func windowIsClippedToTheList() {
        #expect(PrefetchPlan.indices(around: 0, count: 3, direction: 1) == [0, 1, 2])
    }
}
