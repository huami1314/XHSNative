#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <CoreAudio/CoreAudioTypes.h>

static NSURL *copyAsset(NSURL *source, NSString *extension) {
    NSURL *target = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension]];
    NSError *error = nil;
    if (![NSFileManager.defaultManager copyItemAtURL:source toURL:target error:&error]) {
        NSLog(@"copy failed: %@", error);
        return nil;
    }
    return target;
}

static NSURL *temporaryAudio(NSString *extension) {
    return [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:extension]];
}

static NSURL *writeSilence(void) {
    NSURL *file = temporaryAudio(@"wav");
    AudioStreamBasicDescription pcm = {0};
    pcm.mFormatID = kAudioFormatLinearPCM;
    pcm.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    pcm.mSampleRate = 22050;
    pcm.mChannelsPerFrame = 2;
    pcm.mBitsPerChannel = 32;
    pcm.mBytesPerFrame = sizeof(float) * 2;
    pcm.mFramesPerPacket = 1;
    pcm.mBytesPerPacket = pcm.mBytesPerFrame;
    AudioFileID audioFile = NULL;
    OSStatus status = AudioFileCreateWithURL((__bridge CFURLRef)file, kAudioFileWAVEType, &pcm,
                                             kAudioFileFlags_EraseFile, &audioFile);
    if (status != noErr) return nil;
    UInt32 bytes = 22050 * 2 * sizeof(float) * 2;
    float *samples = calloc(22050 * 2 * 2, sizeof(float));
    status = AudioFileWriteBytes(audioFile, false, 0, &bytes, samples);
    free(samples);
    AudioFileClose(audioFile);
    return status == noErr ? file : nil;
}

static NSInteger audioSampleRate(AVAssetTrack *track) {
    CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    const AudioStreamBasicDescription *description =
        format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    return description && description->mSampleRate > 0 ? (NSInteger)description->mSampleRate : 44100;
}

static BOOL hasAudibleAudio(NSURL *file) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
    AVAssetTrack *track = [asset tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!track) return NO;
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    NSDictionary *settings = @{
        AVFormatIDKey: @(kAudioFormatLinearPCM),
        AVLinearPCMIsFloatKey: @YES,
        AVLinearPCMIsNonInterleavedKey: @NO,
        AVLinearPCMBitDepthKey: @32,
    };
    AVAssetReaderTrackOutput *output = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:settings];
    output.alwaysCopiesSampleData = NO;
    if (![reader canAddOutput:output]) return NO;
    [reader addOutput:output];
    if (![reader startReading]) return NO;
    BOOL audible = NO;
    CMFormatDescriptionRef format = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
    const AudioStreamBasicDescription *description = format ? CMAudioFormatDescriptionGetStreamBasicDescription(format) : NULL;
    NSInteger channels = description && description->mChannelsPerFrame > 0 ? description->mChannelsPerFrame : 1;
    NSInteger samples = 0;
    while (!audible && samples < audioSampleRate(track)) {
        CMSampleBufferRef sampleBuffer = [output copyNextSampleBuffer];
        if (!sampleBuffer) break;
        CMBlockBufferRef block = CMSampleBufferGetDataBuffer(sampleBuffer);
        size_t length = block ? CMBlockBufferGetDataLength(block) : 0;
        if (length) {
            float *data = malloc(length);
            if (data && CMBlockBufferCopyDataBytes(block, 0, length, data) == kCMBlockBufferNoErr) {
                NSInteger count = length / sizeof(float);
                for (NSInteger i = 0; i < count; i++) {
                    if (fabsf(data[i]) > 1e-5f) {
                        audible = YES;
                        break;
                    }
                }
                samples += count / channels;
            }
            free(data);
        }
        CFRelease(sampleBuffer);
    }
    [reader cancelReading];
    return audible;
}

static BOOL hasAudioTrack(NSURL *file) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:file options:nil];
    return [asset tracksWithMediaType:AVMediaTypeAudio].count > 0;
}

