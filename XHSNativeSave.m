//
//  XHSNative
//
//  Copyright (c) 2026 huami. All rights reserved.
//  Channel: @huamidev
//  Created on: 2026/11/26
//
#import "XHSNativeSave.h"
#import <AVFoundation/AVFoundation.h>
#import <ImageIO/ImageIO.h>
#import <Photos/Photos.h>
#import <objc/message.h>
#import <objc/runtime.h>

static id field(id object, NSString *key) {
    if (!object) return nil;
    @try { return [object valueForKey:key]; } @catch (NSException *exception) { return nil; }
}

static NSString *string(id value) {
    if ([value isKindOfClass:NSURL.class]) return [value absoluteString];
    return [value isKindOfClass:NSString.class] && [value length] ? value : nil;
}

#pragma mark - 评论

static NSHashTable *comments(void) {
    static NSHashTable *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ table = [NSHashTable weakObjectsHashTable]; });
    return table;
}

static id findComment(NSString *commentId) {
    if (!commentId.length) return nil;
    for (id comment in comments().allObjects)
        if ([string(field(comment, @"commentId")) isEqualToString:commentId]) return comment;
    return nil;
}

#pragma mark - 视频地址

// video_info 是原始视频信息的 JSON，里面按编码分了几路流。挑分辨率最高的，一样高再挑码率高的
static void collectStreams(id node, NSMutableArray<NSDictionary *> *found) {
    if ([node isKindOfClass:NSArray.class]) {
        for (id child in node) collectStreams(child, found);
        return;
    }
    if (![node isKindOfClass:NSDictionary.class]) return;
    NSDictionary *dict = node;
    NSString *url = string(dict[@"master_url"]) ?: string(dict[@"url"]);
    if (!url) {
        NSArray *backups = dict[@"backup_urls"];
        if ([backups isKindOfClass:NSArray.class]) url = string(backups.firstObject);
    }
    if ([url hasPrefix:@"http"]) {
        double pixels = [dict[@"width"] doubleValue] * [dict[@"height"] doubleValue];
        double bitrate = MAX([dict[@"avg_bitrate"] doubleValue], [dict[@"video_bitrate"] doubleValue]);
        [found addObject:@{@"url": url, @"score": @(pixels * 1e4 + bitrate)}];
    }
    for (id child in dict.allValues) collectStreams(child, found);
}

static NSString *bestVideoURL(id info) {
    id json = info;
    if ([info isKindOfClass:NSString.class])
        json = [NSJSONSerialization JSONObjectWithData:[info dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    NSMutableArray<NSDictionary *> *found = [NSMutableArray array];
    collectStreams(json, found);
    NSDictionary *best = nil;
    for (NSDictionary *stream in found)
        if (!best || [stream[@"score"] doubleValue] > [best[@"score"] doubleValue]) best = stream;
    return best[@"url"];
}

#pragma mark - 保存

// 小红书私信模块的媒体保存，自带下载进度和结果提示。它是异步的，保存期间留着
static id mediaHandler(void) {
    static NSMutableArray *alive;
    if (!alive) alive = [NSMutableArray array];
    Class handlerClass = objc_getClass("XYMessageUIKit.MediaMessageHandler");
    id handler = [handlerClass new];
    if (!handler) return nil;
    [alive addObject:handler];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(180 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [alive removeObject:handler]; });
    return handler;
}

static void saveImageData(NSData *data, void (^completion)(BOOL)) {
    void (^finish)(BOOL) = ^(BOOL success) { dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(success); }); };
    [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
        if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) return finish(NO);
        [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
            [[PHAssetCreationRequest creationRequestForAsset] addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
        } completionHandler:^(BOOL success, NSError *error) { finish(success); }];
    }];
}

// 下载原图数据直接存，不重新编码
static BOOL saveImageURL(NSString *source, void (^completion)(BOOL)) {
    NSURL *link = [NSURL URLWithString:source];
    if (!link) return NO;
    [[NSURLSession.sharedSession dataTaskWithURL:link completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
        if (!data.length || error || code >= 400) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(NO); });
            return;
        }
        saveImageData(data, completion);
    }] resume];
    return YES;
}

#pragma mark - 实况

// 实况是一张图加一段视频，两边写上同一个标识，再成对存进相册：
// 图片写在 MakerApple 的 17 号字段，视频写 content.identifier，另加一条 still-image-time 的元数据轨
static NSURL *temporaryFile(NSString *extension) {
    return [[NSURL fileURLWithPath:NSTemporaryDirectory()] URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension]];
}

