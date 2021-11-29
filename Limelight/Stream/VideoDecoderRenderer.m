//
//  VideoDecoderRenderer.m
//  Moonlight
//
//  Created by Cameron Gutman on 10/18/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "VideoDecoderRenderer.h"

@implementation VideoDecoderRenderer {
    StreamView *_view;
    id <ConnectionCallbacks> _callbacks;
    
    AVSampleBufferDisplayLayer *sampleBufferDisplayLayer;
    UIImageView *imageDisplayView;
    Boolean waitingForSps, waitingForPps, waitingForVps;
    int videoFormat;
    
    NSData *spsData, *ppsData, *vpsData;
    CMVideoFormatDescriptionRef formatDesc;
    
    CADisplayLink *_displayLink;
    VTDecompressionSessionRef _decompressionSession;
    
    NSMutableArray<EnqueuedSampleBuffer *> *_videoDecoderBufferObjects;
    NSMutableArray<EnqueuedImageBuffer *> *_imageBufferObjects;
    CMTime _firstPresentationTimeMs;
    // use the rendering strategies to experiment with different kinds of frame blending
    // todo: fix the frame blending in the different rendering strategies
    RenderingStrategy _renderingStrategy;
    // the presentation timestamps do not seem to have an impact on anything meaningful
    PresentationTimeType _presentationTimeType;
    CFTimeInterval _lastTime;
    os_log_t log;
    int _refreshRate;
}

- (void)reinitializeDisplayLayer {
    log = os_log_create("VideoDecoderRenderer", OS_LOG_CATEGORY_POINTS_OF_INTEREST);
    CALayer *oldLayer;
    CALayer *targetLayer;
    switch (self->_renderingStrategy) {
        case kLinkedAVSampleBufferDisplayLayer:
        case kDispatchedAVSampleBufferDisplayLayer:
            oldLayer = sampleBufferDisplayLayer;
            sampleBufferDisplayLayer = [[AVSampleBufferDisplayLayer alloc] init];
            sampleBufferDisplayLayer.videoGravity = AVLayerVideoGravityResizeAspect;
            targetLayer = sampleBufferDisplayLayer;
            break;
        case kLinkedVTDecoderSessionWithAccelerateFramework:
        case kLinkedVTDecoderSessionWithCPUDrawing:
            imageDisplayView = [[UIImageView alloc] init];
            targetLayer = imageDisplayView.layer;
            break;
    }
    
    
    targetLayer.bounds = _view.bounds;
    targetLayer.backgroundColor = [UIColor blackColor].CGColor;
    targetLayer.position = CGPointMake(CGRectGetMidX(_view.bounds), CGRectGetMidY(_view.bounds));
    
    // Hide the layer until we get an IDR frame. This ensures we
    // can see the loading progress label as the stream is starting.
    targetLayer.hidden = YES;
    
    if (oldLayer != nil) {
        // Switch out the old display layer with the new one
        [_view.layer replaceSublayer:oldLayer with:targetLayer];
    } else {
        [_view.layer addSublayer:targetLayer];
    }
    
    // We need some parameter sets before we can properly start decoding frames
    waitingForSps = true;
    spsData = nil;
    waitingForPps = true;
    ppsData = nil;
    waitingForVps = true;
    vpsData = nil;
    _firstPresentationTimeMs = kCMTimeInvalid;
    
    if (formatDesc != nil) {
        CFRelease(formatDesc);
        formatDesc = nil;
    }
}

- (id)initWithView:(StreamView *)view callbacks:(id <ConnectionCallbacks>)callbacks {
    self = [super init];
    _videoDecoderBufferObjects = [NSMutableArray arrayWithCapacity:16];
    _imageBufferObjects = [NSMutableArray arrayWithCapacity:16];
    _presentationTimeType = kRtpPresentationTime;
    _renderingStrategy = kLinkedVTDecoderSessionWithAccelerateFramework;
    _view = view;
    _callbacks = callbacks;
    
    [self reinitializeDisplayLayer];
    
    return self;
}