static NSURL *installAudio(NSURL *videoFile, NSURL *audioFile) {
    AVURLAsset *video = [AVURLAsset URLAssetWithURL:videoFile options:nil];
    AVURLAsset *audio = [AVURLAsset URLAssetWithURL:audioFile options:nil];
    AVAssetTrack *videoTrack = [video tracksWithMediaType:AVMediaTypeVideo].firstObject;
    AVAssetTrack *audioTrack = [audio tracksWithMediaType:AVMediaTypeAudio].firstObject;
    if (!videoTrack || !audioTrack) return nil;

    AVMutableComposition *composition = [AVMutableComposition composition];
    AVMutableCompositionTrack *videoComposition = [composition addMutableTrackWithMediaType:AVMediaTypeVideo preferredTrackID:kCMPersistentTrackID_Invalid];
    AVMutableCompositionTrack *audioComposition = [composition addMutableTrackWithMediaType:AVMediaTypeAudio preferredTrackID:kCMPersistentTrackID_Invalid];
    NSError *error = nil;
    [videoComposition insertTimeRange:CMTimeRangeMake(kCMTimeZero, video.duration) ofTrack:videoTrack atTime:kCMTimeZero error:&error];
    if (error) return nil;
    CMTime audioDuration = CMTimeMinimum(audio.duration, video.duration);
    [audioComposition insertTimeRange:CMTimeRangeMake(kCMTimeZero, audioDuration) ofTrack:audioTrack atTime:kCMTimeZero error:&error];
    if (error) return nil;
    videoComposition.preferredTransform = videoTrack.preferredTransform;

    NSURL *output = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mp4"]];
    AVAssetExportSession *export = [[AVAssetExportSession alloc] initWithAsset:composition presetName:AVAssetExportPresetPassthrough];
    export.outputURL = output;
    export.outputFileType = AVFileTypeMPEG4;
    [export exportAsynchronouslyWithCompletionHandler:^{}];
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (export.status != AVAssetExportSessionStatusCompleted &&
           export.status != AVAssetExportSessionStatusFailed &&
           export.status != AVAssetExportSessionStatusCancelled &&
           deadline.timeIntervalSinceNow > 0) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    }
    return export.status == AVAssetExportSessionStatusCompleted ? output : nil;
}

