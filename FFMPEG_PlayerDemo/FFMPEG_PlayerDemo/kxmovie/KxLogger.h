//
//  KxLogger.h
//  kxmovie
//
//  Created by Mathieu Godart on 01/05/2014.
//
//

#ifndef kxmovie_KxLogger_h
#define kxmovie_KxLogger_h

/**
 * Place global headers in extradata instead of every keyframe.
 */
#define AV_CODEC_FLAG_GLOBAL_HEADER   (1 << 22)
/**
 * Place global headers in extradata instead of every keyframe.
 */
#define AV_CODEC_FLAG_GLOBAL_HEADER   (1 << 22)

// 缓存主目录
#define LVDCachesDirectory [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) lastObject]// stringByAppendingPathComponent:@"LocalVideo"]

// 保存文件名
#define LVDFileName(url) [url stringByAppendingString:@".mp4"]

// 文件的存放路径（caches）
#define LVDFileFullpath(url) [LVDCachesDirectory stringByAppendingPathComponent:LVDFileName(url)]



#define Screen_Width  [UIScreen mainScreen].bounds.size.width
#define Screen_Height [UIScreen mainScreen].bounds.size.height

//#define DUMP_AUDIO_DATA

#ifdef DEBUG
#ifdef USE_NSLOGGER

#    import "NSLogger.h"
#    define LoggerStream(level, ...)   LogMessageF(__FILE__, __LINE__, __FUNCTION__, @"Stream", level, __VA_ARGS__)
#    define LoggerVideo(level, ...)    LogMessageF(__FILE__, __LINE__, __FUNCTION__, @"Video",  level, __VA_ARGS__)
#    define LoggerAudio(level, ...)    LogMessageF(__FILE__, __LINE__, __FUNCTION__, @"Audio",  level, __VA_ARGS__)

#else

#    define LoggerStream(level, ...)   NSLog(__VA_ARGS__)
#    define LoggerVideo(level, ...)    NSLog(__VA_ARGS__)
#    define LoggerAudio(level, ...)    NSLog(__VA_ARGS__)

#endif
#else

#    define LoggerStream(...)          while(0) {}
#    define LoggerVideo(...)           while(0) {}
#    define LoggerAudio(...)           while(0) {}

#endif

#endif
