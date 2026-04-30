import Foundation
import YTKBKit

@MainActor
func channelResolverTests() {
    TestHarness.test("Adds /videos for bare @handle") {
        try expectEq(
            ChannelResolver.normaliseChannelURL("https://www.youtube.com/@chris"),
            "https://www.youtube.com/@chris/videos"
        )
    }

    TestHarness.test("Adds /videos for /channel/UC...") {
        try expectEq(
            ChannelResolver.normaliseChannelURL("https://www.youtube.com/channel/UC123"),
            "https://www.youtube.com/channel/UC123/videos"
        )
    }

    TestHarness.test("Leaves explicit tab alone") {
        try expectEq(
            ChannelResolver.normaliseChannelURL("https://www.youtube.com/@chris/videos"),
            "https://www.youtube.com/@chris/videos"
        )
        try expectEq(
            ChannelResolver.normaliseChannelURL("https://www.youtube.com/@chris/shorts"),
            "https://www.youtube.com/@chris/shorts"
        )
    }

    TestHarness.test("Strips trailing slash before adding") {
        try expectEq(
            ChannelResolver.normaliseChannelURL("https://www.youtube.com/@chris/"),
            "https://www.youtube.com/@chris/videos"
        )
    }

    TestHarness.test("Leaves non-channel URLs alone") {
        try expectEq(
            ChannelResolver.normaliseChannelURL("https://www.youtube.com/watch?v=ABC123"),
            "https://www.youtube.com/watch?v=ABC123"
        )
        try expectEq(
            ChannelResolver.normaliseChannelURL("https://www.youtube.com/playlist?list=PL123"),
            "https://www.youtube.com/playlist?list=PL123"
        )
    }
}
