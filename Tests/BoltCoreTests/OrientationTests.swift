import Testing
@testable import BoltCore

struct OrientationTests {
    @Test func everyExifValueRoundTrips() {
        for value in 1...8 {
            #expect(Orientation(exif: value).exifValue == value)
        }
    }

    @Test func rotatingRightWalksThroughTheRotations() {
        var orientation = Orientation(exif: 1)
        var seen: [Int] = []
        for _ in 0..<4 {
            orientation = orientation.applying(.rotateRight)
            seen.append(orientation.exifValue)
        }

        #expect(seen == [6, 3, 8, 1])
    }

    @Test func flipIsItsOwnInverse() {
        for value in 1...8 {
            #expect(Orientation(exif: value).applying(.flipHorizontal).applying(.flipHorizontal).exifValue == value)
        }
    }

    @Test func relativeOrientationMatchesTheTransformThatWasApplied() {
        let transforms: [OrientationTransform] = [.rotateLeft, .rotateRight, .flipHorizontal]
        for value in 1...8 {
            for transform in transforms {
                let from = Orientation(exif: value)
                let to = from.applying(transform)
                #expect(Orientation.relative(from: from, to: to) == Orientation(exif: 1).applying(transform))
            }
        }
    }

    @Test func mirroringAPortraitShotGivesTranspose() {
        #expect(Orientation(exif: 6).applying(.flipHorizontal).exifValue == 5)
    }
}
