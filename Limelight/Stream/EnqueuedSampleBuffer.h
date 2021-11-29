//
// Created by Benjamin Berman on 11/29/21.
// Copyright (c) 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>


@interface EnqueuedSampleBuffer : NSObject
@property CMSampleBufferRef sampleBuffer;
@property int frameType;

- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sampleBuffer frameType:(int)frameType;


@end