static void stampVideo(NSURL *source, NSString *assetID, void (^done)(NSURL *file)) {
    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:source options:nil];
    NSURL *output = [[NSURL fileURLWithPath:NSTemporaryDirectory()]
        URLByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingPathExtension:@"mov"]];
    AVAssetReader *reader = [AVAssetReader assetReaderWithAsset:asset error:nil];
    AVAssetWriter *writer = [AVAssetWriter assetWriterWithURL:output fileType:AVFileTypeQuickTimeMovie error:nil];
    if (!reader || !writer) return done(nil);

    AVMutableMetadataItem *identifier = [AVMutableMetadataItem metadataItem];
    identifier.keySpace = AVMetadataKeySpaceQuickTimeMetadata;
    identifier.key = AVMetadataQuickTimeMetadataKeyContentIdentifier;
    identifier.value = assetID;
    identifier.dataType = (__bridge NSString *)kCMMetadataBaseDataType_UTF8;
    writer.metadata = @[identifier];

    NSMutableArray<NSArray *> *pairs = [NSMutableArray array];
    BOOL hasVideo = NO;
    for (AVAssetTrack *track in asset.tracks) {
        if (![track.mediaType isEqualToString:AVMediaTypeVideo] && ![track.mediaType isEqualToString:AVMediaTypeAudio]) continue;
        AVAssetReaderTrackOutput *outputTrack = [AVAssetReaderTrackOutput assetReaderTrackOutputWithTrack:track outputSettings:nil];
        CMFormatDescriptionRef hint = (__bridge CMFormatDescriptionRef)track.formatDescriptions.firstObject;
        AVAssetWriterInput *input = [AVAssetWriterInput assetWriterInputWithMediaType:track.mediaType outputSettings:nil sourceFormatHint:hint];
        input.transform = track.preferredTransform;
        if (![reader canAddOutput:outputTrack] || ![writer canAddInput:input]) continue;
        [reader addOutput:outputTrack];
        [writer addInput:input];
        if ([track.mediaType isEqualToString:AVMediaTypeVideo]) hasVideo = YES;
        [pairs addObject:@[outputTrack, input]];
    }

    NSArray *specification = @[@{(__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_Identifier: @"mdta/com.apple.quicktime.still-image-time",
                                 (__bridge NSString *)kCMMetadataFormatDescriptionMetadataSpecificationKey_DataType: (__bridge NSString *)kCMMetadataBaseDataType_SInt8}];
    CMFormatDescriptionRef format = NULL;
    CMMetadataFormatDescriptionCreateWithMetadataSpecifications(kCFAllocatorDefault, kCMMetadataFormatType_Boxed, (__bridge CFArrayRef)specification, &format);
    AVAssetWriterInput *metadataInput = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeMetadata outputSettings:nil sourceFormatHint:format];
    if (format) CFRelease(format);
    AVAssetWriterInputMetadataAdaptor *adaptor = [AVAssetWriterInputMetadataAdaptor assetWriterInputMetadataAdaptorWithAssetWriterInput:metadataInput];
    if (!hasVideo || ![writer canAddInput:metadataInput]) return done(nil);
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
    dispatch_queue_t queue = dispatch_queue_create("LivePhotoAudioTest", DISPATCH_QUEUE_SERIAL);
    for (NSArray *pair in pairs) {
        AVAssetReaderTrackOutput *outputTrack = pair[0];
        AVAssetWriterInput *input = pair[1];
        __block BOOL finished = NO;
        void (^complete)(void) = ^{
            if (finished) return;
            finished = YES;
            [input markAsFinished];
            dispatch_group_leave(group);
        };
        dispatch_group_enter(group);
        [input requestMediaDataWhenReadyOnQueue:queue usingBlock:^{
            while (input.isReadyForMoreMediaData) {
                CMSampleBufferRef buffer = [outputTrack copyNextSampleBuffer];
                if (!buffer) {
                    complete();
                    return;
                }
                BOOL appended = [input appendSampleBuffer:buffer];
                CFRelease(buffer);
                if (!appended) {
                    complete();
                    return;
                }
            }
        }];
    }
    __block BOOL finished = NO;
    dispatch_group_notify(group, queue, ^{
        if (finished) return;
        finished = YES;
        [writer finishWritingWithCompletionHandler:^{
            [reader cancelReading];
            done(writer.status == AVAssetWriterStatusCompleted ? output : nil);
        }];
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:20];
    while (!finished && deadline.timeIntervalSinceNow > 0)
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) {
            fprintf(stderr, "usage: %s video-only audible-audio\n", argv[0]);
            return 2;
        }
        NSURL *videoOnly = copyAsset([NSURL fileURLWithPath:@(argv[1])], @"mp4");
        NSURL *audio = copyAsset([NSURL fileURLWithPath:@(argv[2])], @"m4a");
        NSURL *silence = writeSilence();
        assert(videoOnly && audio && silence);
        NSURL *silentVideo = installAudio(videoOnly, silence);
        assert(silentVideo);
        assert(hasAudioTrack(silentVideo));
        assert(!hasAudibleAudio(silentVideo));
        assert(hasAudibleAudio(audio));

        NSURL *muxed = installAudio(silentVideo, audio);
        assert(muxed && hasAudioTrack(muxed) && hasAudibleAudio(muxed));
        puts("mux audibility passed");

        __block NSURL *output = nil;
        NSURL *audibleVideo = installAudio(videoOnly, audio);
        assert(audibleVideo && hasAudibleAudio(audibleVideo));
        stampVideo(audibleVideo, [NSUUID.UUID.UUIDString copy], ^(NSURL *file) { output = file; });
        assert(output);
        assert(hasAudibleAudio(output));
        AVURLAsset *result = [AVURLAsset URLAssetWithURL:output options:nil];
        assert([[result tracksWithMediaType:AVMediaTypeAudio] count] == 1);
        assert([[result tracksWithMediaType:AVMediaTypeVideo] count] == 1);
        puts("stamp audio preservation passed");
        puts("live photo audio tests passed");
        [[NSFileManager defaultManager] removeItemAtURL:silentVideo error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:videoOnly error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:audio error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:silence error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:muxed error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:audibleVideo error:nil];
        [[NSFileManager defaultManager] removeItemAtURL:output error:nil];
    }
    return 0;
}
