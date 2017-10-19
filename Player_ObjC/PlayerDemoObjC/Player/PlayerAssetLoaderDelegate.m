//
//  PlayerAssetLoaderDelegate.m
//  HiARSDKComponent
//
//  Created by JT Ma on 13/10/2017.
//  Copyright © 2017 MaJiangtao<majt@hiscene.com>. All rights reserved.
//

#import <MobileCoreServices/MobileCoreServices.h>

#import "PlayerAssetLoaderDelegate.h"
#import "PlayerDataRequest.h"

@interface PlayerAssetLoaderDelegate () <PlayerDataRequestDelegate>

@property (nonatomic, strong) NSString *destDirectory;
@property (nonatomic, strong) NSString *cacheDirectory;

@property (nonatomic, strong) PlayerDataRequest *dataRequest;
@property (nonatomic, strong) NSMutableArray *pendingRequests;

@property (nonatomic, strong) NSString *originScheme;

@end

@implementation PlayerAssetLoaderDelegate

- (instancetype)initWithOriginScheme:(NSString *)scheme cacheDirectory:(NSString *)cacheDirectory destDirectory:(NSString *)destDirectory {
    self = [super init];
    if (self) {
        self.pendingRequests = [NSMutableArray array];
        self.cacheDirectory = cacheDirectory;
        self.destDirectory = destDirectory;
        self.originScheme = scheme;
    }
    return self;
}

- (void)dealloc {
    [self.dataRequest invalidate];
}

#pragma mark - AVAssetResourceLoaderDelegate

- (BOOL)resourceLoader:(AVAssetResourceLoader *)resourceLoader
shouldWaitForLoadingOfRequestedResource:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSLog(@"state: Loading");
    [self.pendingRequests addObject:loadingRequest];
    [self loadingRequest:loadingRequest];
    return YES;
}

- (void)resourceLoader:(AVAssetResourceLoader *)resourceLoader
didCancelLoadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSLog(@"state: Cancel");
    [self.pendingRequests removeObject:loadingRequest];
}

#pragma mark - PlayerDataRequestDelegate

- (void)playerDataRequest:(PlayerDataRequest *)dataRequest
               playerData:(PlayerData *)model
           didReceiveData:(NSData *)data {
    [self internalPendingRequestsWithCachePath:model.cachePath];
}

- (void)playerDataRequest:(PlayerDataRequest *)dataRequest
               playerData:(PlayerData *)data
     didCompleteWithError:(NSError *)error {

    if (error) {
        NSLog(@"didCompleteWithError: %@", error.description);
    } else {
        NSLog(@"didComplete");
        if (! [self.cacheDirectory isEqualToString:self.destDirectory]) {
            NSString *cachePath = [self.cacheDirectory stringByAppendingPathComponent:data.url.lastPathComponent];
            NSString *destPath = [self.destDirectory stringByAppendingPathComponent:data.url.lastPathComponent];
            BOOL isExist = [NSFileManager.defaultManager fileExistsAtPath:destPath];
            if (isExist) {
                return;
            }
            BOOL isSuccess = [NSFileManager.defaultManager copyItemAtPath:cachePath toPath:destPath error:nil];
            if (isSuccess) {
                NSLog(@"copy success");
            } else {
                NSLog(@"copy fail");
            }
        }
    }
}

#pragma mark - Private

