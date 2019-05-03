//
//  KxMovieViewController.h
//  FFMPEG_PlayerDemo
//
//  Created by ocean on 2018/8/15.
//  Copyright © 2018年 ocean. All rights reserved.
//

#import <UIKit/UIKit.h>

extern NSString * const KxMovieParameterMinBufferedDuration;    // Float
extern NSString * const KxMovieParameterMaxBufferedDuration;    // Float
extern NSString * const KxMovieParameterDisableDeinterlacing;   // BOOL

@interface KxMovieViewController : UIViewController

+ (id) movieViewControllerWithContentPath: (NSString *) path
                               parameters: (NSDictionary *) parameters;

@property (readonly) BOOL playing;

-(void)play;
-(void)pause;

@end