static void download(NSString *link, NSString *extension, void (^done)(NSURL *file)) {
    NSURL *url = [NSURL URLWithString:link];
    if (!url) return done(nil);
    [[NSURLSession.sharedSession downloadTaskWithURL:url completionHandler:^(NSURL *location, NSURLResponse *response, NSError *error) {
        NSInteger code = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
        NSURL *file = temporaryFile(extension);
        if (error || code >= 400 || ![NSFileManager.defaultManager moveItemAtURL:location toURL:file error:nil]) file = nil;
        done(file);
    }] resume];
}

static NSURL *stampImage(NSURL *source, NSString *assetID) {
    CGImageSourceRef image = CGImageSourceCreateWithURL((__bridge CFURLRef)source, NULL);
    if (!image) return nil;
    NSURL *output = temporaryFile(@"jpg");
    CGImageDestinationRef destination = CGImageDestinationCreateWithURL((__bridge CFURLRef)output, CFSTR("public.jpeg"), 1, NULL);
    NSMutableDictionary *properties = [(__bridge_transfer NSDictionary *)CGImageSourceCopyPropertiesAtIndex(image, 0, NULL) mutableCopy] ?: [NSMutableDictionary dictionary];
    properties[(__bridge NSString *)kCGImagePropertyMakerAppleDictionary] = @{@"17": assetID};
    properties[(__bridge NSString *)kCGImageDestinationLossyCompressionQuality] = @0.95;
    BOOL written = NO;
    if (destination) {
        CGImageDestinationAddImageFromSource(destination, image, 0, (__bridge CFDictionaryRef)properties);
        written = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    CFRelease(image);
    return written ? output : nil;
}

static void stampVideo(NSURL *source, NSString *assetID, void (^done)(NSURL *file)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
    NSURL *output = temporaryFile(@"mov");
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:output fileType:AVFileTypeQuickTimeMovie error:nil];
    if (!reader || !writer) return done(nil);

    AVMutableMetadataItem *identifier = [AVMutableMetadataItem metadataItem];
    identifier.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    identifier.key = AVMetadataQuickTimeMetadataKeyContentIdentifier;
    identifier.value = assetID;
    identifier.dataType = (__bridge NSString *)kCMMetadataBaseDataType_UTF8;
    writer.metadata = @[identifier];

    // 原样搬运音视频，不重新编码
    NSMutableArray<NSArray *> *pairs = [NSMutableArray array];
    for (AVAssetTrack *track in asset.tracks) {
        if (![track.mediaType isEqualToString:AVMediaTypeVideo] && ![track.mediaType isEqualToString:AVMediaTypeAudio]) continue;
        AVAssetReaderTrackOutput *outputTrack = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
        CMFormatDescriptionRef hint = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:track.mediaType outputSettings:nil sourceFormatHint:hint];
        input.transform = track.preferredTransform;
        if (![reader canAddOutput:outputTrack] || ![writer canAddInput:input]) continue;
        [reader addOutput:outputTrack];
        [writer addInput:input];
        [pairs addObject:@[outputTrack, input]];
    }

    NSArray *specification = @[@{(__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: @"mdta/com.apple.quicktime.still-image-time",
                                 (__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: (__bridge NSString *)kCMMetadataBaseDataType_SInt8}];
    CMFormatDescriptionRef format = NULL;
    CMMetadataFormatDescriptionCreateWithMetadataSpecifications(kCFAllocatorDefault, kCMMetadataFormatType_Boxed, (__bridge CFArrayRef)specification, &format);
    AVAssetWriterInput *metadataInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeMetadata outputSettings:nil sourceFormatHint:format];
    if (format) CFRelease(format);
    AVAssetWriterInputMetadataAdaptor *adaptor = [AVAssetWriterInputMetadataAdaptor assetWriterInputMetadataAdaptorWithAssetWriterInput:metadataInput];
    if (!pairs.count || ![writer canAddInput:metadataInput]) return done(nil);
    [writer addInput:metadataInput];
    if (![writer startWriting] || ![reader startReading]) return done(nil);
    [writer startSessionAtSourceTime:kCMTimeZero];

    AVMutableMetadataItem *still = [AVMutableMetadataItem metadataItem];
    still.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    still.key = @"com.apple.quicktime.still-image-time";
    still.value = @(-1);
    still.dataType = (__bridge NSString *)kCMMetadataBaseDataType_SInt8;
    [adaptor appendTimedMetadataGroup:[[AVTimedMetadataGroup alloc] initWithItems:@[still] timeRange:CMTimeRangeMake(kCMTimeZero, CMTimeMake(1, 100))]];
    [metadataInput markAsFinished];

    dispatch_group_t group = dispatch_group_create();
    dispatch_queue_t queue = dispatch_queue_create("XHSNative.livePhoto", DISPATCH_QUEUE_SERIAL);
    for (NSArray *pair in pairs) {
        AVAssetReaderTrackOutput *outputTrack = pair[0];
        AVAssetWriterInput *input = pair[1];
        dispatch_group_enter(group);
        [input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
            while (input.isReadyForMoreMediaData) {
                CMSampleBufferRef buffer = [outputTrack copyNextSampleBuffer];
                if (!buffer) {
                    [input markAsFinished];
                    dispatch_group_leave(group);
                    return;
                }
                [input appendSampleBuffer:buffer];
                CFRelease(buffer);
            }
        }];
    }
    dispatch_group_notify(group, queue, ^{
        [writer finishWritingWithCompletionHandler:^{
            [reader cancelReading];
            done(writer.status == AVAssetWriterStatusCompleted ? output : nil);
        }];
    });
}

