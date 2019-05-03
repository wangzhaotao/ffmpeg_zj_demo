//
//  KxMovieViewController.m
//  FFMPEG_PlayerDemo
//
//  Created by ocean on 2018/8/15.
//  Copyright © 2018年 ocean. All rights reserved.
//

#import "KxMovieViewController.h"
#import "KxAudioManager.h"
#import "KxMovieDecoder.h"
#import "KxMovieGLView.h"
#import "KxLogger.h"
#import "MuxerMp4Object.h"

NSString * const KxMovieParameterMinBufferedDuration = @"KxMovieParameterMinBufferedDuration";
NSString * const KxMovieParameterMaxBufferedDuration = @"KxMovieParameterMaxBufferedDuration";
NSString * const KxMovieParameterDisableDeinterlacing = @"KxMovieParameterDisableDeinterlacing";

static NSMutableDictionary * gHistory;

#define LOCAL_MIN_BUFFERED_DURATION   0.2
#define LOCAL_MAX_BUFFERED_DURATION   0.4
#define NETWORK_MIN_BUFFERED_DURATION 2.0
#define NETWORK_MAX_BUFFERED_DURATION 4.0

@interface KxMovieViewController ()
{
    CGFloat             _moviePosition;
    NSMutableArray      *_videoFrames;
    NSMutableArray      *_audioFrames;
    KxMovieDecoder      *_decoder;
    dispatch_queue_t    _dispatchQueue;
    
    CGFloat             _minBufferedDuration;
    CGFloat             _maxBufferedDuration;
    
    NSDictionary        *_parameters;
    
    KxMovieGLView       *_glView;
    UIImageView         *_imageView;
    
    BOOL                _fullscreen;
    BOOL                _interrupted;
    
    CGFloat             _bufferedDuration;
    
    BOOL                _buffered;
    NSTimeInterval      _tickCorrectionTime;
    NSTimeInterval      _tickCorrectionPosition;
    NSUInteger          _tickCounter;
    
    NSData              *_currentAudioFrame;
    NSUInteger          _currentAudioFramePos;
}

@property (readwrite) BOOL playing;
@property (readwrite) BOOL decoding;

//H264+AAC转成Mp4
@property(nonatomic, strong) MuxerMp4Object *muxerMp4Obj;
@property (nonatomic, strong) UIButton *recordBtn;

@end

@implementation KxMovieViewController

+(void)initialize {
    if (!gHistory)
        gHistory = [NSMutableDictionary dictionary];
}

- (BOOL)prefersStatusBarHidden { return YES; }

+ (id) movieViewControllerWithContentPath: (NSString *) path
                               parameters: (NSDictionary *) parameters
{
    //初始化 - 音频播放控件
    id<KxAudioManager> audioManager = [KxAudioManager audioManager];
    [audioManager activateAudioSession];
    
    //视频
    return [[KxMovieViewController alloc] initWithContentPath: path parameters: parameters];
}

-(id)initWithContentPath:(NSString*)path parameters:(NSDictionary*)parameters {
    
    NSAssert(path.length>0, @"empty path");
    
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _moviePosition = 0;
        
        _parameters = parameters;
        
        __weak KxMovieViewController *weakSelf = self;
        
        KxMovieDecoder *decoder = [[KxMovieDecoder alloc]init];
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
            
            NSError *error = nil;
            [decoder openFile:path error:&error];
            
            __strong KxMovieViewController *strongSelf = weakSelf;
            if (strongSelf) {
                
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf setMovieDecoder:decoder withError:error];
                    
                    [strongSelf restorePlay];
                });
            }
        });
    }
    return self;
}


