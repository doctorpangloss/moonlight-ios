//
// Created by Benjamin Berman on 12/3/21.
// Copyright (c) 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>


@interface EnqueuedImageBuffer : NSObject
@property CVImageBufferRef imageBuffer;
@property CMTime presentationTimestamp;
@property CMTime presentationDuration;
@property Boolean isIdr;

- (instancetype)initWithImageBuffer:(CVImageBufferRef)imageBuffer presentationTimestamp:(CMTime)presentationTimestamp presentationDuration:(CMTime)presentationDuration isIdr:(Boolean)isIdr;

@end