//
//  KxMovieDecoder.m
//  FFMPEG_PlayerDemo
//
//  Created by ocean on 2018/8/15.
//  Copyright © 2018年 ocean. All rights reserved.
//

#import "KxMovieDecoder.h"
#import <CoreGraphics/CoreGraphics.h>
#include "libavformat/avformat.h"
//#include "avcodec.h"
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"
#import "libavutil/pixdesc.h"
#import "KxAudioManager.h"
#import <Accelerate/Accelerate.h>

///////////////////////////////静态////////////////////////////////////////
NSString * kxmovieErrorDomain = @"ru.kolyvan.kxmovie";
static void FFLog(void* context, int level, const char* format, va_list args);

static NSError * kxmovieError (NSInteger code, id info)
{
    NSDictionary *userInfo = nil;
    
    if ([info isKindOfClass: [NSDictionary class]]) {
        
        userInfo = info;
        
    } else if ([info isKindOfClass: [NSString class]]) {
        
        userInfo = @{ NSLocalizedDescriptionKey : info };
    }
    
    return [NSError errorWithDomain:kxmovieErrorDomain
                               code:code
                           userInfo:userInfo];
}
static NSString * errorMessage (kxMovieError errorCode)
{
    switch (errorCode) {
        case kxMovieErrorNone:
            return @"";
            
        case kxMovieErrorOpenFile:
            return NSLocalizedString(@"Unable to open file", nil);
            
        case kxMovieErrorStreamInfoNotFound:
            return NSLocalizedString(@"Unable to find stream information", nil);
            
        case kxMovieErrorStreamNotFound:
            return NSLocalizedString(@"Unable to find stream", nil);
            
        case kxMovieErrorCodecNotFound:
            return NSLocalizedString(@"Unable to find codec", nil);
            
        case kxMovieErrorOpenCodec:
            return NSLocalizedString(@"Unable to open codec", nil);
            
        case kxMovieErrorAllocateFrame:
            return NSLocalizedString(@"Unable to allocate frame", nil);
            
        case kxMovieErroSetupScaler:
            return NSLocalizedString(@"Unable to setup scaler", nil);
            
        case kxMovieErroReSampler:
            return NSLocalizedString(@"Unable to setup resampler", nil);
            
        case kxMovieErroUnsupported:
            return NSLocalizedString(@"The ability is not supported", nil);
    }
}

static BOOL isNetworkPath (NSString *path)
{
    NSRange r = [path rangeOfString:@":"];
    if (r.location == NSNotFound)
        return NO;
    NSString *scheme = [path substringToIndex:r.length];
    if ([scheme isEqualToString:@"file"])
        return NO;
    return YES;
}
static BOOL audioCodecIsSupported(AVCodecContext *audioCodecCtx) {
    if (audioCodecCtx->sample_fmt == AV_SAMPLE_FMT_S16) {
        
        id<KxAudioManager> audioManager = [KxAudioManager audioManager];
        return (int)audioManager.samplingRate == audioCodecCtx->sample_rate &&
        audioManager.numOutputChannels==audioCodecCtx->channels;
    }
    return NO;
}
static NSArray *collectStreams(AVFormatContext *formatCtx, enum AVMediaType codecType)
{
    NSMutableArray *ma = [NSMutableArray array];
    for (NSInteger i = 0; i < formatCtx->nb_streams; ++i)
        if (codecType == formatCtx->streams[i]->codec->codec_type)
            [ma addObject: [NSNumber numberWithInteger: i]];
    return [ma copy];
}
static void avStreamFPSTimeBase(AVStream *st, CGFloat defaultTimeBase, CGFloat *pFPS, CGFloat *pTimeBase) {
    
    CGFloat fps, timebase;
    if (st->time_base.den && st->time_base.num) {
        timebase = av_q2d(st->time_base);
    }else if (st->codec->time_base.den && st->codec->time_base.num) {
        timebase = av_q2d(st->codec->time_base);
    }else {
        timebase = defaultTimeBase;
    }
    
    if (st->avg_frame_rate.den && st->avg_frame_rate.num) {
        fps = av_q2d(st->avg_frame_rate);
    }else if (st->r_frame_rate.den && st->r_frame_rate.num) {
        fps = av_q2d(st->r_frame_rate);
    }else {
        fps =  1.0/timebase;
    }
    
    if (pFPS) {
        *pFPS = fps;
    }
    if (pTimeBase) {
        *pTimeBase = timebase;
    }
}

