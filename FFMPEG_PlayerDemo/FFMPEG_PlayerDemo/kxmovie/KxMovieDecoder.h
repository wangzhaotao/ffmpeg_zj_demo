//
//  KxMovieDecoder.h
//  FFMPEG_PlayerDemo
//
//  Created by ocean on 2018/8/15.
//  Copyright © 2018年 ocean. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <UIKit/UIKit.h>

typedef enum {
    
    kxMovieErrorNone,
    kxMovieErrorOpenFile,
    kxMovieErrorStreamInfoNotFound,
    kxMovieErrorStreamNotFound,
    kxMovieErrorCodecNotFound,
    kxMovieErrorOpenCodec,
    kxMovieErrorAllocateFrame,
    kxMovieErroSetupScaler,
    kxMovieErroReSampler,
    kxMovieErroUnsupported,
    
} kxMovieError;


typedef enum {
    
    KxMovieFrameTypeAudio,
    KxMovieFrameTypeVideo,
    KxMovieFrameTypeArtwork,
    KxMovieFrameTypeSubtitle,
    
} KxMovieFrameType;

typedef enum {
    
    KxVideoFrameFormatRGB,
    KxVideoFrameFormatYUV,
    
} KxVideoFrameFormat;




@interface KxMovieFrame : NSObject
@property (nonatomic, readonly) KxMovieFrameType type;
@property (nonatomic, readonly) CGFloat duration;
@property (nonatomic, readonly) CGFloat position;
@end

@interface KxAudioFrame : KxMovieFrame
@property (nonatomic, strong, readonly) NSData *samples;
@end

@interface KxVideoFrame : KxMovieFrame
@property (nonatomic, readonly) KxVideoFrameFormat format;
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@end

@interface KxVideoFrameRGB : KxVideoFrame
@property (nonatomic, readonly) NSUInteger linesize;
@property (nonatomic, strong, readonly) NSData *rgb;
-(UIImage*)asImage;
@end

@interface KxVideoFrameYUV :KxVideoFrame
@property (nonatomic, strong, readonly) NSData *luma;
@property (nonatomic, strong, readonly) NSData *chromaB;
@property (nonatomic, strong, readonly) NSData *chromaR;
@end








typedef BOOL(^KxMovieDecoderInterruptCallback)();

@interface KxMovieDecoder : NSObject

@property (readonly, nonatomic, strong) NSString *path;
@property (readonly, nonatomic) BOOL isEOF;
@property (readonly, nonatomic) BOOL isNetwork;
@property (readonly, nonatomic) CGFloat fps;
@property (readonly, nonatomic) BOOL validVideo;
@property (readonly, nonatomic) BOOL validAudio;
@property (readonly, nonatomic) NSUInteger frameWidth;
@property (readonly, nonatomic) NSUInteger frameHeight;
@property (readwrite, nonatomic) BOOL disableDeinterlacing;
@property (readwrite, nonatomic, strong) KxMovieDecoderInterruptCallback interruptCallback;


- (BOOL) setupVideoFrameFormat: (KxVideoFrameFormat) format;
-(NSArray*)decodeFrames:(CGFloat)minDuration;

-(BOOL)openFile: (NSString *) path
            error: (NSError **) perror;
- (BOOL) interruptDecoder;

@end
