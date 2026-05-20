#import "TorrentSessionBridge.h"

// This file is Objective-C++ (`.mm`), so it can talk to both Objective-C/Swift
// and C++ libtorrent. The Swift side sees only the Objective-C methods declared
// in `TorrentSessionBridge.h`.

#include <map>
#include <memory>
#include <string>
#include <vector>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>

namespace lt = libtorrent;

@interface TorrentSessionBridge () {
    // One libtorrent session owns global networking features such as DHT,
    // listening sockets, UPnP/NAT-PMP and all torrent handles.
    std::unique_ptr<lt::session> _session;

    // Map our identifier string to libtorrent torrent_handle.
    std::map<std::string, lt::torrent_handle> _handles;

    // When incomplete files are renamed to `.tmp`, keep original paths here so
    // they can be restored after completion and still shown correctly in Swift UI.
    std::map<std::string, std::vector<std::string>> _originalFilePaths;
}
@end

@implementation TorrentSessionBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        lt::settings_pack settings;
        // Keep alerts modest for now; status is polled by Swift instead of
        // consuming every libtorrent alert type.
        settings.set_int(lt::settings_pack::alert_mask, lt::alert_category::error | lt::alert_category::status);

        // DHT/LSD/UPnP/NAT-PMP improve peer discovery, especially for magnets.
        settings.set_bool(lt::settings_pack::enable_dht, true);
        settings.set_bool(lt::settings_pack::enable_lsd, true);
        settings.set_bool(lt::settings_pack::enable_upnp, true);
        settings.set_bool(lt::settings_pack::enable_natpmp, true);
        settings.set_bool(lt::settings_pack::enable_incoming_tcp, true);
        settings.set_bool(lt::settings_pack::enable_incoming_utp, true);
        // Listen on both IPv4 and IPv6. 6881 is the conventional BT port.
        settings.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
        // Bootstrap nodes help DHT start without relying only on trackers.
        settings.set_str(lt::settings_pack::dht_bootstrap_nodes,
                         "router.bittorrent.com:6881,"
                         "router.utorrent.com:6881,"
                         "dht.transmissionbt.com:6881,"
                         "dht.libtorrent.org:25401,"
                         "dht.aelitis.com:6881");
        _session = std::make_unique<lt::session>(settings);
        // Add the same nodes explicitly to kick-start DHT discovery.
        _session->add_dht_node(std::make_pair(std::string("router.bittorrent.com"), 6881));
        _session->add_dht_node(std::make_pair(std::string("router.utorrent.com"), 6881));
        _session->add_dht_node(std::make_pair(std::string("dht.transmissionbt.com"), 6881));
        _session->add_dht_node(std::make_pair(std::string("dht.libtorrent.org"), 25401));
        _session->add_dht_node(std::make_pair(std::string("dht.aelitis.com"), 6881));
    }
    return self;
}

- (NSString *)startMagnet:(NSString *)magnetURI savePath:(NSString *)savePath error:(NSError **)error {
    if (magnetURI.length == 0 || savePath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"Downloader.Torrent"
                                         code:1
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing magnet URI or save path."}];
        }
        return nil;
    }

    lt::error_code ec;
    // Parse magnet URI into libtorrent add_torrent_params.
    lt::add_torrent_params params = lt::parse_magnet_uri(magnetURI.UTF8String, ec);
    if (ec) {
        if (error) {
            *error = [NSError errorWithDomain:@"Downloader.Torrent"
                                         code:2
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
        }
        return nil;
    }

    params.save_path = savePath.UTF8String;
    // We manage pausing/resuming ourselves, so auto_managed is disabled.
    params.flags &= ~lt::torrent_flags::paused;
    params.flags &= ~lt::torrent_flags::auto_managed;
    // upload_mode allows metadata/peer discovery while avoiding real payload
    // download before the user chooses files.
    params.flags |= lt::torrent_flags::upload_mode;

    // Extra public trackers improve magnet discovery when the magnet has few trackers.
    params.trackers.push_back("udp://tracker.opentrackr.org:1337/announce");
    params.trackers.push_back("udp://open.stealth.si:80/announce");
    params.trackers.push_back("udp://tracker.torrent.eu.org:451/announce");
    params.trackers.push_back("udp://explodie.org:6969/announce");
    params.trackers.push_back("udp://tracker.openbittorrent.com:6969/announce");
    params.trackers.push_back("udp://tracker.internetwarriors.net:1337/announce");
    params.trackers.push_back("udp://tracker.leechers-paradise.org:6969/announce");

    lt::torrent_handle handle = _session->add_torrent(std::move(params), ec);
    if (ec) {
        if (error) {
            *error = [NSError errorWithDomain:@"Downloader.Torrent"
                                         code:3
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
        }
        return nil;
    }

    std::string identifier = magnetURI.UTF8String;
    _handles[identifier] = handle;
    // Force announces immediately instead of waiting for libtorrent's normal schedule.
    handle.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
    handle.force_dht_announce();
    handle.force_lsd_announce();
    return [NSString stringWithUTF8String:identifier.c_str()];
}

- (NSString *)startTorrentFile:(NSString *)torrentFilePath savePath:(NSString *)savePath error:(NSError **)error {
    if (torrentFilePath.length == 0 || savePath.length == 0) {
        if (error) {
            *error = [NSError errorWithDomain:@"Downloader.Torrent"
                                         code:4
                                     userInfo:@{NSLocalizedDescriptionKey: @"Missing torrent file path or save path."}];
        }
        return nil;
    }

    lt::error_code ec;
    auto info = std::make_shared<lt::torrent_info>(torrentFilePath.UTF8String, ec);
    if (ec) {
        if (error) {
            *error = [NSError errorWithDomain:@"Downloader.Torrent"
                                         code:5
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
        }
        return nil;
    }

    lt::add_torrent_params params;
    params.ti = info;
    params.save_path = savePath.UTF8String;
    params.flags &= ~lt::torrent_flags::paused;
    params.flags &= ~lt::torrent_flags::auto_managed;
    // Match magnet behaviour: wait for the user to choose files before payload download.
    params.flags |= lt::torrent_flags::upload_mode;

    lt::torrent_handle handle = _session->add_torrent(std::move(params), ec);
    if (ec) {
        if (error) {
            *error = [NSError errorWithDomain:@"Downloader.Torrent"
                                         code:6
                                     userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithUTF8String:ec.message().c_str()]}];
        }
        return nil;
    }

    std::string identifier = std::string("file://") + torrentFilePath.UTF8String;
    _handles[identifier] = handle;
    handle.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
    handle.force_dht_announce();
    handle.force_lsd_announce();
    return [NSString stringWithUTF8String:identifier.c_str()];
}