static int interrupt_callback(void *ctx)
{
    if (!ctx)
        return 0;
    __unsafe_unretained KxMovieDecoder *p = (__bridge KxMovieDecoder *)ctx;
    const BOOL r = [p interruptDecoder];
    if (r) NSLog(@"DEBUG: INTERRUPT_CALLBACK!");
    return r;
}
static NSData* copyFrameData(UInt8 *src, int linesize, int width, int height) {
    
    width = MIN(linesize, width);
    NSMutableData *md = [NSMutableData dataWithLength:width*height];
    Byte *dst = md.mutableBytes;
    for (NSUInteger i=0; i<height; ++i) {
        memcpy(dst, src, width);
        dst += width;
        src += linesize;
    }
    return md;
}
///////////////////////////////静态////////////////////////////////////////

///////////////////////////////数据类////////////////////////////////////////
@interface KxMovieFrame ()
@property (readwrite, nonatomic) CGFloat position;
@property (readwrite, nonatomic) CGFloat duration;
@end

@implementation KxMovieFrame
@end


@interface KxAudioFrame ()
@property (readwrite, nonatomic, strong) NSData *samples;
@end

@implementation KxAudioFrame
- (KxMovieFrameType) type { return KxMovieFrameTypeAudio; }
@end


@interface KxVideoFrame ()
@property (readwrite, nonatomic) NSUInteger width;
@property (readwrite, nonatomic) NSUInteger height;
@end

@implementation KxVideoFrame
- (KxMovieFrameType) type { return KxMovieFrameTypeVideo; }
@end


@interface KxVideoFrameRGB ()
@property (readwrite, nonatomic) NSUInteger linesize;
@property (readwrite, nonatomic, strong) NSData *rgb;
@end

@implementation KxVideoFrameRGB
- (KxVideoFrameFormat) format { return KxVideoFrameFormatRGB; }
-(UIImage*)asImage {
    UIImage *image = nil;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)(_rgb));
    
    if (provider) {
        CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
        if (colorSpace) {
            CGImageRef imageRef = CGImageCreate(self.width,
                                                self.height,
                                                8,
                                                24,
                                                self.linesize,
                                                colorSpace,
                                                kCGBitmapByteOrderDefault,
                                                provider,
                                                NULL,
                                                YES,
                                                kCGRenderingIntentDefault);
            if (imageRef) {
                image = [UIImage imageWithCGImage:imageRef];
                CGImageRelease(imageRef);
            }
            CGColorSpaceRelease(colorSpace);
        }
        CGDataProviderRelease(provider);
    }
    
    return image;
}
@end


@interface KxVideoFrameYUV ()
@property (readwrite, nonatomic, strong) NSData *luma;
@property (readwrite, nonatomic, strong) NSData *chromaB;
@property (readwrite, nonatomic, strong) NSData *chromaR;
@end

@implementation KxVideoFrameYUV
- (KxVideoFrameFormat) format { return KxVideoFrameFormatYUV; }
@end
///////////////////////////////数据类////////////////////////////////////////














/////////////////////////////////解码类//////////////////////////////////////
@interface KxMovieDecoder ()
{
    AVFormatContext     *_formatCtx;
    NSInteger           _videoStream;
    NSInteger           _audioStream;
    AVCodecContext      *_videoCodecCtx;
    AVCodecContext      *_audioCodecCtx;
    AVFrame             *_videoFrame;
    AVFrame             *_audioFrame;
    NSUInteger          _artworkStream;
    NSArray             *_videoStreams;
    NSArray             *_audioStreams;
    
