//
// Created by Benjamin Berman on 11/29/21.
// Copyright (c) 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "EnqueuedSampleBuffer.h"


@implementation EnqueuedSampleBuffer {

}
- (instancetype)initWithSampleBuffer:(CMSampleBufferRef)sampleBuffer frameType:(int)frameType {
    self = [super init];
    if (self) {
        self.sampleBuffer = sampleBuffer;
        self.frameType = frameType;
    }
    
    return self;
}


@end