- (void)viewDidLoad {
    [super viewDidLoad];
    //
    _recordBtn = [[UIButton alloc]initWithFrame:CGRectMake(30, Screen_Height-55, Screen_Width-60, 50)];
    [_recordBtn setTitle:@"录制视频" forState:UIControlStateNormal];
    [_recordBtn addTarget:self action:@selector(recordBtnAction:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:_recordBtn];
    
    
    
}

-(void)viewDidDisappear:(BOOL)animated {
    
    [self pause];
    
    [[NSNotificationCenter defaultCenter]removeObserver:self];
    if (_dispatchQueue) {
        _dispatchQueue = NULL;
    }
    
    [super viewDidDisappear:animated];
}


-(void)loadView {

    CGRect bounds = [[UIScreen mainScreen]applicationFrame];

    self.view = [[UIView alloc]initWithFrame:bounds];
    self.view.backgroundColor = [UIColor blueColor];
    self.view.tintColor = [UIColor blackColor];

    if (_decoder) {

        [self setupPresentView];

    } else {

        //隐藏控制控件
    }
}

-(void)dealloc {
    
    [self pause];
    
    [[NSNotificationCenter defaultCenter]removeObserver:self];
    if (_dispatchQueue) {
        _dispatchQueue = NULL;
    }
}

#pragma mark actions
-(void)recordBtnAction:(UIButton*)sender {
    
    if (!sender.selected) {
        
        sender.selected = YES;
        if (self.muxerMp4Obj) {
            [self.muxerMp4Obj clearData];
            self.muxerMp4Obj=nil;
        }
        
        NSString *videoPath=LVDFileFullpath(@"test");
        if([[NSFileManager defaultManager] fileExistsAtPath:videoPath]==YES){
            [[NSFileManager defaultManager] removeItemAtPath:videoPath error:nil];
        }
        BOOL suc = [[NSFileManager defaultManager] createFileAtPath:videoPath contents:nil attributes:nil];
        NSLog(@"videoPath=%@, %@", videoPath, suc?@"成功":@"失败");
        self.muxerMp4Obj=[[MuxerMp4Object alloc] initMuxerMp4WithLocalPath:videoPath];
    }else {
        
        sender.selected = NO;
        
        [self.muxerMp4Obj stopMuxerMp4];
    }
}


#pragma mark poublic
-(void)play {
    
    if (self.playing) {
        return;
    }
    
    if (!_decoder.validVideo && !_decoder.validAudio) {
        return;
    }
    
    if (_interrupted) {
        return;
    }
    
    self.playing = YES;
    _interrupted = NO;
    
    [self asyncDecodeFrames];
    
    dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, 0.1*NSEC_PER_SEC);
    dispatch_after(popTime, dispatch_get_main_queue(), ^{
        [self tick];
    });
    
    if (_decoder.validAudio) {
        [self enableAudio:YES];
    }
}
-(void)pause {
    
    if (!self.playing) {
        return;
    }
    
    self.playing = NO;
    [self enableAudio:NO];
}


#pragma mark private
-(void)restorePlay {
    
    NSNumber *n = [gHistory valueForKey:_decoder.path];
    if (n) {
        //
        NSLog(@"Error: invalidate function");
        
    }else {
        [self play];
    }
}
-(void)setMovieDecoder:(KxMovieDecoder*)decoder
             withError:(NSError*)error {
    
    if (!error && decoder) {
        
        _decoder = decoder;
        //同步队列
        _dispatchQueue = dispatch_queue_create("KxMovie", DISPATCH_QUEUE_SERIAL);
        _videoFrames = [NSMutableArray array];
        _audioFrames = [NSMutableArray array];
        
        if (_decoder.isNetwork) {
            
            _minBufferedDuration = NETWORK_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = NETWORK_MAX_BUFFERED_DURATION;
            
        } else {
            
            _minBufferedDuration = LOCAL_MIN_BUFFERED_DURATION;
            _maxBufferedDuration = LOCAL_MAX_BUFFERED_DURATION;
        }
        
        if (_decoder.validVideo) {
            _minBufferedDuration *= 10;
        }
        
        if (_parameters.count) {
            id val;
            
            val = [_parameters valueForKey: KxMovieParameterMinBufferedDuration];
            if ([val isKindOfClass:[NSNumber class]])
                _minBufferedDuration = [val floatValue];
            
            val = [_parameters valueForKey: KxMovieParameterMaxBufferedDuration];
            if ([val isKindOfClass:[NSNumber class]])
                _maxBufferedDuration = [val floatValue];
            
            val = [_parameters valueForKey: KxMovieParameterDisableDeinterlacing];
            if ([val isKindOfClass:[NSNumber class]])
                _decoder.disableDeinterlacing = [val boolValue];
            
            if (_maxBufferedDuration < _minBufferedDuration) {
                _maxBufferedDuration = _minBufferedDuration*2;
            }
        }
        
        if (self.isViewLoaded) {
            [self setupPresentView];
            
        }
        
    }else {
        
        
    }
}

