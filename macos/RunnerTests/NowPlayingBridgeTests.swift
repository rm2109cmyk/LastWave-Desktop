import MediaPlayer
import XCTest

@testable import lastwave_desktop

/// Covers the pure payload parsing / info-dictionary mapping. The
/// MPNowPlayingInfoCenter / MPRemoteCommandCenter side effects need a real
/// macOS session and are covered by the manual procedure in
/// docs/macos-now-playing.md.
class NowPlayingBridgeTests: XCTestCase {
  private func args(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var m: [String: Any] = [
      "hasTrack": true, "title": "Song", "artist": "Artist", "album": "Album",
      "artworkUrl": "https://example.com/c.jpg", "state": "playing",
      "positionMs": 10_000, "durationMs": 180_000, "rate": 1.0,
      "canNext": true, "canPrev": true, "canSeek": true,
    ]
    for (k, v) in overrides { m[k] = v }
    return m
  }

  func testParsesFullPayload() {
    let p = NowPlayingPayload(arguments: args())
    XCTAssertEqual(p?.title, "Song")
    XCTAssertEqual(p?.state, .playing)
    XCTAssertEqual(p?.durationMs, 180_000)
    XCTAssertEqual(p?.canSeek, true)
  }

  func testRejectsMalformedPayload() {
    XCTAssertNil(NowPlayingPayload(arguments: nil))
    XCTAssertNil(NowPlayingPayload(arguments: "nope"))
    XCTAssertNil(NowPlayingPayload(arguments: ["title": "x"]))
  }

  func testUnknownStateFallsBackToStopped() {
    XCTAssertEqual(NowPlayingPayload(arguments: args(["state": "weird"]))?.state, .stopped)
  }

  func testInfoDictionaryMetadataAndTiming() {
    let info = NowPlayingPayload(arguments: args())!.infoDictionary(artwork: nil)
    XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Song")
    XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Artist")
    XCTAssertEqual(info[MPMediaItemPropertyAlbumTitle] as? String, "Album")
    XCTAssertEqual(info[MPMediaItemPropertyPlaybackDuration] as? Double, 180)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 10)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1.0)
    XCTAssertNil(info[MPMediaItemPropertyArtwork])
  }

  func testMissingMetadataAndUnknownDurationAreOmitted() {
    let info = NowPlayingPayload(
      arguments: args(["title": "", "artist": "", "album": "", "durationMs": 0])
    )!.infoDictionary(artwork: nil)
    XCTAssertNil(info[MPMediaItemPropertyTitle])
    XCTAssertNil(info[MPMediaItemPropertyArtist])
    XCTAssertNil(info[MPMediaItemPropertyAlbumTitle])
    XCTAssertNil(info[MPMediaItemPropertyPlaybackDuration])
  }

  func testElapsedIsClampedToDuration() {
    let info = NowPlayingPayload(arguments: args(["positionMs": 999_000]))!
      .infoDictionary(artwork: nil)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 180)
  }

  func testPausedAndBufferingFreezeTimeline() {
    let info = NowPlayingPayload(arguments: args(["state": "paused", "rate": 0.0]))!
      .infoDictionary(artwork: nil)
    XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
  }

  func testNoTrackProducesEmptyInfo() {
    let info = NowPlayingPayload(arguments: args(["hasTrack": false]))!
      .infoDictionary(artwork: nil)
    XCTAssertTrue(info.isEmpty)
  }
}