- (void)setupWithVideoFormat:(int)videoFormat refreshRate:(int)refreshRate {
    self->videoFormat = videoFormat;
    self->_refreshRate = refreshRate;
    
    switch (self->_renderingStrategy) {
        case kLinkedVTDecoderSessionWithAccelerateFramework:
        case kLinkedVTDecoderSessionWithCPUDrawing:
        case kLinkedAVSampleBufferDisplayLayer: {
            _displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayLinkCallback:)];
            
            if (@available(iOS 15.0, *)) {
                const long maxFps = [[UIScreen mainScreen] maximumFramesPerSecond];
                _displayLink.preferredFrameRateRange = CAFrameRateRangeMake(refreshRate, maxFps, maxFps);
            } else if (@available(iOS 10.0, tvOS 10.0, *)) {
                _displayLink.preferredFramesPerSecond = refreshRate;
            } else {
                _displayLink.frameInterval = 1;
            }
            
            [_displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
            break;
        }
        default:
            break;
    }
}

- (void)displayLinkCallback:(CADisplayLink *)sender {
    OSStatus status;
    CFTimeInterval thisTime = CACurrentMediaTime();
    os_signpost_id_t identifier;
    
    if (@available(iOS 12.0, *)) {
        identifier = os_signpost_id_generate(log);
        os_signpost_interval_begin(log, identifier, "Display Link Callback", "%{public}f", 1.0 / (thisTime - _lastTime));
    }
    
    NSUInteger count;
    switch (self->_renderingStrategy) {
        case kLinkedVTDecoderSessionWithCPUDrawing:
        case kLinkedVTDecoderSessionWithAccelerateFramework: {
            NSArray<EnqueuedImageBuffer *> *thisImageBuffers;
            
            // blend all the queued images
            @synchronized (self) {
                thisImageBuffers = [self->_imageBufferObjects copy];
                [self->_imageBufferObjects removeAllObjects];
            }
            
            count = thisImageBuffers.count;
            Boolean sawIdr = false;
            if (count == 0) {
                break;
            }
            
            UIImage *image;
            if (self->_renderingStrategy == kLinkedVTDecoderSessionWithAccelerateFramework) {
                CGImageRef imageOut;
                vImage_Error vImageError;
                vImage_Buffer vBufferFinal = {};
                if (count == 1) {
                    CVImageBufferRef buffer = thisImageBuffers[0].imageBuffer;
                    status = VTCreateCGImageFromCVPixelBuffer(buffer, NULL, &imageOut);
                    CFRelease(buffer);
                    if (status != noErr) {
                        Log(LOG_E, @"VTCreateCGImageFromCVPixelBuffer error: %d", status);
                        return;
                    }
                } else {
                    // todo: picture winds up magenta cast for some reason
                    Pixel_8 alphaBlend = ((unsigned char) (255.0 / (double) count));
                    Pixel_8 slack = (unsigned char) 255 - (alphaBlend * (unsigned char) count);
                    
                    for (unsigned int i = 0; i < count; i++) {
                        vImage_Buffer vBufferThis;
                        CVImageBufferRef buffer = thisImageBuffers[i].imageBuffer;
                        vImageCVImageFormatRef format = vImageCVImageFormat_CreateWithCVPixelBuffer(buffer);
                        vImageError = vImageBuffer_InitWithCVPixelBuffer(&vBufferThis, &vImageFormatARGB8888, buffer, format, NULL, kvImageNoFlags);
                        vImageCVImageFormat_Release(format);
                        // don't need this anymore
                        CFRelease(buffer);
                        
                        if (vImageError != kvImageNoError) {
                            Log(LOG_E, @"vImageBuffer_InitWithCVPixelBuffer error: %d", vImageError);
                            return;
                        }
                        
                        if (vBufferFinal.data == NULL) {
                            // create vBufferFinal
                            vImageError = vImageBuffer_Init(&vBufferFinal, vBufferThis.height, vBufferThis.width, 32, kvImageNoFlags);
                            if (vImageError != kvImageNoError) {
                                Log(LOG_E, @"vImageBuffer_Init error: %d", vImageError);
                                return;
                            }
                        }
                        
                        Boolean shouldUseSlack = i == count - 1;
                        vImageError = vImagePremultipliedConstAlphaBlend_ARGB8888(&vBufferThis, alphaBlend + (shouldUseSlack ? slack : (unsigned char) 0), &vBufferFinal, &vBufferFinal, kvImageNoFlags);
                        free(vBufferThis.data);
                        if (vImageError != kvImageNoError) {
                            Log(LOG_E, @"vImagePremultipliedConstAlphaBlend_ARGB8888 error: %d", vImageError);
                            return;
                        }
                    }
                    
                    imageOut = vImageCreateCGImageFromBuffer(&vBufferFinal, &vImageFormatARGB8888, NULL, NULL, kvImageNoFlags, &vImageError);
                    free(vBufferFinal.data);
                    if (vImageError != kvImageNoError) {
                        Log(LOG_E, @"vImageCreateCGImageFromBuffer error: %d", vImageError);
                        return;
                    }
                }
                
                if (imageOut == NULL) {
                    Log(LOG_E, @"displayLinkCallback failed because imageOut was NULL");
                    return;
                }
                image = [[UIImage alloc] initWithCGImage:imageOut];
                CFRelease(imageOut);
            } else if (self->_renderingStrategy == kLinkedVTDecoderSessionWithCPUDrawing) {
                // todo: too slow
                double alpha = 1.0 / (double) count;
                CVImageBufferRef firstBuffer = thisImageBuffers[0].imageBuffer;
                CGSize size = CGSizeMake(CVPixelBufferGetWidth(firstBuffer), CVPixelBufferGetHeight(firstBuffer));
                UIGraphicsBeginImageContextWithOptions(size, YES, 1.0);
                [[UIColor whiteColor] setFill];
                CGRect rect = CGRectMake(0, 0, size.width, size.height);
                UIRectFill(rect);
                
                for (unsigned int i = 0; i < count; i++) {
                    CVImageBufferRef buffer = thisImageBuffers[i].imageBuffer;
                    CGImageRef imageOut;
                    status = VTCreateCGImageFromCVPixelBuffer(buffer, NULL, &imageOut);
                    CFRelease(buffer);
                    if (status != noErr) {
                        Log(LOG_E, @"VTCreateCGImageFromCVPixelBuffer error: %d", status);
                        return;
                    }
                    UIImage *singleImage = [[UIImage alloc] initWithCGImage:imageOut];
                    CFRelease(imageOut);
                    [singleImage drawInRect:rect blendMode:kCGBlendModeNormal alpha:i == 0 ? 1.0 : alpha];
                }
                image = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
            }
            
            self->imageDisplayView.image = image;
            
            for (unsigned int i = 0; i < count; i++) {
                if (thisImageBuffers[i].isIdr) {
                    sawIdr = true;
                    break;
                }
            }
            
            if (sawIdr) {
                // Ensure the layer is visible now
                self->imageDisplayView.hidden = NO;
                
                // Tell our parent VC to hide the progress indicator
                [_callbacks videoContentShown];
            }
            break;
        }
        
        case kLinkedAVSampleBufferDisplayLayer: {
            NSArray<EnqueuedSampleBuffer *> *thisVideoDecoderBufferObjects;
            @synchronized (self) {
                thisVideoDecoderBufferObjects = [self->_videoDecoderBufferObjects copy];
                [self->_videoDecoderBufferObjects removeAllObjects];
            }
            
            count = [thisVideoDecoderBufferObjects count];
            
            for (unsigned int i = 0; i < count; i++) {
                Boolean isLastSampleBufferThisFrame = i == count - 1;
                EnqueuedSampleBuffer *videoDecoderBufferObject = thisVideoDecoderBufferObjects[i];
                [self sendToDisplayLayer:videoDecoderBufferObject isLastSampleBufferThisFrame:isLastSampleBufferThisFrame];
            }
            break;
        }
        default:
            break;
    }
    
    if (@available(iOS 12.0, *)) {
        // instruments will record the number of frames that were awaiting to be rendered.
        // more than 1 indicates the draw rate was too slow to render all the networked frames
        // 0 indicates the network didn't provide a frame in time for this vsync
        os_signpost_interval_end(log, identifier, "Display Link Callback", "%{public}d", count);
    }
    
    _lastTime = thisTime;
}