-(void)setupPresentView {
    
    CGRect bounds = CGRectMake(30, 64, Screen_Width-60, Screen_Height-64-60);//self.view.boudns;
    
    if (_decoder.validVideo) {
        _glView = [[KxMovieGLView alloc]initWithFrame:bounds decoder:_decoder];
    }
    
    if (!_glView) {
        [_decoder setupVideoFrameFormat:KxVideoFrameFormatRGB];
        _imageView = [[UIImageView alloc]initWithFrame:bounds];
        _imageView.backgroundColor = [UIColor blackColor];
    }
    
    UIView *frameView = [self frameView];
    frameView.contentMode = UIViewContentModeScaleAspectFit;
    frameView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleHeight | UIViewAutoresizingFlexibleBottomMargin;
    [self.view insertSubview:frameView atIndex:0];
    
    if (_decoder.validVideo) {
        //手势
        [self setupUserInteraction];
    }else {
        
        _imageView.image = [UIImage imageNamed:@"kxmovie.bundle/music_icon.png"];
        _imageView.contentMode = UIViewContentModeCenter;
    }
    
    self.view.backgroundColor = [UIColor blueColor];
    
}
-(UIView*)frameView {
    return _glView? _glView:_imageView;
}

- (void) setupUserInteraction {
    
    
}

-(void)asyncDecodeFrames {
    iLog(@"%@, ", NSStringFromSelector(_cmd));
    
    //decoding
    if (_decoding) {
        return;
    }
    
    //
    __weak KxMovieViewController *weakSelf = self;
    __weak KxMovieDecoder *weakDecoder = _decoder;
    
    const CGFloat duration = _decoder.isNetwork? .0f: 0.1f;
    self.decoding = YES;
    dispatch_async(_dispatchQueue, ^{
        
        {
            __strong KxMovieViewController *strongSelf = weakSelf;
            if (!strongSelf.playing) {
                return;
            }
        }
        
        BOOL good = YES;
        while (good) {
            
            iLog(@"%@, while循环", NSStringFromSelector(_cmd));
            good = NO;
            @autoreleasepool {
                
                __strong KxMovieDecoder *strongDecoder = weakDecoder;
                if (strongDecoder && (strongDecoder.validAudio || strongDecoder.validVideo)) {
                    
                    NSArray *frames = [strongDecoder decodeFrames:duration];
                    __strong KxMovieViewController *strongSelf = weakSelf;
                    if (strongSelf) {
                        good = [strongSelf addFrames:frames];
                    }
                }
            }
        }
        
        {
            __strong KxMovieViewController *strongSelf = weakSelf;
            if (strongSelf) {
                strongSelf.decoding = NO;
            }
        }
    });
}