    CGFloat             _videoTimeBase;
    CGFloat             _audioTimeBase;
    SwrContext          *_swrContext;
    struct SwrContext   *_swsContext;
    
    void                *_swrBuffer;
    NSUInteger          _swrBufferSize;
    
    AVPicture           _picture;
    BOOL                _pictureValid;
    
    KxVideoFrameFormat  _videoFrameFormat;
    CGFloat             _position;
}

@end

@implementation KxMovieDecoder

#pragma mark life
+(void)initialize {
    av_log_set_callback(FFLog);
    av_register_all();
    avformat_network_init();
}


#pragma mark public
-(BOOL)openFile: (NSString *) path
          error: (NSError **) perror {
    
    _isNetwork = isNetworkPath(path);
    static BOOL needNetworkInit = YES;
    if (needNetworkInit && _isNetwork) {
        needNetworkInit = NO;
        avformat_network_init();
    }
    
    _path = path;
    kxMovieError errCode = [self openInput:path];
    
    if (errCode == kxMovieErrorNone) {
        kxMovieError videoErr = [self openVideoStream];
        kxMovieError audioErr = [self openAudioStream];
        
        if (videoErr != kxMovieErrorNone && audioErr != kxMovieErrorNone) {
            errCode = videoErr;
        }
    }
    
    if (errCode != kxMovieErrorNone) {
        
        [self closeFile];
        
        NSString *errMsg = errorMessage(errCode);
        if (perror) {
            *perror = kxmovieError(errCode, errMsg);
        }
        
        return NO;
    }
    
    return YES;
}

-(NSArray*)decodeFrames:(CGFloat)minDuration {
    
    iLog(@"%@", NSStringFromSelector(_cmd));
    if (_videoStream==-1 && _audioStream==-1) {
        return nil;
    }
    
    NSMutableArray *result = [NSMutableArray array];
    AVPacket packet;
    CGFloat decodeDuration = 0;
    BOOL finished = NO;
    while (!finished) {
        
        iLog(@"%@, while(!finished)", NSStringFromSelector(_cmd));
        if (av_read_frame(_formatCtx, &packet)<0) {
            _isEOF = YES;
            break;
        }
        
        if (packet.stream_index == _videoStream) {
            int pktSize = packet.size;
            
            while (pktSize>0) {
                iLog(@"%@, while (pktSize)-video", NSStringFromSelector(_cmd));
                int gotframe = 0;
                int len = avcodec_decode_video2(_videoCodecCtx,
                                                _videoFrame,
                                                &gotframe,
                                                &packet);
                if (len<0) {
                    NSLog(@"Error: decode video error, skip packet");
                    break;
                }
                
                if (gotframe) {
                    if (!_disableDeinterlacing && _videoFrame->interlaced_frame) {
                        avpicture_deinterlace((AVPicture*)_videoFrame,
                                              (AVPicture*)_videoFrame,
                                              _videoCodecCtx->pix_fmt,
                                              _videoCodecCtx->width,
                                              _videoCodecCtx->height);
                    }
                    
                    KxVideoFrame *frame = [self handleVideoFrame];
                    if (frame) {
                        [result addObject:frame];
                        
                        _position = frame.position;
                        decodeDuration += frame.duration;
                        if (decodeDuration>minDuration) {
                            finished = YES;
                        }
                    }
                }
                
                if (0 == len) {
                    break;
                }
                
                pktSize -= len;
            }
        }else if (packet.stream_index == _audioStream) {
            
            int pktSize = packet.size;
            while (pktSize>0) {
                iLog(@"%@, while (pktSize)-audio", NSStringFromSelector(_cmd));
                int gotFrame = 0;
                int len = avcodec_decode_audio4(_audioCodecCtx,
                                                _audioFrame,
                                                &gotFrame,
                                                &packet);
                if (len<0) {
                    NSLog(@"Error: decode audio error, skip packet");
                    break;
                }
                
                if (gotFrame) {
                    KxAudioFrame *frame = [self handleAudioFrame];
                    if (frame) {
                        [result addObject:frame];
                        
                        if (_videoStream == -1) {
                            _position = frame.position;
                            decodeDuration += frame.duration;
                            if (decodeDuration>minDuration) {
                                finished = YES;
                            }
                        }
                    }
                }
                
                if (0 == len) {
                    break;
                }
                
                pktSize -= len;
            }
        }
        
        av_free_packet(&packet);
    }
    
    return result;
}


