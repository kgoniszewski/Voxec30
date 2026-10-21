import MediaPlayer
import MusicKit

struct MusicControlTool: AssistantTool {
    let name = "music_control"
    let description = "Steruje odtwarzaniem w aplikacji Muzyka: włącz, pauza, następny/poprzedni utwór, losowo, co teraz gra."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "action": JSONSchema.enumeration(["play", "pause", "next", "previous", "shuffle_on", "shuffle_off", "now_playing"], "Akcja"),
        ], required: ["action"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let player = MPMusicPlayerController.systemMusicPlayer
        switch try input.requiredString("action") {
        case "play": player.play(); return .ok("Wznowiono odtwarzanie.")
        case "pause": player.pause(); return .ok("Zatrzymano muzykę.")
        case "next": player.skipToNextItem(); return .ok("Następny utwór.")
        case "previous": player.skipToPreviousItem(); return .ok("Poprzedni utwór.")
        case "shuffle_on": player.shuffleMode = .songs; return .ok("Odtwarzanie losowe włączone.")
        case "shuffle_off": player.shuffleMode = .off; return .ok("Odtwarzanie losowe wyłączone.")
        default:
            guard let item = player.nowPlayingItem else { return .ok("Nic teraz nie gra.") }
            return .ok("Teraz gra: \(item.title ?? "?") – \(item.artist ?? "?").")
        }
    }
}

struct PlayMusicTool: AssistantTool {
    let name = "music_play"
    let description = "Wyszukuje i włącza muzykę: wykonawcę, utwór, album albo playlistę. Najpierw szuka w bibliotece, potem w katalogu Apple Music."
    var inputSchema: JSONValue {
        JSONSchema.object([
            "query": JSONSchema.string("Czego szukać, np. „Dawid Podsiadło”, „Małomiasteczkowy”"),
            "kind": JSONSchema.enumeration(["artist", "song", "album", "playlist", "any"], "Typ wyszukiwania"),
            "shuffle": JSONSchema.boolean("Odtwarzaj losowo"),
        ], required: ["query"])
    }

    func run(_ input: JSONValue, context: ToolContext) async throws -> ToolOutput {
        let query = try input.requiredString("query")
        let kind = input.optionalString("kind") ?? "any"
        let player = MPMusicPlayerController.systemMusicPlayer

        // 1) Biblioteka na urządzeniu.
        if MPMediaLibrary.authorizationStatus() == .notDetermined {
            _ = await withCheckedContinuation { continuation in MPMediaLibrary.requestAuthorization { continuation.resume(returning: $0) } }
        }
        if MPMediaLibrary.authorizationStatus() == .authorized {
            let property: String = switch kind {
            case "song": MPMediaItemPropertyTitle
            case "album": MPMediaItemPropertyAlbumTitle
            case "playlist": MPMediaPlaylistPropertyName
            default: MPMediaItemPropertyArtist
            }
            let mediaQuery = kind == "playlist" ? MPMediaQuery.playlists() : MPMediaQuery.songs()
            mediaQuery.addFilterPredicate(MPMediaPropertyPredicate(value: query, forProperty: property, comparisonType: .contains))
            if let items = mediaQuery.items, !items.isEmpty {
                player.setQueue(with: MPMediaItemCollection(items: items))
                player.shuffleMode = (input["shuffle"]?.boolValue ?? (kind == "artist")) ? .songs : .off
                player.play()
                return .ok("Gram z biblioteki: \(query) (\(items.count) utworów).")
            }
        }

        // 2) Katalog Apple Music (wymaga subskrypcji i włączonej usługi MusicKit dla App ID).
        guard await MusicAuthorization.request() == .authorized else {
            return .error("Nie znaleziono w bibliotece, a dostęp do Apple Music jest wyłączony.")
        }
        var request = MusicCatalogSearchRequest(term: query, types: [Song.self, Artist.self, Album.self, Playlist.self])
        request.limit = 5
        let response = try await request.response()
        let systemPlayer = SystemMusicPlayer.shared
        switch kind {
        case "album":
            guard let album = response.albums.first else { throw ToolError.notFound("album „\(query)”") }
            systemPlayer.queue = SystemMusicPlayer.Queue(for: [album])
        case "playlist":
            guard let playlist = response.playlists.first else { throw ToolError.notFound("playlista „\(query)”") }
            systemPlayer.queue = SystemMusicPlayer.Queue(for: [playlist])
        case "song":
            guard let song = response.songs.first else { throw ToolError.notFound("utwór „\(query)”") }
            systemPlayer.queue = SystemMusicPlayer.Queue(for: [song])
        default:
            // Wykonawca: kolejka z jego najpopularniejszych utworów.
            let songs = response.songs.filter { song in
                response.artists.first.map { TextNormalizer.normalize(song.artistName).contains(TextNormalizer.normalize($0.name)) } ?? true
            }
            guard !songs.isEmpty else { throw ToolError.notFound("muzyka „\(query)”") }
            systemPlayer.queue = SystemMusicPlayer.Queue(for: songs)
        }
        try await systemPlayer.play()
        return .ok("Gram z Apple Music: \(query).")
    }
}