static void saveLivePhoto(NSString *imageLink, NSString *videoLink, void (^completion)(BOOL success)) {
    void (^finish)(BOOL) = ^(BOOL success) { dispatch_async(dispatch_get_main_queue(), ^{ completion(success); }); };
    download(imageLink, @"img", ^(NSURL *imageFile) {
        download(videoLink, @"mp4", ^(NSURL *videoFile) {
            NSString *assetID = NSUUID.UUID.UUIDString;
            NSURL *image = imageFile ? stampImage(imageFile, assetID) : nil;
            if (!image || !videoFile) return finish(NO);
            stampVideo(videoFile, assetID, ^(NSURL *video) {
                if (!video) return finish(NO);
                [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly handler:^(PHAuthorizationStatus status) {
                    if (status != PHAuthorizationStatusAuthorized && status != PHAuthorizationStatusLimited) return finish(NO);
                    [PHPhotoLibrary.sharedPhotoLibrary performChanges:^{
                        PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
                        PHAssetResourceCreationOptions *move = [PHAssetResourceCreationOptions new];
                        move.shouldMoveFile = YES;
                        [request addResourceWithType:PHAssetResourceTypePhoto fileURL:image options:move];
                        [request addResourceWithType:PHAssetResourceTypePairedVideo fileURL:video options:move];
                    } completionHandler:^(BOOL success, NSError *error) { finish(success); }];
                }];
            });
        });
    });
}

#pragma mark - 图集笔记

// 图集是 ImageSlidesView，它的 slidesModel 是 Swift 的属性，只能按实例变量取；
// 模型上的 note、noteId 和图集的 collection、currentIndex 都是 @objc 的
static id call(id object, NSString *name) {
    SEL selector = NSSelectorFromString(name);
    return [object respondsToSelector:selector] ? ((id (*)(id, SEL))objc_msgSend)(object, selector) : nil;
}

static id slidesModel(UIView *slides) {
    Ivar ivar = class_getInstanceVariable(slides.class, "slidesModel");
    return ivar ? object_getIvar(slides, ivar) : nil;
}

static UIView *findSlides(UIView *view, Class slidesClass, NSString *noteId) {
    if ([view isKindOfClass:slidesClass]) {
        // 信息流里前后几篇也预加载着，只认铺在屏幕中间的这一篇
        CGRect frame = [view convertRect:view.bounds toView:nil];
        CGPoint center = CGPointMake(CGRectGetMidX(view.window.bounds), CGRectGetMidY(view.window.bounds));
        if ([string(call(slidesModel(view), @"noteId")) isEqualToString:noteId] && CGRectContainsPoint(frame, center)) return view;
        return nil;
    }
    for (UIView *child in view.subviews) {
        UIView *found = findSlides(child, slidesClass, noteId);
        if (found) return found;
    }
    return nil;
}

static NSArray *slideImages(UIView *slides) {
    NSArray *images = call(call(slidesModel(slides), @"note"), @"imagesList");
    return [images isKindOfClass:NSArray.class] ? images : nil;
}

