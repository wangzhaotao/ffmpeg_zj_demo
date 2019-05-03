//
//  KxAudioManager.m
//  FFMPEG_PlayerDemo
//
//  Created by ocean on 2018/8/15.
//  Copyright © 2018年 ocean. All rights reserved.
//

#import "KxAudioManager.h"
#import <AudioToolbox/AudioToolbox.h>
#import <TargetConditionals.h>
#import <Accelerate/Accelerate.h>

#define MAX_FRAME_SIZE 4096
#define MAX_CHAN       2

///////////////////////////////
@interface KxAudioManagerImpl: KxAudioManager<KxAudioManager> {
    
    float                       *_outData;
    BOOL                        _activated;
    BOOL                        _initialized;
    AudioUnit                   _audioUnit;
    AudioStreamBasicDescription _outputFormat;
}
@property (readonly) UInt32             numOutputChannels;
@property (readonly) Float64            samplingRate;
@property (readonly) UInt32             numBytesPerSample;
@property (readwrite) Float32           outputVolume;
@property (readonly) BOOL               playing;
@property (readonly, strong) NSString   *audioRoute;

@property (readwrite, copy) KxAudioManagerOutputBlock outputBlock;
@property (readwrite) BOOL playAfterSessionEndInterruption;

- (BOOL) activateAudioSession;
- (void) deactivateAudioSession;
- (BOOL) play;
- (void) pause;

@end
//////////////////////////////


@implementation KxAudioManager

+(id<KxAudioManager>)audioManager {
    
    static KxAudioManagerImpl *audioManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        audioManager = [[KxAudioManagerImpl alloc]init];
    });
    return audioManager;
}

@end


///////////////////////////////
@implementation KxAudioManagerImpl
-(id)init {
    if (self = [super init]) {
        _outData = (float*)calloc(MAX_FRAME_SIZE*MAX_CHAN, sizeof(float));
        _outputVolume = 0.5;
    }
    return self;
}
-(void)dealloc {
    if (_outData) {
        free(_outData);
        _outData = NULL;
    }
}


#pragma mark private
-(BOOL)checkAudioRoute {
    
    UInt32 propertySize = sizeof(CFStringRef);
    CFStringRef route;
    if (checkError(AudioSessionGetProperty(kAudioSessionProperty_AudioRoute,
                                           &propertySize,
                                           &route),
                   "Can't check audio property")) {
        return NO;
    }
    return YES;
}
-(BOOL)setupAudio {
    
    UInt32 sessionCategory = kAudioSessionCategory_MediaPlayback;
    if (checkError(AudioSessionSetProperty(kAudioSessionProperty_AudioCategory,
                                           sizeof(sessionCategory),
                                           &sessionCategory),
                   "Couldn't set audio category")) {
        return NO;
    }
    
    if (checkError(AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange,
                                                   sessionPropertyListener,
                                                   (__bridge void*)(self)),
                   "Couldn't add audio session property listener")) {
        //just warning
    }
    
    if (checkError(AudioSessionAddPropertyListener(kAudioSessionProperty_CurrentHardwareOutputVolume,
                                                   sessionPropertyListener,
                                                   (__bridge void *)(self)),
                   "Couldn't add audio session property listener")) {
        //just warning
    }
    
#if !TARGET_IPHONE_SIMULATOR
    Float32 preferredBufferSize = 0.0232;
    if (checkError(AudioSessionSetProperty(kAudioSessionProperty_PreferredHardwareIOBufferDuration,
                                           sizeof(preferredBufferSize),
                                           &preferredBufferSize),
                   "Couldn't set the preferred buffer duration")) {
        //just warning
    }
#endif
    
    if (checkError(AudioSessionSetActive(YES),
                   "Couldn' activate the audio session")) {
        return NO;
    }
    
    [self checkSessionProperties];
    
    //Audio Unit setup
    AudioComponentDescription description = {0};
    description.componentType = kAudioUnitType_Output;
    description.componentSubType = kAudioUnitSubType_RemoteIO;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    
    //Get Component
    AudioComponent component = AudioComponentFindNext(NULL, &description);
    if (checkError(AudioComponentInstanceNew(component, &_audioUnit), "Couldn't create the output audio unit")) {
        return NO;
    }
    
    UInt32 size;
    //check the output stream format
    size = sizeof(AudioStreamBasicDescription);
    if (checkError(AudioUnitGetProperty(_audioUnit,
                                        kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Input,
                                        0,
                                        &_outputFormat, &size), "Couldbn't get the hardware output stream format")) {
        return NO;
    }
    
    _outputFormat.mSampleRate = _samplingRate;
    if (checkError(AudioUnitSetProperty(_audioUnit,
                                        kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Input, 0, &_outputFormat,
                                        &size), "Couldn,t set the hardware output stream output")) {
        //just warning
    }
    
    _numBytesPerSample = _outputFormat.mBitsPerChannel/8;
    _numOutputChannels = _outputFormat.mChannelsPerFrame;
    
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = renderCallback;
    callbackStruct.inputProcRefCon = (__bridge void *)(self);
    
    if (checkError(AudioUnitSetProperty(_audioUnit,
                                        kAudioUnitProperty_SetRenderCallback,
                                        kAudioUnitScope_Input,
                                        0, &callbackStruct, sizeof(callbackStruct)),
                   "Couldn't set the render callback on the audio unit")) {
        return NO;
    }
    
    if (checkError(AudioUnitInitialize(_audioUnit), "Couldn't initialize the audio unit")) {
        return NO;
    }
    return YES;
}
-(BOOL)checkSessionProperties {
    
    [self checkAudioRoute];
    
    UInt32 newNumChannels;
    UInt32 size = sizeof(newNumChannels);
    if (checkError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputNumberChannels,
                                           &size,
                                           &newNumChannels),
                   "Checking number of output channels")) {
        return NO;
    }
    
    size = sizeof(_samplingRate);
    if (checkError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareSampleRate,
                                           &size,
                                           &_samplingRate),
                   "Checking hardware sampling rate")) {
        return NO;
    }
    
    size = sizeof(_outputVolume);
    if (checkError(AudioSessionGetProperty(kAudioSessionProperty_CurrentHardwareOutputVolume,
                                           &size,
                                           &_outputVolume),
                   "Checking current hardware output volume")) {
        return NO;
    }
    
    return YES;
}

