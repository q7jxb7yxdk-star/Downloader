#import "TorrentSessionBridge.h"

#include <map>
#include <memory>
#include <string>
#include <vector>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_status.hpp>

namespace lt = libtorrent;

@interface TorrentSessionBridge () {
    std::unique_ptr<lt::session> _session;
    std::map<std::string, lt::torrent_handle> _handles;
}
@end

@implementation TorrentSessionBridge

- (instancetype)init {
    self = [super init];
    if (self) {
        lt::settings_pack settings;
        settings.set_int(lt::settings_pack::alert_mask, lt::alert_category::error | lt::alert_category::status);
        settings.set_bool(lt::settings_pack::enable_dht, true);
        settings.set_bool(lt::settings_pack::enable_lsd, true);
        settings.set_bool(lt::settings_pack::enable_upnp, true);
        settings.set_bool(lt::settings_pack::enable_natpmp, true);
        settings.set_bool(lt::settings_pack::enable_incoming_tcp, true);
        settings.set_bool(lt::settings_pack::enable_incoming_utp, true);
        settings.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:6881,[::]:6881");
        settings.set_str(lt::settings_pack::dht_bootstrap_nodes,
                         "router.bittorrent.com:6881,"
                         "router.utorrent.com:6881,"
                         "dht.transmissionbt.com:6881,"
                         "dht.libtorrent.org:25401");
        _session = std::make_unique<lt::session>(settings);
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
    params.flags &= ~lt::torrent_flags::paused;
    params.flags |= lt::torrent_flags::auto_managed;

    if (params.trackers.empty()) {
        params.trackers.push_back("udp://tracker.opentrackr.org:1337/announce");
        params.trackers.push_back("udp://open.stealth.si:80/announce");
        params.trackers.push_back("udp://tracker.torrent.eu.org:451/announce");
        params.trackers.push_back("udp://explodie.org:6969/announce");
        params.trackers.push_back("udp://tracker.openbittorrent.com:6969/announce");
    }

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
    return [NSString stringWithUTF8String:identifier.c_str()];
}

- (void)pause:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found != _handles.end() && found->second.is_valid()) {
        found->second.unset_flags(lt::torrent_flags::auto_managed);
        found->second.pause();
    }
}

- (void)resume:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found != _handles.end() && found->second.is_valid()) {
        found->second.set_flags(lt::torrent_flags::auto_managed);
        found->second.resume();
    }
}

- (NSDictionary<NSString *, id> *)statusForIdentifier:(NSString *)identifier {
    auto found = _handles.find(identifier.UTF8String);
    if (found == _handles.end() || !found->second.is_valid()) {
        return @{
            @"valid": @NO,
            @"progress": @0.0,
            @"downloadRate": @0,
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
        @"downloadRate": @((long long)status.download_rate),
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
