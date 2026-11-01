import Foundation

/// 播客节目
struct PodcastShow: Codable, Identifiable, Hashable {
    var feedURL: String
    var title: String
    var author: String = ""
    var artwork: String = ""
    var summary: String = ""
    var lang: String = "fr"
    /// 适合的水平, 如 "A2-B1"
    var level: String = ""
    var id: String { feedURL }
}

/// 单集
struct PodcastEpisode: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var audioURL: String
    var pubDate: Date?
    var duration: Double = 0
    var summary: String = ""
    var artwork: String = ""
    /// RSS 中 podcast:transcript 提供的字幕 (vtt / srt / json)
    var transcriptURL: String?
    var transcriptType: String?

    /// 用于缓存文件名
    var cacheKey: String {
        var h: UInt64 = 1469598103934665603
        for b in (audioURL.isEmpty ? id : audioURL).utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
        return String(h, radix: 36)
    }
}

enum PodcastCatalog {
    /// 默认节目: 以法语生活、学习、交流类为主
    static let defaults: [PodcastShow] = [
        PodcastShow(feedURL: "https://podcast.innerfrench.com/feed.xml", title: "InnerFrench", author: "Hugo Cotton",
                    summary: String(localized: "Society, culture and life in clear, simple French. A favorite of intermediate learners."), level: "B1-B2"),
        PodcastShow(feedURL: "https://onethinginafrenchday.podbean.com/feed.xml", title: "One Thing In A French Day", author: "Laetitia",
                    summary: String(localized: "Short stories of daily life in Paris, with transcripts"), level: "B1"),
        PodcastShow(feedURL: "https://feeds.fireside.fm/easyfrench/rss", title: "Easy French", author: "Easy Languages",
                    summary: String(localized: "Two hosts chat about everyday topics in natural spoken French"), level: "B1-B2"),
        PodcastShow(feedURL: "https://apis.fle.rfi.fr/products/get_product/fle_getpodcast_by_nid_author_rfi?token_application=applepodcast_fle&program.entrepriseId=WBMZ39-FLE-FR-20220627",
                    title: "Journal en français facile", author: "RFI", summary: String(localized: "RFI's daily news in easy French"), level: "A2-B1"),
        PodcastShow(feedURL: "https://apis.fle.rfi.fr/products/get_product/fle_getpodcast_by_nid?token_application=applepodcast_fle&program.entrepriseId=WBMZ25635-FLE-FR-20230628",
                    title: "Parlez-vous Paris ?", author: "RFI", summary: String(localized: "Practical French from everyday Paris situations"), level: "A2-B1"),
        PodcastShow(feedURL: "https://www.spreaker.com/show/6084166/episodes/feed", title: "Little Talk in Slow French",
                    summary: String(localized: "Slow French dialogues for beginners"), level: "A2"),
        PodcastShow(feedURL: "https://anchor.fm/s/e1ba1904/podcast/rss", title: "LanguaTalk Slow French", author: "Gaëlle",
                    summary: String(localized: "Slow, clear French about everyday topics"), level: "A2-B1"),
        PodcastShow(feedURL: "https://francaisauthentique.libsyn.com/rss", title: "Français Authentique", author: "Johan Tekfak",
                    summary: String(localized: "Authentic French expressions and learning tips"), level: "B1-B2"),
        PodcastShow(feedURL: "https://feed.ausha.co/WLa6pfvX6PMw", title: "Le Français Parlé avec Krys",
                    summary: String(localized: "Spoken French from real life"), level: "B2"),
        PodcastShow(feedURL: "https://rss.libsyn.com/shows/105696/destinations/568861.xml", title: "French Blabla",
                    summary: String(localized: "Relaxed talk about French culture and daily life"), level: "B1-B2"),
        PodcastShow(feedURL: "https://feed.ausha.co/Ln46Vf3gQEe0", title: "French Baratin",
                    summary: String(localized: "Real conversations between native speakers"), level: "B2-C1"),
        PodcastShow(feedURL: "https://anchor.fm/s/fb438900/podcast/rss", title: "Duolingo French Podcast", author: "Duolingo",
                    summary: String(localized: "True stories told in French and English"), level: "A2-B1"),
        PodcastShow(feedURL: "https://feeds.acast.com/public/shows/47990e88-454b-4e3b-bf78-75a172c33184", title: "Coffee Break French",
                    summary: String(localized: "Structured French lessons (explained in English)"), level: "A1-B1"),
        PodcastShow(feedURL: "https://anchor.fm/s/10ed62a18/podcast/rss", title: "French Side Stories", author: "LaFrenchAlexia",
                    summary: String(localized: "Everyday stories for intermediate learners"), level: "B1"),
        PodcastShow(feedURL: "https://feeds.acast.com/public/shows/66057de88268a800162cadf2", title: "Choses à Savoir",
                    summary: String(localized: "Short general-knowledge episodes for native speakers"), level: "C1"),
    ] + english

