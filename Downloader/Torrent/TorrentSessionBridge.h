#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Objective-C wrapper for the C++ libtorrent session.
///
/// Swift cannot call C++ libtorrent directly from normal Swift files, so this
/// Objective-C++ bridge exposes a small Objective-C API that Swift can import.
@interface TorrentSessionBridge : NSObject
/// Adds a magnet link to libtorrent and returns an identifier used by later calls.
- (nullable NSString *)startMagnet:(NSString *)magnetURI savePath:(NSString *)savePath error:(NSError **)error;
/// Adds a .torrent file to libtorrent and returns an identifier used by later calls.
- (nullable NSString *)startTorrentFile:(NSString *)torrentFilePath savePath:(NSString *)savePath error:(NSError **)error;
/// Pauses a torrent.
- (void)pause:(NSString *)identifier;
/// Resumes a torrent and reannounces it to trackers/DHT/LSD.
- (void)resume:(NSString *)identifier;
/// Resumes metadata/peer discovery without allowing payload download.
- (void)resumeDiscoveryOnly:(NSString *)identifier;
/// Removes a torrent from the libtorrent session.
- (void)remove:(NSString *)identifier;
/// Forces tracker, DHT, and LSD announce.
- (void)reannounce:(NSString *)identifier;
/// Moves libtorrent storage. Kept for future storage migration work.
- (void)moveStorage:(NSString *)identifier savePath:(NSString *)savePath;
/// Renames torrent files to add `.tmp` while incomplete.
- (void)applyTemporaryFileNames:(NSString *)identifier;
/// Restores original torrent file names after completion.
- (void)restoreOriginalFileNames:(NSString *)identifier;
/// Sets all file priorities to dont_download while waiting for user selection.
- (void)pauseAllFiles:(NSString *)identifier;
/// Returns file index, path, and size after metadata is available.
- (NSArray<NSDictionary<NSString *, id> *> *)filesForIdentifier:(NSString *)identifier;
/// Applies selected file priorities and starts real payload download.
- (void)setSelectedFileIndexes:(NSIndexSet *)indexes forIdentifier:(NSString *)identifier;
/// Returns a dictionary snapshot of torrent status, including paused state, for Swift polling.
- (NSDictionary<NSString *, id> *)statusForIdentifier:(NSString *)identifier;
@end

NS_ASSUME_NONNULL_END