- (BOOL) validVideo
{
    return _videoStream != -1;
}
- (BOOL) validAudio
{
    return _audioStream != -1;
}
- (BOOL) setupVideoFrameFormat: (KxVideoFrameFormat) format {
    
    if (format == KxVideoFrameFormatYUV && _videoCodecCtx &&
        (_videoCodecCtx->pix_fmt==AV_PIX_FMT_YUV420P || _videoCodecCtx->pix_fmt==AV_PIX_FMT_YUVJ420P)) {
        _videoFrameFormat = KxVideoFrameFormatYUV;
        
        return YES;
    }
    
    _videoFrameFormat = KxVideoFrameFormatRGB;
    return _videoFrameFormat==format;
}

#pragma mark private
/*解码流程为：注册所有格式->
            初始化AVFormatContext->
            打开一个视频文件->
            获取视频文件的流信息->
            获取初始的视频流->
            获得视频流编码内容->
            获得音频流编码内容->
            获取视频编码格式->
            获取音频编码格式->
            用一个编码格式打开一个编码文件->
            从frame中读取packet->
            解码视频->
            解码音频->
            释放packet->
            关闭解码器->
            关闭AVFormatContext
 */
-(kxMovieError)openInput:(NSString*)path {
    
    AVFormatContext *formatCtx = NULL;
    if (_interruptCallback) {
        formatCtx = avformat_alloc_context();
        if (!formatCtx) {
            return kxMovieErrorOpenFile;
        }
        
        AVIOInterruptCB cb = {interrupt_callback, (__bridge void*)(self)};
        formatCtx->interrupt_callback = cb;
    }
    
    //打开多媒体文件
    if (avformat_open_input(&formatCtx, [path cStringUsingEncoding:NSUTF8StringEncoding], NULL, NULL)<0) {
        //打开失败
        if (formatCtx) {
            avformat_free_context(formatCtx);
        }
        return kxMovieErrorOpenFile;
    }
    
    //获取多媒体文件的流信息
    if (avformat_find_stream_info(formatCtx, NULL)<0) {
        avformat_close_input(&formatCtx);
        return kxMovieErrorOpenFile;
    }
    
    //这一步会用有效的信息把 AVFormatContext 的流域（streams field）填满。作为一个可调试的诊断，我们会将这些信息全盘输出到标准错误输出中，不过你在一个应用程序的产品中并不用这么做
    av_dump_format(formatCtx, 0, [path.lastPathComponent cStringUsingEncoding:NSUTF8StringEncoding], false);
    
    _formatCtx = formatCtx;
    return kxMovieErrorNone;
}
- (BOOL) interruptDecoder
{
    if (_interruptCallback)
        return _interruptCallback();
    return NO;
}
-(kxMovieError)openVideoStream {
    
    kxMovieError errCode = kxMovieErrorStreamNotFound;
    _videoStream = -1;
    _artworkStream = -1;
    _videoStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_VIDEO);
    for (NSNumber *n in _videoStreams) {
        
        const NSUInteger iStream = n.integerValue;
        if (0 == (_formatCtx->streams[iStream]->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
            errCode = [self openVideoStream:iStream];
            if (errCode == kxMovieErrorNone) {
                break;
            }
        }else {
            
            _artworkStream = iStream;
        }
    }
    
    return errCode;
}
-(kxMovieError)openVideoStream:(NSInteger)videoStram {
    
    AVCodecContext *codecCtx = _formatCtx->streams[videoStram]->codec;
    AVCodec *codec = avcodec_find_decoder(codecCtx->codec_id);
    if (!codec) {
        return kxMovieErrorStreamNotFound;
    }
    
    if (avcodec_open2(codecCtx, codec, NULL)<0) {
        return kxMovieErrorOpenCodec;
    }
    
    _videoFrame = av_frame_alloc();
    if (!_videoFrame) {
        avcodec_close(codecCtx);
        return kxMovieErrorAllocateFrame;
    }
    
    _videoStream = videoStram; //av_find_best_stream(_formatCtx, AVMEDIA_TYPE_VIDEO, -1, -1, &codec, 0);
    _videoCodecCtx = codecCtx;
    
    AVStream *st = _formatCtx->streams[_videoStream];
    avStreamFPSTimeBase(st, 0.04, &_fps, &_videoTimeBase);
    
    return kxMovieErrorNone;
}
-(kxMovieError)openAudioStream {
    
    kxMovieError errCode = kxMovieErrorStreamNotFound;
    _audioStream = -1;
    _audioStreams = collectStreams(_formatCtx, AVMEDIA_TYPE_AUDIO);
    for (NSNumber *n in _audioStreams) {
        errCode = [self openAudioStream:n.integerValue];
        if (errCode == kxMovieErrorNone) {
            break;
        }
    }
    
    return errCode;
}
-(kxMovieError)openAudioStream:(NSInteger)audioStream {
    
    AVCodecContext *codecCtx = _formatCtx->streams[audioStream]->codec;
    AVCodec *codec = avcodec_find_decoder(codecCtx->codec_id);
    
    SwrContext *swrContex = NULL; //重采样
    if (!codec) {
        return kxMovieErrorCodecNotFound;
    }
    if (avcodec_open2(codecCtx, codec, NULL)<0) {
        return kxMovieErrorOpenCodec;
    }
    
    
    //判断是否需要重采样
    if (!audioCodecIsSupported(codecCtx)) {
        id<KxAudioManager> audioManager = [KxAudioManager audioManager];
        //swr_alloc_set_opts: 分配SwrContext并设置/重置常用的参数;
        //输入输出参数中sample rate(采样率)、sample format(采样格式)、channel layout等参数
        swrContex = swr_alloc_set_opts(NULL,
                                       av_get_default_channel_layout(audioManager.numOutputChannels),
                                       AV_SAMPLE_FMT_S16,
                                       audioManager.samplingRate,
                                       av_get_default_channel_layout(codecCtx->channels),
                                       codecCtx->sample_fmt,
                                       codecCtx->sample_rate,
                                       0,
                                       NULL);
        if (!swrContex || swr_init(swrContex)) {
            if (swrContex) {
                //释放掉SwrContext结构体并将此结构体置为NULL
                swr_free(&swrContex);
            }
            avcodec_close(codecCtx);
            
            return kxMovieErroReSampler;
        }
    }
    
    _audioFrame = av_frame_alloc();
    
    if (!_audioFrame) {
        if (swrContex) {
            swr_free(&swrContex);
        }
        avcodec_close(codecCtx);
        return kxMovieErrorAllocateFrame;
    }
    
    _audioStream = audioStream;
    _audioCodecCtx = codecCtx;
    _swrContext = swrContex;
    
    AVStream *st = _formatCtx->streams[_audioStream];
    avStreamFPSTimeBase(st, 0.025, 0, &_audioTimeBase);
    
    return kxMovieErrorNone;
}
-(void)closeFile {
    
    [self closeAudioStream];
    [self closeVideoStream];
    
    _videoStreams = nil;
    _audioStreams = nil;
    
    if (_formatCtx) {
        _formatCtx->interrupt_callback.opaque = NULL;
        _formatCtx->interrupt_callback.callback = NULL;
        
        avformat_close_input(&_formatCtx);
        _formatCtx = NULL;
    }
}
-(void)closeAudioStream {
    
    _audioStream = -1;
    
    if (_swrBuffer) {
        free(_swrBuffer);
        _swrBuffer = NULL;
        _swrBufferSize = 0;
    }
    
    if (_swrContext) {
        swr_free(&_swrContext);
        _swrContext = NULL;
    }
    
    if (_audioFrame) {
        av_free(_audioFrame);
        _audioFrame = NULL;
    }
    
    if (_audioCodecCtx) {
        avcodec_close(_audioCodecCtx);
        _audioCodecCtx = NULL;
    }
}
-(void)closeVideoStream {
    
    _videoStream = -1;
    
    [self closeScaler];
    
    if (_videoFrame) {
        av_free(_videoFrame);
        _videoFrame = NULL;
    }
    
    if (_videoCodecCtx) {
        avcodec_close(_videoCodecCtx);
        _videoCodecCtx = NULL;
    }
}
-(void)closeScaler {
    
    if (_swrContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
    
    if (_pictureValid) {
        avpicture_free(&_picture);
        _pictureValid = NO;
    }
}
-(KxVideoFrame*)handleVideoFrame {
    
    if (!_videoFrame->data[0]) {
        return nil;
    }
    
    KxVideoFrame *frame;
    if (_videoFrameFormat == KxVideoFrameFormatYUV) {
        KxVideoFrameYUV *yuvFrame = [[KxVideoFrameYUV alloc]init];
        yuvFrame.luma = copyFrameData(_videoFrame->data[0],
                                      _videoFrame->linesize[0],
                                      _videoCodecCtx->width,
                                      _videoCodecCtx->height);
        yuvFrame.chromaB = copyFrameData(_videoFrame->data[1],
                                         _videoFrame->linesize[1],
                                         _videoCodecCtx->width/2,
                                         _videoCodecCtx->height/2);
        yuvFrame.chromaR = copyFrameData(_videoFrame->data[2],
                                         _videoFrame->linesize[2],
                                         _videoCodecCtx->width/2,
                                         _videoCodecCtx->height/2);
        
        frame = yuvFrame;
    }else {
        
        if (!_swsContext && ![self setupScaler]) {
            
            NSLog(@"Error: fail setup video scaler");
            return nil;
        }
        
        sws_scale(_swsContext, (const uint8_t **)_videoFrame->data,
                  _videoFrame->linesize,
                  0,
                  _videoCodecCtx->height,
                  _picture.data,
                  _picture.linesize);
        
        KxVideoFrameRGB *rgbFrame = [[KxVideoFrameRGB alloc]init];
        rgbFrame.linesize = _picture.linesize[0];
        rgbFrame.rgb = [NSData dataWithBytes:_picture.data[0] length:rgbFrame.linesize*_videoFrame->height];
        frame = rgbFrame;
    }
    
    frame.width = _videoCodecCtx->width;
    frame.height = _videoCodecCtx->height;
    frame.position =av_frame_get_best_effort_timestamp(_videoFrame)*_videoTimeBase;
    
    const int64_t frameDuration = av_frame_get_pkt_duration(_videoFrame);
    if (frameDuration) {
        
        frame.duration = frameDuration*_videoTimeBase;
        frame.duration += _videoFrame->repeat_pict*_videoTimeBase*0.5;
    }else {
        
        frame.duration = 1.0/_fps;
    }
    
    return frame;
}
-(KxAudioFrame*)handleAudioFrame {
    
    if (!_audioFrame->data[0]) {
        return nil;
    }
    
    id<KxAudioManager> audioManager = [KxAudioManager audioManager];
    const NSUInteger numChannels = audioManager.numOutputChannels;
    NSUInteger numFrames;
    void *audioData;
    if (_swrContext) {
        
        const NSUInteger ratio = MAX(1, audioManager.samplingRate/_audioCodecCtx->sample_rate)*MAX(1, audioManager.numOutputChannels / _audioCodecCtx->channels)*2;
        const int bufSize = av_samples_get_buffer_size(NULL,
                                                       audioManager.numOutputChannels,
                                                       _audioFrame->nb_samples*ratio,
                                                       AV_SAMPLE_FMT_S16,
                                                       1);
        if (!_swrBuffer || _swrBufferSize<bufSize) {
            _swrBufferSize = bufSize;
            _swrBuffer = realloc(_swrBuffer, _swrBufferSize);
        }
        
        Byte *outbuf[2] = {_swrBuffer, 0};
        numFrames = swr_convert(_swrContext,
                                outbuf,
                                _audioFrame->nb_samples*ratio,
                                (const uint8_t **)_audioFrame->data,
                                _audioFrame->nb_samples);
        if (numFrames<0) {
            NSLog(@"Error: fail resample audio");
            return nil;
        }
        
        audioData = _swrBuffer;
    }else {
        
        if (_audioCodecCtx->sample_fmt != AV_SAMPLE_FMT_S16) {
            NSLog(@"Error: bucheck, audio format is invalid");
            return nil;
        }
        audioData = _audioFrame->data[0];
        numFrames = _audioFrame->nb_samples;
    }
    
    const NSUInteger numElements = numFrames*numChannels;
    NSMutableData *data = [NSMutableData dataWithLength:numElements*sizeof(float)];
    
    float scale = 1.0/(float)INT16_MAX;
    vDSP_vflt16((SInt16*)audioData, 1, data.mutableBytes, 1, numElements);
    vDSP_vsmul(data.mutableBytes, 1, &scale, data.mutableBytes, 1, numElements);
    
    KxAudioFrame *frame = [[KxAudioFrame alloc]init];
    frame.position = av_frame_get_best_effort_timestamp(_audioFrame)*_audioTimeBase;
    frame.duration = av_frame_get_pkt_duration(_audioFrame)*_audioTimeBase;
    frame.samples = data;
    
    if (frame.duration==0) {
        frame.duration = frame.samples.length/(sizeof(float)*numChannels*audioManager.samplingRate);
    }
    
    return frame;
}
-(BOOL)setupScaler {
    [self chooseScaler];
    
    _pictureValid = avpicture_alloc(&_picture,
                                    AV_PIX_FMT_RGB24,
                                    _videoCodecCtx->width,
                                    _videoCodecCtx->height);
    if (!_pictureValid) {
        return NO;
    }
    
    _swsContext = sws_getCachedContext(_swsContext,
                                       _videoCodecCtx->width,
                                       _videoCodecCtx->height,
                                       _videoCodecCtx->pix_fmt,
                                       _videoCodecCtx->width,
                                       _videoCodecCtx->height,
                                       AV_PIX_FMT_RGB24,
                                       SWS_FAST_BILINEAR,
                                       NULL,
                                       NULL,
                                       NULL);
    
    return _swsContext != NULL;
}
-(void)chooseScaler {
    
    if (_swsContext) {
        sws_freeContext(_swsContext);
        _swsContext = NULL;
    }
    
    if (_pictureValid) {
        avpicture_free(&_picture);
        _pictureValid = NO;
    }
}


#pragma mark set/get
- (NSUInteger) frameWidth
{
    return _videoCodecCtx ? _videoCodecCtx->width : 0;
}

- (NSUInteger) frameHeight
{
    return _videoCodecCtx ? _videoCodecCtx->height : 0;
}

@end




static void FFLog(void* context, int level, const char* format, va_list args) {
    @autoreleasepool {
        //Trim time at the beginning and new line at the end
        NSString* message = [[NSString alloc] initWithFormat: [NSString stringWithUTF8String: format] arguments: args];
        switch (level) {
            case 0:
            case 1:
                NSLog(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
                break;
            case 2:
                NSLog(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
                break;
            case 3:
            case 4:
                NSLog(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
                break;
            default:
                NSLog(@"%@", [message stringByTrimmingCharactersInSet:[NSCharacterSet newlineCharacterSet]]);
                break;
        }
    }
}
