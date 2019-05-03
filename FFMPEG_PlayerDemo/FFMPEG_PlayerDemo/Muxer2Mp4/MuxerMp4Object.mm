//
//  MuxerMp4Object.m
//  BatteryCam
//
//  Created by ocean on 2018/6/8.
//  Copyright © 2018年 oceanwing. All rights reserved.
//

#import "MuxerMp4Object.h"
#include "streamMuxer.hpp"
//#import "AACEncoder.h"

@interface MuxerMp4Object(){
    StreamMuxer *muxer;
    GLNK_VideoDataFormat videoFormat;
    GLNK_AudioDataFormat audioFormat;
    
    NSInteger _videoWidth;
    NSInteger _videoHeigh;
    
    NSString *_localFilePath;
}

@property(nonatomic,assign)NSInteger writeVideoCnt;
@property(nonatomic,assign)NSInteger writeAudioCnt;

//@property(nonatomic,strong)AACEncoder *aacEncoder;

@end

@implementation MuxerMp4Object

-(instancetype)initMuxerMp4WithLocalPath:(NSString *)filePath{
    self=[super init];
    if (self) {
        _localFilePath=filePath;
        [self initMuxerWithWidth:1920 heigh:1080];
        
        //self.aacEncoder=[[AACEncoder alloc] initWithBitrate:32000 samplerate:8000 channel:1];
    }
    return self;
}

-(void)initMuxerWithWidth:(NSInteger)width heigh:(NSInteger)heigh{
    if (_videoWidth!=width&&_videoHeigh!=heigh) {
        _videoWidth=width;
        _videoHeigh=heigh;
        self.writeVideoCnt=0;
        self.writeAudioCnt=0;
        if (muxer) {
            muxer=nil;
        }
         
        char *filePath=(char *)[_localFilePath cStringUsingEncoding:NSASCIIStringEncoding];
        muxer=new StreamMuxer(filePath);
        memset(&videoFormat,0,sizeof(GLNK_VideoDataFormat));
        memset(&audioFormat,0,sizeof(GLNK_AudioDataFormat));
        
        videoFormat.bitrate       = -1;
        videoFormat.framerate     = 15;
        videoFormat.gopSize       = 30;
        videoFormat.width         = (int)width;
        videoFormat.height        = (int)heigh;
        
        audioFormat.channelNumber   = 1;
        audioFormat.samplesRate    = 16000;
        audioFormat.sample_fmt    = AV_SAMPLE_FMT_S16;
        audioFormat.iLayout      = (int)av_get_default_channel_layout(audioFormat.channelNumber);
        audioFormat.bitrate      = -1;
        
        muxer->SaveMediaInfo(videoFormat,audioFormat);
    }
}

-(void)receiveVideoFrame:(uint8_t *)video_frame videoSize:(int)video_size videoWidth:(int)video_width videoHeigh:(int)video_heigh{
    [self initMuxerWithWidth:video_width heigh:video_heigh];
    
    AVPacket pkt;
    av_init_packet(&pkt);
    pkt.data       = video_frame;
    pkt.size       = video_size;
    pkt.stream_index   = VIDEO_ID;
    
    AVRational inTimeBase;
    inTimeBase.num     = 1;
    inTimeBase.den     = 1000;
    self.writeVideoCnt++;
    pkt.pts        = 1000/15*self.writeVideoCnt;
    pkt.dts       = pkt.pts;
    pkt.duration    = 1000/15;
    
    muxer->InputData5(pkt, VIDEO_ID, AUDIO_ID);
}

-(void)receiveAudioFrame:(uint8_t *)audio_frame audioSize:(int)audio_size{
    if (audio_frame&&audio_size>0) {
        AVPacket pkt;
        av_init_packet(&pkt);
        pkt.data       = (uint8_t *)audio_frame;
        pkt.size       = audio_size;
        pkt.stream_index   = AUDIO_ID;
        
        AVRational inTimeBase;
        inTimeBase.num     = 1;
        inTimeBase.den     = 1000;
        self.writeAudioCnt++;
        pkt.pts        = 1000*1024/16000*self.writeAudioCnt;
        pkt.dts       = pkt.pts;
        pkt.duration    = 1000*1024/16000;
        
        self->muxer->InputData5(pkt, VIDEO_ID, AUDIO_ID);
    }
    
    /*
     __weak typeof(self)weakSelf=self;
    [self.aacEncoder encodePCMToAAC:(char *)audio_frame len:audio_size callBack:^(char *aacData, int aac_len) {
        if (aacData&&aac_len>0) {
            AVPacket pkt;
            av_init_packet(&pkt);
            pkt.data       = (uint8_t *)aacData;
            pkt.size       = aac_len;
            pkt.stream_index   = AUDIO_ID;
            
            AVRational inTimeBase;
            inTimeBase.num     = 1;
            inTimeBase.den     = 1000;
            weakSelf.writeAudioCnt++;
            pkt.pts        = 1000*1024/8000*weakSelf.writeAudioCnt;
            pkt.dts       = pkt.pts;
            pkt.duration    = 1000*1024/8000;
            
            self->muxer->InputData5(pkt, VIDEO_ID, AUDIO_ID);
        }
    }];
     */
}

-(void)stopMuxerMp4{
    if (muxer) {
        //    [self.aacEncoder free];
        muxer->WriteFileTail();
        
        _videoWidth=0;
        _videoHeigh=0;
    }
}

-(void)clearData{
    _videoWidth=0;
    _videoHeigh=0;
    self.writeVideoCnt=0;
    self.writeAudioCnt=0;
    
    if (_localFilePath) {
        _localFilePath=nil;
    }
    
    if (muxer) {
        muxer=nil;
    }
    
    /*
    if (self.aacEncoder) {
        self.aacEncoder=nil;
    }*/
}

@end
