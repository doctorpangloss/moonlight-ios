//
//  VideoDecoderRenderer.h
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

@import AVFoundation;
@import Darwin.Mach.mach_time;
@import os.log;
@import os.signpost;
@import VideoToolbox;
@import Accelerate.vImage;

#import "ConnectionCallbacks.h"
#import "StreamView.h"
#import "EnqueuedSampleBuffer.h"
#import "EnqueuedImageBuffer.h"
#include "Limelight.h"

typedef enum {
    kNoPresentationTime,
    kRtpPresentationTime,
    kTimestampPresentationTime,
    kMachTime
} PresentationTimeType;

typedef enum {
    kLinkedAVSampleBufferDisplayLayer,
    kDispatchedAVSampleBufferDisplayLayer,
    kLinkedVTDecoderSessionWithAccelerateFramework,
    kLinkedVTDecoderSessionWithCPUDrawing,
} RenderingStrategy;

static vImage_CGImageFormat vImageFormatARGB8888 = (vImage_CGImageFormat) {
        .bitsPerComponent = 8,
        .bitsPerPixel = 32,
        .colorSpace = NULL,
        .bitmapInfo = kCGImageAlphaFirst | kCGBitmapByteOrderDefault,
        .version = 0,
        .decode = NULL,
        .renderingIntent = kCGRenderingIntentDefault,
};

static void VTDecoderCallback(void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef imageBuffer, CMTime presentationTimestamp, CMTime presentationDuration);

@interface VideoDecoderRenderer : NSObject

- (id)initWithView:(UIView *)view callbacks:(id <ConnectionCallbacks>)callbacks;

- (void)setupWithVideoFormat:(int)videoFormat refreshRate:(int)refreshRate;

- (void)cleanup;

- (void)updateBufferForRange:(CMBlockBufferRef)existingBuffer data:(unsigned char *)data offset:(int)offset length:(int)nalLength;

- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType frameType:(int)frameType pts:(unsigned int)pts;
@end