-(BOOL)renderFrames:(UInt32) numFrames ioData:(AudioBufferList*)ioData {
    
    /*
     void *memset(void *s, int ch, size_t n);
     函数解释：将s中当前位置后面的n个字节(typedef unsigned int size_t)用ch替换, 并返回s。
     */
    for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer) {
        memset(ioData->mBuffers[iBuffer].mData, 0, ioData->mBuffers[iBuffer].mDataByteSize);
    }
    
    //应用vDSP叠加算法
    if (_playing && _outputBlock) {
        
        _outputBlock(_outData, numFrames, _numOutputChannels);
        
        if (_numBytesPerSample == 4) {
            float zero = 0.0;
            for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer) {
                int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
                
                for (int iChannel=0; iChannel<thisNumChannels; ++iChannel) {
                    //相加
                    vDSP_vsadd(_outData+iChannel,
                               _numOutputChannels,
                               &zero,
                               (float*)ioData->mBuffers[iBuffer].mData,
                               thisNumChannels,
                               numFrames);
                }
            }
        }else if (_numBytesPerSample == 2) {
            float scale = (float)INT16_MAX;
            //相乘
            vDSP_vsmul(_outData,
                       1,
                       &scale,
                       _outData,
                       1,
                       numFrames*_numOutputChannels);
            
            for (int iBuffer=0; iBuffer<ioData->mNumberBuffers; ++iBuffer) {
                int thisNumChannels = ioData->mBuffers[iBuffer].mNumberChannels;
                
                for (int iChannel=0; iChannel<thisNumChannels; ++iChannel) {
                    //转回byte
                    vDSP_vfix16(_outData+iChannel,
                                _numOutputChannels,
                                (SInt16*)ioData->mBuffers[iBuffer].mData+iChannel,
                                thisNumChannels,
                                numFrames);
                }
            }
            
        }
    }
    
    return noErr;
}


#pragma mark public
-(BOOL)activateAudioSession {
    
    if (!_activated) {
        if (!_initialized) {
            if (checkError(AudioSessionInitialize(NULL,
                                                  kCFRunLoopDefaultMode,
                                                  sessionInterruptionListener,
                                                  (__bridge void *)(self)),
                           "Couldn't initialize audio session")) {
                return NO;
            }
            _initialized = YES;
        }
    }
    
    if ([self checkAudioRoute]) {
        
        [self setupAudio];
        
        _activated = YES;
    }
    
    return _activated;
}

-(BOOL)play {
    
    if (!_playing) {
        if ([self activateAudioSession]) {
            _playing = !checkError(AudioOutputUnitStart(_audioUnit), "Couldn't start the output unit.");
        }
    }
    
    return _playing;
}
-(void)pause {
    
    if (_playing) {
        _playing = checkError(AudioOutputUnitStop(_audioUnit),
                              "Couldn't stop the output unit");
    }
}

#pragma mark callbacks
static void sessionPropertyListener(void *inClientData,
                                    AudioSessionPropertyID inID,
                                    UInt32 inDataSize,
                                    const void *inData) {
    KxAudioManagerImpl *sm = (__bridge KxAudioManagerImpl*)inClientData;
    
    if (inID == kAudioSessionProperty_AudioRouteChange) {
        if ([sm checkAudioRoute]) {
            [sm checkSessionProperties];
        }
    }else if (inID == kAudioSessionProperty_CurrentHardwareOutputVolume) {
        if (inData && inDataSize==4) {
            sm.outputVolume = *(float*)inData;
        }
    }
}
static void sessionInterruptionListener(void *inClientData, UInt32 inInterruption) {
    
    KxAudioManagerImpl *sm = (__bridge KxAudioManagerImpl *)inClientData;
    if (inInterruption == kAudioSessionBeginInterruption) {
        sm.playAfterSessionEndInterruption = sm.playing;
    }else if (inInterruption == kAudioSessionEndInterruption) {
        if (sm.playAfterSessionEndInterruption) {
            sm.playAfterSessionEndInterruption = NO;
            [sm playing];
        }
    }
}

static OSStatus renderCallback(void                       *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp       *inTimeStamp,
                               UInt32                     inOutputBusNumber,
                               UInt32                     inNumberFrames,
                               AudioBufferList            *ioData)
{
    KxAudioManagerImpl *sm = (__bridge KxAudioManagerImpl*)inRefCon;
    return [sm renderFrames:inNumberFrames ioData:ioData];
}

static BOOL checkError(OSStatus error, const char *operation) {
    if (error == noErr) {
        return NO;
    }
    
    return YES;
}




@end
///////////////////////////////