- (void)sendToDisplayLayer:(EnqueuedSampleBuffer *)videoDecoderBufferObject isLastSampleBufferThisFrame:(Boolean)isLastSampleBufferThisFrame {
    int frameType = videoDecoderBufferObject.frameType;
    
    CMSampleBufferRef sampleBuffer = videoDecoderBufferObject.sampleBuffer;
    if (_presentationTimeType == kNoPresentationTime) {
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, isLastSampleBufferThisFrame ? kCFBooleanTrue : kCFBooleanFalse);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DoNotDisplay, isLastSampleBufferThisFrame ? kCFBooleanFalse : kCFBooleanTrue);
    }
    
    [sampleBufferDisplayLayer enqueueSampleBuffer:sampleBuffer];
    CFRelease(sampleBuffer);
    
    if (frameType == FRAME_TYPE_IDR
            && sampleBufferDisplayLayer.hidden == YES) {
        // Ensure the layer is visible now
        sampleBufferDisplayLayer.hidden = NO;
        
        // Tell our parent VC to hide the progress indicator
        [_callbacks videoContentShown];
    }
}

- (void)enqueueImageBuffer:(EnqueuedImageBuffer *)bufferObject {
    @synchronized (self) {
        [self->_imageBufferObjects addObject:bufferObject];
    }
}