    /// 英语播客: 学习类 + 知名母语节目
    static let english: [PodcastShow] = [
        // 入门
        PodcastShow(feedURL: "https://anchor.fm/s/115855384/podcast/rss", title: "Slow English Daily", summary: String(localized: "Short everyday texts in slow English for beginners"), lang: "en", level: "A1-A2"),
        PodcastShow(feedURL: "https://learningenglish.voanews.com/podcast/?zoneId=1581", title: "VOA American Stories", author: "VOA Learning English",
                    summary: String(localized: "Classic short stories read slowly by VOA"), lang: "en", level: "A2-B1"),
        PodcastShow(feedURL: "https://feeds.megaphone.fm/GLSS2276105381", title: "Easy Stories in English", author: "Ariel Goodbody",
                    summary: String(localized: "English stories graded by difficulty"), lang: "en", level: "A2-B1"),
        // 中级
        PodcastShow(feedURL: "https://podcasts.files.bbci.co.uk/p02pc9tn.rss", title: "6 Minute English", author: "BBC Learning English",
                    summary: String(localized: "BBC: two hosts discuss a topic and its vocabulary in 6 minutes"), lang: "en", level: "B1"),
        PodcastShow(feedURL: "https://podcasts.files.bbci.co.uk/p02pc9zn.rss", title: "Learning English Conversations", author: "BBC Learning English",
                    summary: String(localized: "BBC: everyday conversations and idioms"), lang: "en", level: "B1"),
        PodcastShow(feedURL: "https://rss.libsyn.com/shows/95915/destinations/491662.xml", title: "Speak English Now", author: "Georgiana",
                    summary: String(localized: "Everyday topics in natural English for listening and speaking practice"), lang: "en", level: "B1"),
        PodcastShow(feedURL: "https://rss.libsyn.com/shows/441930/destinations/3695967.xml", title: "Real English Conversations", author: "Curtis Davies",
                    summary: String(localized: "Real-life conversations to improve fluency"), lang: "en", level: "B1-B2"),
        PodcastShow(feedURL: "https://feeds.megaphone.fm/allearsenglish", title: "All Ears English", author: "Lindsay & Michelle",
                    summary: String(localized: "American English and culture; one of the most popular learning podcasts"), lang: "en", level: "B1-B2"),
        PodcastShow(feedURL: "https://feeds.transistor.fm/leonardo-english-english-language-learning-for-curious-minds", title: "English Learning for Curious Minds",
                    author: "Leonardo English", summary: String(localized: "Stories of history, culture and science in clear English"), lang: "en", level: "B2"),
        PodcastShow(feedURL: "https://teacherluke.libsyn.com/rss", title: "Luke's English Podcast", author: "Luke Thompson",
                    summary: String(localized: "British English; long, humorous conversations"), lang: "en", level: "B2-C1"),
        PodcastShow(feedURL: "https://feeds.feedburner.com/Skills360", title: "Business English Skills 360", author: "Business English Pod",
                    summary: String(localized: "Business English skills for the workplace"), lang: "en", level: "B2"),
        // 高级: 母语节目
        PodcastShow(feedURL: "https://feeds.acast.com/public/shows/67587e77c705e441797aff96", title: "TED Talks Daily", author: "TED",
                    summary: String(localized: "A TED talk every day"), lang: "en", level: "C1"),
        PodcastShow(feedURL: "https://feeds.simplecast.com/Sl5CSM3S", title: "The Daily", author: "The New York Times",
                    summary: String(localized: "The New York Times' daily news deep dive"), lang: "en", level: "C1"),
        PodcastShow(feedURL: "https://podcasts.files.bbci.co.uk/p02nq0gn.rss", title: "Global News Podcast", author: "BBC World Service",
                    summary: String(localized: "BBC world news"), lang: "en", level: "C1"),
        PodcastShow(feedURL: "https://feeds.simplecast.com/Y8lFbOT4", title: "Freakonomics Radio", summary: String(localized: "The everyday world through an economist's eyes"), lang: "en", level: "C1"),
        PodcastShow(feedURL: "https://feeds.simplecast.com/kwWc0lhf", title: "Hidden Brain", author: "Shankar Vedantam",
                    summary: String(localized: "The hidden forces behind human behavior"), lang: "en", level: "C1"),
        PodcastShow(feedURL: "https://feeds.npr.org/510289/podcast.xml", title: "Planet Money", author: "NPR", summary: String(localized: "Economics explained in an easy way"), lang: "en", level: "C1"),
        PodcastShow(feedURL: "https://www.omnycontent.com/d/playlist/e73c998e-6e60-432f-8610-ae210140c5b1/a91018a4-ea4f-4130-bf55-ae270180c327/44710ecc-10bb-48d1-93c7-ae270180c33e/podcast.rss",
                    title: "Stuff You Should Know", summary: String(localized: "General-knowledge chats, with transcripts"), lang: "en", level: "C1"),
        PodcastShow(feedURL: "https://feeds.simplecast.com/BqbsxVfO", title: "99% Invisible", author: "Roman Mars",
                    summary: String(localized: "Untold stories behind design and architecture"), lang: "en", level: "C1"),
        PodcastShow(feedURL: "https://www.thisamericanlife.org/podcast/rss.xml", title: "This American Life",
                    summary: String(localized: "True stories of American life; a landmark narrative podcast"), lang: "en", level: "C1-C2"),
        PodcastShow(feedURL: "https://feeds.simplecast.com/EmVW7VGp", title: "Radiolab", author: "WNYC Studios",
                    summary: String(localized: "Sound-rich stories of science and philosophy"), lang: "en", level: "C1-C2"),
    ]