-(BOOL)addFrames:(NSArray*)frames {
    
    if (_decoder.validVideo) {
        
        @synchronized(_videoFrames){
            for (KxMovieFrame *frame in frames) {
                if (frame.type == KxMovieFrameTypeVideo) {
                    [_videoFrames addObject:frame];
                    _bufferedDuration +=frame.duration;
                    
//                    dispatch_async(dispatch_get_main_queue(), ^{
//                        if (self.muxerMp4Obj && _recordBtn.selected) {
//                            if ([frame isKindOfClass:[KxVideoFrameRGB class]]) {
//                                KxVideoFrameRGB *rgbFrame = (KxVideoFrameRGB*)frame;
//                                [self.muxerMp4Obj receiveVideoFrame:(uint8_t *)[rgbFrame.rgb bytes] videoSize:(int)[rgbFrame.rgb length] videoWidth:100 videoHeigh:100];
//                            }else if ([frame isKindOfClass:[KxVideoFrameYUV class]]) {
//                                KxVideoFrameYUV *lumaFrame = (KxVideoFrameYUV*)frame;
//                                [self.muxerMp4Obj receiveVideoFrame:(uint8_t *)[lumaFrame.luma bytes] videoSize:(int)[lumaFrame.luma length] videoWidth:100 videoHeigh:100];
//                            }
//                        }
//                    });
                    
                    
                    
                }
            }
        }
    }
    
    if (_decoder.validAudio) {
        
        @synchronized(_audioFrames) {
            for (KxMovieFrame *frame in frames) {
                if (frame.type == KxMovieFrameTypeAudio) {
                    [_audioFrames addObject:frame];
                    if (!_decoder.validVideo) {
                        _bufferedDuration += frame.duration;
                    }
                    
//                    dispatch_async(dispatch_get_main_queue(), ^{
//                        if (self.muxerMp4Obj && _recordBtn.selected) {
//                            
//                            if ([frame isKindOfClass:[KxVideoFrameRGB class]]) {
//                                KxAudioFrame *audioFrame = (KxAudioFrame*)frame;
//                                [self.muxerMp4Obj receiveAudioFrame:(uint8_t *)[audioFrame.samples bytes] audioSize:(int)[audioFrame.samples length]];
//                            }
//                        }
//                    });
                    
                    
                }
            }
        }
        
        if (!_decoder.validVideo) {
            for (KxMovieFrame *frame in frames) {
                if (frame.type==KxMovieFrameTypeArtwork) {
                    NSLog(@"Error: frame.type ArtWork");
                }
            }
        }
    }
    
    return self.playing && _bufferedDuration<_maxBufferedDuration;
}

-(void)enableAudio:(BOOL)on {
    
    id <KxAudioManager> audioManager = [KxAudioManager audioManager];
    if (on && _decoder.validAudio) {
        audioManager.outputBlock = ^(float *data, UInt32 numFrames, UInt32 numChannels) {
            [self audioCallbackFillData:data numFrames:numFrames numChannels:numChannels];
        };
        
        [audioManager play];
    }else {
        
        [audioManager pause];
        audioManager.outputBlock = nil;
    }
}
- (void) audioCallbackFillData: (float *) outData
                     numFrames: (UInt32) numFrames
                   numChannels: (UInt32) numChannels
{
    
    if (_buffered) {
        memset(outData, 0, numFrames*numChannels*sizeof(float));
    }
    
    @autoreleasepool {
        
        while (numFrames>0) {
            if (!_currentAudioFrame) {
                @synchronized(_audioFrames) {
                    NSUInteger count = _audioFrames.count;
                    
                    if (count>0) {
                        KxAudioFrame *frame = _audioFrames[0];
                        
                        if (_decoder.validVideo) {
                            const CGFloat delta = _moviePosition - frame.position;
                            if (delta<-0.1) {
                                memset(outData, 0, numFrames*numChannels*sizeof(float));
                                
                                break;
                            }
                            
                            [_audioFrames removeObjectAtIndex:0];
                            
                            if (delta>0.1 && count>1) {
                                continue;
                            }
                        }else {
                            
                            [_audioFrames removeObjectAtIndex:0];
                            _moviePosition = frame.position;
                            _bufferedDuration -= frame.duration;
                        }
                        
                        _currentAudioFrame = frame.samples;
                        _currentAudioFramePos = 0;
                    }
                }
            }
            
            if (_currentAudioFrame) {
                const void *bytes = (Byte*)_currentAudioFrame.bytes+_currentAudioFramePos;
                const NSUInteger bytesLeft = (_currentAudioFrame.length - _currentAudioFramePos);
                const NSUInteger frameSizeOf = numChannels*sizeof(float);
                const NSUInteger bytesTOCopy = MIN(numFrames*frameSizeOf, bytesLeft);
                const NSUInteger framesToCopy = bytesTOCopy/frameSizeOf;
                
                memcpy(outData, bytes, bytesTOCopy);
                numFrames -= framesToCopy;
                outData += framesToCopy*numChannels;
                
                if (bytesTOCopy<bytesLeft) {
                    _currentAudioFramePos += bytesTOCopy;
                }else{
                    _currentAudioFrame = nil;
                }
            }else{
                
                memset(outData, 0, numFrames*numChannels*sizeof(float));
                break;
            }
        }
    }
}