- (void)cleanup {
    _firstPresentationTimeMs = kCMTimeInvalid;
    [_displayLink invalidate];
}

#define FRAME_START_PREFIX_SIZE 4
#define NALU_START_PREFIX_SIZE 3
#define NAL_LENGTH_PREFIX_SIZE 4

- (Boolean)readyForPictureData {
    if (videoFormat & VIDEO_FORMAT_MASK_H264) {
        return !waitingForSps && !waitingForPps;
    } else {
        // H.265 requires VPS in addition to SPS and PPS
        return !waitingForVps && !waitingForSps && !waitingForPps;
    }
}

- (void)updateBufferForRange:(CMBlockBufferRef)existingBuffer data:(unsigned char *)data offset:(int)offset length:(int)nalLength {
    OSStatus status;
    size_t oldOffset = CMBlockBufferGetDataLength(existingBuffer);
    
    // If we're at index 1 (first NALU in frame), enqueue this buffer to the memory block
    // so it can handle freeing it when the block buffer is destroyed
    if (offset == 1) {
        int dataLength = nalLength - NALU_START_PREFIX_SIZE;
        
        // Pass the real buffer pointer directly (no offset)
        // This will give it to the block buffer to free when it's released.
        // All further calls to CMBlockBufferAppendMemoryBlock will do so
        // at an offset and will not be asking the buffer to be freed.
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, data,
                nalLength + 1, // Add 1 for the offset we decremented
                kCFAllocatorDefault,
                NULL, 0, nalLength + 1, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int) status);
            return;
        }
        
        // Write the length prefix to existing buffer
        const uint8_t lengthBytes[] = {(uint8_t) (dataLength >> 24), (uint8_t) (dataLength >> 16),
                (uint8_t) (dataLength >> 8), (uint8_t) dataLength};
        status = CMBlockBufferReplaceDataBytes(lengthBytes, existingBuffer,
                oldOffset, NAL_LENGTH_PREFIX_SIZE);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int) status);
            return;
        }
    } else {
        // Append a 4 byte buffer to this block for the length prefix
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, NULL,
                NAL_LENGTH_PREFIX_SIZE,
                kCFAllocatorDefault, NULL, 0,
                NAL_LENGTH_PREFIX_SIZE, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferAppendMemoryBlock failed: %d", (int) status);
            return;
        }
        
        // Write the length prefix to the new buffer
        int dataLength = nalLength - NALU_START_PREFIX_SIZE;
        const uint8_t lengthBytes[] = {(uint8_t) (dataLength >> 24), (uint8_t) (dataLength >> 16),
                (uint8_t) (dataLength >> 8), (uint8_t) dataLength};
        status = CMBlockBufferReplaceDataBytes(lengthBytes, existingBuffer,
                oldOffset, NAL_LENGTH_PREFIX_SIZE);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int) status);
            return;
        }
        
        // Attach the buffer by reference to the block buffer
        status = CMBlockBufferAppendMemoryBlock(existingBuffer, &data[offset + NALU_START_PREFIX_SIZE],
                dataLength,
                kCFAllocatorNull, // Don't deallocate data on free
                NULL, 0, dataLength, 0);
        if (status != noErr) {
            Log(LOG_E, @"CMBlockBufferReplaceDataBytes failed: %d", (int) status);
            return;
        }
    }
}

