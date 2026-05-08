#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TorrentSessionBridge : NSObject
- (nullable NSString *)startMagnet:(NSString *)magnetURI savePath:(NSString *)savePath error:(NSError **)error;
- (void)pause:(NSString *)identifier;
- (void)resume:(NSString *)identifier;
- (NSDictionary<NSString *, id> *)statusForIdentifier:(NSString *)identifier;
@end

NS_ASSUME_NONNULL_END