- (void)pause:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found != _handles.end() && found->second.is_valid()) {
        // Manual pause avoids auto_managed immediately waking the torrent again.
        found->second.unset_flags(lt::torrent_flags::auto_managed);
        found->second.pause();
    }
}

- (void)resume:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found != _handles.end() && found->second.is_valid()) {
        // After user resumes, clear upload_mode so selected files can download payload.
        found->second.unset_flags(lt::torrent_flags::upload_mode);
        found->second.unset_flags(lt::torrent_flags::auto_managed);
        found->second.resume();
        found->second.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
        found->second.force_dht_announce();
        found->second.force_lsd_announce();
    }
}

- (void)resumeDiscoveryOnly:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found != _handles.end() && found->second.is_valid()) {
        // Keep upload_mode enabled while the app is waiting for file selection.
        found->second.unset_flags(lt::torrent_flags::auto_managed);
        found->second.resume();
        found->second.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
        found->second.force_dht_announce();
        found->second.force_lsd_announce();
    }
}

- (void)remove:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found != _handles.end()) {
        if (found->second.is_valid()) {
            _session->remove_torrent(found->second);
        }
        _handles.erase(found);
    }
}

- (void)reannounce:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found != _handles.end() && found->second.is_valid()) {
        found->second.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
        found->second.force_dht_announce();
        found->second.force_lsd_announce();
    }
}

- (void)moveStorage:(NSString *)identifier savePath:(NSString *)savePath {
    auto found = _handles.find(identifier.UTF8String);
    if (found != _handles.end() && found->second.is_valid() && savePath.length > 0) {
        found->second.move_storage(savePath.UTF8String, lt::move_flags_t::always_replace_files);
    }
}

- (NSArray<NSDictionary<NSString *, id> *> *)filesForIdentifier:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found == _handles.end() || !found->second.is_valid() || !found->second.status().has_metadata) {
        return @[];
    }

    std::shared_ptr<const lt::torrent_info> info = found->second.torrent_file();
    if (!info) {
        return @[];
    }

    NSMutableArray<NSDictionary<NSString *, id> *> *files = [NSMutableArray array];
    lt::file_storage const& storage = info->files();
    auto originals = _originalFilePaths.find(identifier.UTF8String);

    for (int index = 0; index < storage.num_files(); ++index) {
        lt::file_index_t fileIndex(index);
        // If files have been renamed to `.tmp`, still show original names in the UI.
        std::string path = originals != _originalFilePaths.end() && index < originals->second.size()
            ? originals->second[index]
            : storage.file_path(fileIndex);
        std::int64_t size = storage.file_size(fileIndex);
        [files addObject:@{
            @"index": @(index),
            @"path": [NSString stringWithUTF8String:path.c_str()],
            @"size": @((long long)size)
        }];
    }

    return files;
}

