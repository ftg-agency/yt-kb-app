import Foundation
import YTKBKit

@MainActor
func rssFetcherTests() {
    TestHarness.test("RSS parser extracts видео из Atom feed") {
        guard let url = TestFixtures.url("sample-feed", ext: "xml") else {
            throw ExpectError(message: "fixture sample-feed.xml не найден", file: "RSSFetcherTests", line: 0)
        }
        let data = try Data(contentsOf: url)
        let parser = YTRSSParser()
        let videos = try parser.parse(data: data)
        try expectEq(videos.count, 2)
        try expectEq(videos[0].videoId, "abcdefghijk")
        try expectEq(videos[0].title, "Первое видео в feed")
        try expectEq(videos[1].videoId, "lmnopqrstuv")
        try expectEq(videos[1].title, "Второе видео — short")
    }

    TestHarness.test("RSS parser возвращает пустой массив на feed без entry") {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
            <title>Empty</title>
        </feed>
        """
        let parser = YTRSSParser()
        let videos = try parser.parse(data: Data(xml.utf8))
        try expectEq(videos.count, 0)
    }

    TestHarness.test("RSS parser игнорирует entry с невалидным videoId") {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns="http://www.w3.org/2005/Atom">
            <entry>
                <yt:videoId>short_id</yt:videoId>
                <title>Bad id</title>
            </entry>
            <entry>
                <yt:videoId>aaaaaaaaaaa</yt:videoId>
                <title>Good</title>
            </entry>
        </feed>
        """
        let parser = YTRSSParser()
        let videos = try parser.parse(data: Data(xml.utf8))
        try expectEq(videos.count, 1)
        try expectEq(videos[0].videoId, "aaaaaaaaaaa")
    }

    TestHarness.test("RSS parser кидает parse на кривом XML") {
        let bad = Data("<not actually xml>".utf8)
        let parser = YTRSSParser()
        do {
            _ = try parser.parse(data: bad)
            throw ExpectError(message: "ожидали что бросит, но не бросило", file: "RSSFetcherTests", line: 0)
        } catch is RSSFetchError {
            // expected
        }
    }
}