    static var shows: [PodcastShow] {
        get {
            guard let d = UserDefaults.standard.data(forKey: "podcastShows"), var list = try? JSONDecoder().decode([PodcastShow].self, from: d) else { return defaults }
            // 新增的默认节目 (英语播客) 补充到已保存的列表
            if UserDefaults.standard.integer(forKey: "podcastShowsVersion") < 2 {
                for s in defaults where !list.contains(where: { $0.feedURL == s.feedURL }) { list.append(s) }
                UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "podcastShows")
                UserDefaults.standard.set(2, forKey: "podcastShowsVersion")
            }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "podcastShows") }
    }
}

/// RSS 解析
enum PodcastFeed {
    static func fetch(_ show: PodcastShow) async throws -> (PodcastShow, [PodcastEpisode]) {
        guard let url = URL(string: show.feedURL) else { throw ReaderError.network(String(localized: "Invalid feed URL")) }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        req.setValue("VReading/\(AppInfo.version) (iOS) Podcast", forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let root = XNode.parse(data), let channel = root.first("channel") else { throw ReaderError.invalidFile(String(localized: "Couldn't parse the podcast feed")) }
        var s = show
        if let t = channel.child("title")?.fullText, !t.isEmpty, show.title.isEmpty { s.title = t }
        if s.artwork.isEmpty {
            s.artwork = channel.children.first { $0.name == "image" && $0.attrs["href"] != nil }?.attrs["href"]
                ?? channel.child("image")?.child("url")?.fullText ?? ""
        }
        if s.author.isEmpty { s.author = channel.child("author")?.fullText ?? "" }
        if s.summary.isEmpty { s.summary = String((channel.child("summary") ?? channel.child("description"))?.fullText.strippingHTML.prefix(120) ?? "") }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        var episodes: [PodcastEpisode] = []
        for item in channel.children where item.name == "item" {
            guard let enc = item.child("enclosure"), let audio = enc.attrs["url"], !audio.isEmpty else { continue }
            let title = item.child("title")?.fullText ?? ""
            var ep = PodcastEpisode(id: item.child("guid")?.fullText ?? audio, title: title, audioURL: audio)
            ep.pubDate = (item.child("pubdate")?.fullText).flatMap { df.date(from: $0.trimmingCharacters(in: .whitespaces)) }
            ep.duration = parseDuration(item.child("duration")?.fullText ?? "")
            ep.summary = String((item.child("summary") ?? item.child("description"))?.fullText.strippingHTML.prefix(400) ?? "")
            ep.artwork = item.children.first { $0.name == "image" }?.attrs["href"] ?? ""
            // 字幕: 优先 vtt / srt, 其次 json
            let transcripts = item.children.filter { $0.name == "transcript" && $0.attrs["url"] != nil }
            let pick = transcripts.first { ($0.attrs["type"] ?? "").contains("vtt") }
                ?? transcripts.first { ($0.attrs["type"] ?? "").contains("srt") || ($0.attrs["type"] ?? "").contains("subrip") }
                ?? transcripts.first { ($0.attrs["type"] ?? "").contains("json") }
            ep.transcriptURL = pick?.attrs["url"]
            ep.transcriptType = pick?.attrs["type"]
            episodes.append(ep)
        }
        return (s, episodes)
    }

    static func parseDuration(_ s: String) -> Double {
        let parts = s.split(separator: ":").compactMap { Double($0) }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