// This function must free data for bufferType == BUFFER_TYPE_PICDATA
- (int)submitDecodeBuffer:(unsigned char *)data length:(int)length bufferType:(int)bufferType frameType:(int)frameType pts:(unsigned int)pts {
    OSStatus status;
    
    if (bufferType != BUFFER_TYPE_PICDATA) {
        if (bufferType == BUFFER_TYPE_VPS) {
            Log(LOG_I, @"Got VPS");
            vpsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForVps = false;
            
            // We got a new VPS so wait for a new SPS to match it
            waitingForSps = true;
        } else if (bufferType == BUFFER_TYPE_SPS) {
            Log(LOG_I, @"Got SPS");
            spsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForSps = false;
            
            // We got a new SPS so wait for a new PPS to match it
            waitingForPps = true;
        } else if (bufferType == BUFFER_TYPE_PPS) {
            Log(LOG_I, @"Got PPS");
            ppsData = [NSData dataWithBytes:&data[FRAME_START_PREFIX_SIZE] length:length - FRAME_START_PREFIX_SIZE];
            waitingForPps = false;
        }
        
        // See if we've got all the parameter sets we need for our video format
        if ([self readyForPictureData]) {
            if (videoFormat & VIDEO_FORMAT_MASK_H264) {
                const uint8_t *const parameterSetPointers[] = {[spsData bytes], [ppsData bytes]};
                const size_t parameterSetSizes[] = {[spsData length], [ppsData length]};
                
                Log(LOG_I, @"Constructing new H264 format description");
                status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                        2, /* count of parameter sets */
                        parameterSetPointers,
                        parameterSetSizes,
                        NAL_LENGTH_PREFIX_SIZE,
                        &formatDesc);
                if (status != noErr) {
                    Log(LOG_E, @"Failed to create H264 format description: %d", (int) status);
                    formatDesc = NULL;
                }
            } else {
                const uint8_t *const parameterSetPointers[] = {[vpsData bytes], [spsData bytes], [ppsData bytes]};
                const size_t parameterSetSizes[] = {[vpsData length], [spsData length], [ppsData length]};
                
                Log(LOG_I, @"Constructing new HEVC format description");
                
                if (@available
                (iOS
                        11.0, *)) {
                    status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(kCFAllocatorDefault,
                            3, /* count of parameter sets */
                            parameterSetPointers,
                            parameterSetSizes,
                            NAL_LENGTH_PREFIX_SIZE,
                            nil,
                            &formatDesc);
                } else {
                    // This means Moonlight-common-c decided to give us an HEVC stream
                    // even though we said we couldn't support it. All we can do is abort().
                    abort();
                }
                
                if (status != noErr) {
                    Log(LOG_E, @"Failed to create HEVC format description: %d", (int) status);
                    formatDesc = NULL;
                }
            }
            
            // create the decompression session once we have a format
            // todo: does the format change?
            if (formatDesc != NULL) {
                if (_decompressionSession != NULL) {
                    VTDecompressionSessionInvalidate(_decompressionSession);
                    CFRelease(_decompressionSession);
                    _decompressionSession = NULL;
                }
                
                VTDecompressionOutputCallbackRecord callbackRecord = {
                        .decompressionOutputCallback=&VTDecoderCallback,
                        .decompressionOutputRefCon=(__bridge void *) self
                };
                
                // todo: this might be causing the magenta cast
                NSDictionary *imageOutputDescription = @{(NSString *) kCVPixelBufferOpenGLESTextureCacheCompatibilityKey: @true};
                NSDictionary *sessionConfiguration = @{(NSString *) kVTDecompressionPropertyKey_RealTime: @true};
                status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                        formatDesc,
                        (__bridge CFDictionaryRef) sessionConfiguration,
                        (__bridge CFDictionaryRef) imageOutputDescription,
                        &callbackRecord,
                        &_decompressionSession);
                
                if (status != noErr) {
                    Log(LOG_E, @"VTDecompressionSessionCreate failed: %d", (int) status);
                    return DR_NEED_IDR;
                }
            }
        }
        
        // No frame data to submit for these NALUs
        return DR_OK;
    }
    
    if (formatDesc == NULL) {
        // Can't decode if we haven't gotten our parameter sets yet
        free(data);
        return DR_NEED_IDR;
    }
    
    // Check for previous decoder errors before doing anything
    if (sampleBufferDisplayLayer.status == AVQueuedSampleBufferRenderingStatusFailed) {
        Log(LOG_E, @"Display layer rendering failed: %@", sampleBufferDisplayLayer.error);
        
        // Recreate the display layer on the main thread.
        // We need to use dispatch_sync() or we may miss
        // some parameter sets while the layer is being
        // recreated.
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self reinitializeDisplayLayer];
        });
        
        // Request an IDR frame to initialize the new decoder
        free(data);
        return DR_NEED_IDR;
    }
    
    // todo: check for VTDecompressionSession errors
    
    // Now we're decoding actual frame data here
    CMBlockBufferRef blockBuffer;
    
    status = CMBlockBufferCreateEmpty(NULL, 0, 0, &blockBuffer);
    if (status != noErr) {
        Log(LOG_E, @"CMBlockBufferCreateEmpty failed: %d", (int) status);
        free(data);
        return DR_NEED_IDR;
    }
    
    int lastOffset = -1;
    for (int i = 0; i < length - FRAME_START_PREFIX_SIZE; i++) {
        // Search for a NALU
        if (data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1) {
            // It's the start of a new NALU
            if (lastOffset != -1) {
                // We've seen a start before this so enqueue that NALU
                [self updateBufferForRange:blockBuffer data:data offset:lastOffset length:i - lastOffset];
            }
            
            lastOffset = i;
        }
    }
    
    if (lastOffset != -1) {
        // Enqueue the remaining data
        [self updateBufferForRange:blockBuffer data:data offset:lastOffset length:length - lastOffset];
    }
    
    // From now on, CMBlockBuffer owns the data pointer and will free it when it's dereferenced
    // Enqueue video samples on the main thread
    Boolean usePresentationTime = _presentationTimeType != kNoPresentationTime;
    CMTime presentationTime;
    switch (_presentationTimeType) {
        case kRtpPresentationTime:
            presentationTime = CMTimeMake(pts, 1000);
            break;
        case kTimestampPresentationTime:
            // uses the last vsync as the timestamp
            // todo: targetTimestamp just appears frozen, which is weird
            presentationTime = CMTimeMakeWithSeconds(_displayLink.timestamp, 10000);
            break;
        case kMachTime:
            presentationTime = CMClockMakeHostTimeFromSystemUnits(mach_absolute_time());
            break;
        case kNoPresentationTime:
        default:
            presentationTime = kCMTimeInvalid;
            break;
        
    }
    
    if (usePresentationTime && !CMTIME_IS_VALID(_firstPresentationTimeMs)) {
        _firstPresentationTimeMs = presentationTime;
        CMTimebaseRef controlTimebase;
        CMTimebaseCreateWithSourceClock(CFAllocatorGetDefault(), CMClockGetHostTimeClock(), &controlTimebase);
        CMTimebaseSetRate(controlTimebase, 1.0f);
        CMTimebaseSetTime(controlTimebase, presentationTime);
        dispatch_async(dispatch_get_main_queue(), ^{
            sampleBufferDisplayLayer.controlTimebase = controlTimebase;
        });
    }
    
    CMSampleBufferRef sampleBuffer;
    CMSampleTimingInfo timingInfo = {
            .duration = CMTimeMakeWithSeconds(1.0 / _refreshRate, 100000),
            .presentationTimeStamp = presentationTime,
            .decodeTimeStamp = kCMTimeInvalid
    };
    
    status = CMSampleBufferCreate(kCFAllocatorDefault,
            blockBuffer,
            true, NULL,
            NULL, formatDesc, 1, usePresentationTime ? 1 : 0,
            usePresentationTime ? &timingInfo : NULL, 0, NULL,
            &sampleBuffer);
    
    CFRelease(blockBuffer);
    
    if (status != noErr) {
        Log(LOG_E, @"CMSampleBufferCreate failed: %d", (int) status);
        return DR_NEED_IDR;
    }
    
    if (usePresentationTime) {
        status = CMSampleBufferSetOutputPresentationTimeStamp(sampleBuffer, presentationTime);
        
        if (status != noErr) {
            CFRelease(sampleBuffer);
            Log(LOG_E, @"CMSampleBufferSetOutputPresentationTimeStamp failed: %d", (int) status);
            return DR_NEED_IDR;
        }
    }
    
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, YES);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
    CFDictionarySetValue(dict, kCMSampleAttachmentKey_NotSync, frameType == FRAME_TYPE_IDR ? kCFBooleanFalse : kCFBooleanTrue);
    
    switch (self->_renderingStrategy) {
        case kLinkedVTDecoderSessionWithCPUDrawing:
        case kLinkedVTDecoderSessionWithAccelerateFramework: {
            status = VTDecompressionSessionDecodeFrame(self->_decompressionSession,
                    sampleBuffer,
                    kVTDecodeFrame_EnableAsynchronousDecompression | kVTDecodeFrame_EnableTemporalProcessing,
                    sampleBuffer,
                    NULL);
            
            // this happens when the frame is decoded
            // CFRelease(sampleBuffer);
            
            if (status != noErr) {
                Log(LOG_E, @"VTDecompressionSessionDecodeFrame failed: %d", (int) status);
                return DR_NEED_IDR;
            }
            
            break;
        }
        case kLinkedAVSampleBufferDisplayLayer: {
            EnqueuedSampleBuffer *enqueuedSampleBuffer = [[EnqueuedSampleBuffer alloc] initWithSampleBuffer:sampleBuffer frameType:frameType];
            @synchronized (self) {
                [_videoDecoderBufferObjects addObject:enqueuedSampleBuffer];
            }
            break;
        }
        case kDispatchedAVSampleBufferDisplayLayer: {
            EnqueuedSampleBuffer *enqueuedSampleBuffer = [[EnqueuedSampleBuffer alloc] initWithSampleBuffer:sampleBuffer frameType:frameType];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self sendToDisplayLayer:enqueuedSampleBuffer isLastSampleBufferThisFrame:false];
            });
            break;
        }
    }
    
    return DR_OK;
}

@end

void VTDecoderCallback(void *decompressionOutputRefCon,
        void *sourceFrameRefCon,
        OSStatus status,
        VTDecodeInfoFlags infoFlags,
        CVImageBufferRef imageBuffer,
        CMTime presentationTimestamp,
        CMTime presentationDuration) {
    VideoDecoderRenderer *videoDecoderRenderer = (__bridge VideoDecoderRenderer *) (decompressionOutputRefCon);
    CMSampleBufferRef sourceFrame = (CMSampleBufferRef) sourceFrameRefCon;
    CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sourceFrame, NO);
    CFMutableDictionaryRef dict = (CFMutableDictionaryRef) CFArrayGetValueAtIndex(attachments, 0);
    Boolean isIdr = CFBooleanGetValue((CFBooleanRef) CFDictionaryGetValue(dict, kCMSampleAttachmentKey_NotSync));
    // we can release the source frame now, because we got the data we needed out of it
    CFRelease(sourceFrame);
    [videoDecoderRenderer enqueueImageBuffer:[[EnqueuedImageBuffer alloc] initWithImageBuffer:imageBuffer presentationTimestamp:presentationTimestamp presentationDuration:presentationDuration isIdr:isIdr]];
}