- (void)applyTemporaryFileNames:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found == _handles.end() || !found->second.is_valid() || !found->second.status().has_metadata) {
        return;
    }

    std::string key = identifier.UTF8String;
    if (_originalFilePaths.find(key) != _originalFilePaths.end()) {
        return;
    }

    std::shared_ptr<const lt::torrent_info> info = found->second.torrent_file();
    if (!info) {
        return;
    }

    lt::file_storage const& storage = info->files();
    std::vector<std::string> originals;
    originals.reserve(storage.num_files());

    for (int index = 0; index < storage.num_files(); ++index) {
        lt::file_index_t fileIndex(index);
        std::string originalPath = storage.file_path(fileIndex);
        originals.push_back(originalPath);
        // Let Finder show incomplete BT files with a `.tmp` suffix.
        found->second.rename_file(fileIndex, originalPath + ".tmp");
    }

    _originalFilePaths[key] = originals;
}

- (void)restoreOriginalFileNames:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    auto originals = _originalFilePaths.find(identifier.UTF8String);
    if (found == _handles.end() || !found->second.is_valid() || originals == _originalFilePaths.end()) {
        return;
    }

    for (int index = 0; index < originals->second.size(); ++index) {
        found->second.rename_file(lt::file_index_t(index), originals->second[index]);
    }

    _originalFilePaths.erase(originals);
}

- (void)pauseAllFiles:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found == _handles.end() || !found->second.is_valid() || !found->second.status().has_metadata) {
        return;
    }

    std::shared_ptr<const lt::torrent_info> info = found->second.torrent_file();
    if (!info) {
        return;
    }

    lt::file_storage const& storage = info->files();
    std::vector<lt::download_priority_t> priorities;
    priorities.reserve(storage.num_files());

    for (int index = 0; index < storage.num_files(); ++index) {
        // Priority 0 means "do not download this file".
        priorities.push_back(lt::dont_download);
    }

    found->second.prioritize_files(priorities);
}

- (void)setSelectedFileIndexes:(NSIndexSet *)indexes forIdentifier:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found == _handles.end() || !found->second.is_valid() || !found->second.status().has_metadata) {
        return;
    }

    std::shared_ptr<const lt::torrent_info> info = found->second.torrent_file();
    if (!info) {
        return;
    }

    lt::file_storage const& storage = info->files();
    std::vector<lt::download_priority_t> priorities;
    priorities.reserve(storage.num_files());

    for (int index = 0; index < storage.num_files(); ++index) {
        // Selected files get normal priority; unselected files stay at dont_download.
        priorities.push_back([indexes containsIndex:index] ? lt::default_priority : lt::dont_download);
    }

    found->second.prioritize_files(priorities);
    // This is the moment real payload download is allowed to start.
    found->second.unset_flags(lt::torrent_flags::upload_mode);
    found->second.unset_flags(lt::torrent_flags::auto_managed);
    found->second.resume();
    found->second.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
    found->second.force_dht_announce();
    found->second.force_lsd_announce();
}

- (NSDictionary<NSString *, id> *)statusForIdentifier:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found == _handles.end() || !found->second.is_valid()) {
        return @{
            @"valid": @NO,
            @"progress": @0.0,
            @"downloadRate": @0,
            @"downloadPayloadRate": @0,
            @"totalWanted": @0,
            @"totalWantedDone": @0,
            @"isFinished": @NO,
            @"hasMetadata": @NO,
            @"seeds": @0,
            @"peers": @0,
            @"state": @"Invalid"
        };
    }

    lt::torrent_status status = found->second.status();
    NSString *stateName = @"Downloading";
    // Convert libtorrent enum values to readable strings for Swift UI.
    switch (status.state) {
        case lt::torrent_status::checking_files:
        case lt::torrent_status::checking_resume_data:
            stateName = @"Checking";
            break;
        case lt::torrent_status::downloading_metadata:
            stateName = @"Finding metadata";
            break;
        case lt::torrent_status::downloading:
            stateName = @"Downloading";
            break;
        case lt::torrent_status::finished:
            stateName = @"Finished";
            break;
        case lt::torrent_status::seeding:
            stateName = @"Seeding";
            break;
        case lt::torrent_status::unused_enum_for_backwards_compatibility_allocating:
            stateName = @"Allocating";
            break;
        default:
            stateName = @"Starting";
            break;
    }

    return @{
        @"valid": @YES,
        @"progress": @(status.progress),
        // downloadRate includes protocol chatter; downloadPayloadRate is real file payload.
        @"downloadRate": @((long long)status.download_rate),
        @"downloadPayloadRate": @((long long)status.download_payload_rate),
        @"uploadPayloadRate": @((long long)status.upload_payload_rate),
        @"totalPayloadUpload": @((long long)status.total_payload_upload),
        @"totalWanted": @((long long)status.total_wanted),
        @"totalWantedDone": @((long long)status.total_wanted_done),
        @"isFinished": @(status.is_finished),
        @"hasMetadata": @(status.has_metadata),
        @"seeds": @(status.num_seeds),
        @"peers": @(status.num_peers),
        @"connectCandidates": @(status.connect_candidates),
        @"state": stateName,
        @"name": status.name.empty() ? @"" : [NSString stringWithUTF8String:status.name.c_str()]
    };
}

@end