// 一张图：实况存成实况，静态图存原图
static void saveSlide(id image, void (^completion)(BOOL success)) {
    NSString *cover = string(field(image, @"urlLarge")) ?: string(field(image, @"url"));
    NSString *video = bestVideoURL(field(image, @"livePhotoVideoInfo")) ?: string(field(image, @"livePhotoVideoUrl"));
    if (!cover) return completion(NO);
    if (video) return saveLivePhoto(cover, video, completion);
    if (!saveImageURL(cover, completion)) completion(NO);
}

// 按顺序一张张存，相册里的顺序和笔记一致
static void saveSlides(NSArray *images, NSUInteger index, BOOL allSaved, void (^completion)(BOOL success)) {
    if (index >= images.count) return completion(allSaved);
    saveSlide(images[index], ^(BOOL success) { saveSlides(images, index + 1, allSaved && success, completion); });
}

@implementation XHSNativeSave

+ (void)rememberComment:(id)comment {
    if (comment) [comments() addObject:comment];
}

+ (BOOL)saveCommentVideoWithCommentId:(NSString *)commentId index:(NSInteger)index {
    NSArray *videos = field(findComment(commentId), @"commentVideos");
    if (![videos isKindOfClass:NSArray.class] || index < 0 || index >= (NSInteger)videos.count) return NO;
    NSString *url = bestVideoURL(field(videos[index], @"videoInfo"));
    id handler = url ? mediaHandler() : nil;
    SEL save = NSSelectorFromString(@"saveVidioWithUrl:");
    if (![handler respondsToSelector:save]) return NO;
    ((void (*)(id, SEL, id))objc_msgSend)(handler, save, url);
    return YES;
}

+ (BOOL)saveCommentLivePhotoWithCommentId:(NSString *)commentId videoId:(NSString *)videoId imageURL:(NSString *)imageURL {
    NSArray *images = field(findComment(commentId), @"commentImages");
    if (![images isKindOfClass:NSArray.class]) return NO;
    id item = nil;
    for (id image in images)
        if ([string(field(image, @"livePhotoVideoId")) isEqualToString:videoId]) item = image;
    NSString *video = bestVideoURL(field(item, @"livePhotoMediaInfo"));
    NSString *cover = string(field(item, @"originUrl")) ?: string(field(item, @"url")) ?: imageURL;
    id handler = video && cover ? mediaHandler() : nil;
    SEL save = NSSelectorFromString(@"saveLivePhotoWithImageUrl:videoUrl:");
    if (![handler respondsToSelector:save]) return NO;
    ((void (*)(id, SEL, id, id))objc_msgSend)(handler, save, cover, video);
    return YES;
}

+ (UIView *)slidesOfNote:(NSString *)noteId {
    Class slidesClass = objc_getClass("XYOldNoteModule.ImageSlidesView");
    if (!slidesClass || !noteId.length) return nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            UIView *slides = window.hidden ? nil : findSlides(window, slidesClass, noteId);
            if (slideImages(slides).count) return slides;
        }
    }
    return nil;
}

+ (void)saveSlides:(UIView *)slides all:(BOOL)all completion:(void (^)(BOOL success))completion {
    NSArray *images = slideImages(slides);
    if (all) return saveSlides(images, 0, images.count > 0, completion);
    id collection = call(slides, @"collection");
    SEL current = NSSelectorFromString(@"currentIndex");
    NSInteger index = [collection respondsToSelector:current] ? ((NSInteger (*)(id, SEL))objc_msgSend)(collection, current) : -1;
    if (index < 0 || index >= (NSInteger)images.count) return completion(NO);
    saveSlide(images[index], completion);
}

// 评论图片原本是下载后画上水印再存成静态图。直接存原图数据；评论里这张有动图地址就存动图
+ (BOOL)saveCommentImageWithURL:(NSString *)url completion:(void (^)(BOOL success))completion {
    NSString *source = url;
    for (id comment in comments().allObjects) {
        NSArray *images = field(comment, @"commentImages");
        if (![images isKindOfClass:NSArray.class]) continue;
        for (id image in images) {
            NSString *plain = string(field(image, @"url")), *origin = string(field(image, @"originUrl"));
            if (![url isEqualToString:plain] && ![url isEqualToString:origin]) continue;
            source = string(field(image, @"animationUrl")) ?: origin ?: url;
        }
    }
    return saveImageURL(source, completion);
}

@end
