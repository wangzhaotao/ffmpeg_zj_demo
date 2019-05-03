//
//  MuxerMp4Object.h
//  BatteryCam
//
//  Created by ocean on 2018/6/8.
//  Copyright © 2018年 oceanwing. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface MuxerMp4Object : NSObject

-(instancetype)initMuxerMp4WithLocalPath:(NSString *)filePath;

-(void)receiveVideoFrame:(uint8_t *)video_frame videoSize:(int)video_size videoWidth:(int)video_width videoHeigh:(int)video_heigh;

-(void)receiveAudioFrame:(uint8_t *)audio_frame audioSize:(int)audio_size;

-(void)stopMuxerMp4;

-(void)clearData;

@end
