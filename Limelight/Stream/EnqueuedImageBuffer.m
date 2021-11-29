//
// Created by Benjamin Berman on 12/3/21.
// Copyright (c) 2021 Moonlight Game Streaming Project. All rights reserved.
//

#import "EnqueuedImageBuffer.h"


@implementation EnqueuedImageBuffer {

}

- (instancetype)initWithImageBuffer:(CVImageBufferRef)imageBuffer presentationTimestamp:(CMTime)presentationTimestamp presentationDuration:(CMTime)presentationDuration isIdr:(Boolean)isIdr {
    self = [super init];
    if (self) {
        self.imageBuffer = imageBuffer;
        self.presentationTimestamp = presentationTimestamp;
        self.presentationDuration = presentationDuration;
        self.isIdr = isIdr;
    }
    
    CFRetain(self->_imageBuffer);
    
    return self;
}


@end