-(void)tick {
    
    if (_buffered && ((_bufferedDuration>_minBufferedDuration) || _decoder.isEOF)) {
        _buffered = NO;
    }
    
    CGFloat interval = 0;
    if (!_buffered) {
        interval = [self presentFrame];
    }
    
    if (self.playing) {
        
        const NSUInteger leftFrames = (_decoder.validVideo ? _videoFrames.count : 0) +
        (_decoder.validAudio ? _audioFrames.count : 0);
        
        if (0 == leftFrames) {
            if (_decoder.isEOF) {
                [self pause];
                //[self updateHUD];
                return;
            }
            
            if (_minBufferedDuration>0 && !_buffered) {
                _buffered = YES;
            }
        }
        
        if (!leftFrames || !(_bufferedDuration>_minBufferedDuration)) {
            [self asyncDecodeFrames];
        }
        
        const NSTimeInterval correction = [self tickCorrection];
        const NSTimeInterval time = MAX(interval+correction, 0.01);
        dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, time * NSEC_PER_SEC);
        dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
            [self tick];
        });
    }
    
    if ((_tickCounter++ % 3) == 0) {
        //[self updateHUD];
    }
}

- (CGFloat) tickCorrection
{
    if (_buffered)
        return 0;
    
    const NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    
    if (!_tickCorrectionTime) {
        
        _tickCorrectionTime = now;
        _tickCorrectionPosition = _moviePosition;
        return 0;
    }
    
    NSTimeInterval dPosition = _moviePosition - _tickCorrectionPosition;
    NSTimeInterval dTime = now - _tickCorrectionTime;
    NSTimeInterval correction = dPosition - dTime;
    
    //if ((_tickCounter % 200) == 0)
    //    LoggerStream(1, @"tick correction %.4f", correction);
    
    if (correction > 1.f || correction < -1.f) {
        
        NSLog(@"tick correction reset %.2f", correction);
        correction = 0;
        _tickCorrectionTime = 0;
    }
    
    return correction;
}

-(CGFloat)presentFrame {
    
    CGFloat interval = 0;
    if (_decoder.validVideo) {
        KxVideoFrame *frame;
        @synchronized(_videoFrames) {
            if (_videoFrames.count>0) {
                frame = _videoFrames[0];
                [_videoFrames removeObjectAtIndex:0];
                _bufferedDuration -= frame.duration;
            }
        }
        
        if (frame) {
            interval = [self presentVideoFrame:frame];
        }
    }else if (_decoder.validAudio) {
        
        
    }
    
    return interval;
}

-(CGFloat)presentVideoFrame:(KxVideoFrame*)frame {
    
    if (_glView) {
        [_glView render:frame];
    }else {
        
        KxVideoFrameRGB *rgbFrame = (KxVideoFrameRGB*)frame;
        _imageView.image = [rgbFrame asImage];
    }
    
    _moviePosition = frame.position;
    
    return frame.duration;
}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}
@end