- (void)loadingRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    @synchronized(self) {
        if (self.dataRequest) {
            if (loadingRequest.dataRequest.requestedOffset >= self.dataRequest.requestOffset &&
                loadingRequest.dataRequest.requestedOffset <= self.dataRequest.requestOffset + self.dataRequest.downloadedLength) {
                NSLog(@"数据已经缓存，则直接完成");
                [self internalPendingRequestsWithCachePath:[self.cacheDirectory stringByAppendingPathComponent:loadingRequest.request.URL.lastPathComponent]];
            }
        } else {
            self.dataRequest = [[PlayerDataRequest alloc] initWithCacheDirectory:self.cacheDirectory];
            self.dataRequest.delegate = self;
            
            AVAssetResourceLoadingDataRequest *dataRequest = loadingRequest.dataRequest;
            NSUInteger startOffset = (NSUInteger)dataRequest.requestedOffset;
            if (dataRequest.currentOffset != 0) {
                startOffset = (NSUInteger)dataRequest.currentOffset;
            }
            startOffset = MAX(0, startOffset);
            
            NSURLComponents *actualURLComponents = [[NSURLComponents alloc] initWithURL:loadingRequest.request.URL resolvingAgainstBaseURL:NO];
            actualURLComponents.scheme = self.originScheme;
            NSURL *url = actualURLComponents.URL;
            [self.dataRequest resume:url.absoluteString requestOffset:startOffset];
        }
    }
}

- (void)cancelRequest:(AVAssetResourceLoadingRequest *)loadingRequest {
    NSURLComponents *actualURLComponents = [[NSURLComponents alloc] initWithURL:loadingRequest.request.URL resolvingAgainstBaseURL:NO];
    actualURLComponents.scheme = self.originScheme;
    NSURL *url = actualURLComponents.URL;
    [self.dataRequest cancel:url.absoluteString];
}

- (void)internalPendingRequestsWithCachePath:(NSString *)cachePath {
    NSMutableArray *requestsCompleted = [NSMutableArray array];
    for (AVAssetResourceLoadingRequest *loadingRequest in self.pendingRequests) {
        @autoreleasepool {
            if (!loadingRequest.isFinished && !loadingRequest.isCancelled) {
                [self fillInContentInformation:loadingRequest.contentInformationRequest];
                BOOL didRespondFinished = [self respondWithDataForRequest:loadingRequest cachePath:cachePath];
                if (didRespondFinished) {
                    [requestsCompleted addObject:loadingRequest];
                }
            }
        }        
    }
    if (requestsCompleted.count > 0) {
        NSLog(@"state: Finished");
        
        [self.pendingRequests removeObjectsInArray:[requestsCompleted copy]];
    }
}

- (void)fillInContentInformation:(AVAssetResourceLoadingContentInformationRequest *)contentInformationRequest {
    NSString *cType = self.dataRequest.contentType;
    CFStringRef contentType = UTTypeCreatePreferredIdentifierForTag(kUTTagClassMIMEType, (__bridge CFStringRef)(cType), NULL);
    contentInformationRequest.byteRangeAccessSupported = YES;
    contentInformationRequest.contentType = CFBridgingRelease(contentType);
    contentInformationRequest.contentLength = self.dataRequest.contentLength;
}

- (BOOL)respondWithDataForRequest:(AVAssetResourceLoadingRequest *)loadingRequest cachePath:(NSString *)cachePath {
    NSUInteger cacheLength = self.dataRequest.downloadedLength;
    NSUInteger requestedOffset = (NSUInteger)loadingRequest.dataRequest.requestedOffset;
    if (loadingRequest.dataRequest.currentOffset != 0) {
        requestedOffset = (NSUInteger)loadingRequest.dataRequest.currentOffset;
    }
    NSUInteger canReadLength = cacheLength - (requestedOffset - 0);
    NSUInteger respondLength = MIN(canReadLength, loadingRequest.dataRequest.requestedLength);
    
    NSFileHandle  *handle = [NSFileHandle fileHandleForReadingAtPath:cachePath];
    [handle seekToFileOffset:requestedOffset];
    NSData *tempVideoData = [handle readDataOfLength:respondLength];
    [loadingRequest.dataRequest respondWithData:tempVideoData];
    
    NSUInteger nowendOffset = requestedOffset + canReadLength;
    NSUInteger reqEndOffset = (NSUInteger)loadingRequest.dataRequest.requestedOffset + (NSUInteger)loadingRequest.dataRequest.requestedLength;
    if (nowendOffset >= reqEndOffset) {
        [loadingRequest finishLoading];
        NSLog(@"finishLoading");
        return YES;
    }
    return NO;
}

@end


