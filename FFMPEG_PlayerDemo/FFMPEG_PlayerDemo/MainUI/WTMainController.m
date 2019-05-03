//
//  WTMainController.m
//  FFMPEG_PlayerDemo
//
//  Created by ocean on 2018/8/15.
//  Copyright © 2018年 ocean. All rights reserved.
//

#import "WTMainController.h"
#import "KxMovieViewController.h"


@interface WTMainController ()
- (IBAction)playBtnAction:(UIButton *)sender;
@property (weak, nonatomic) IBOutlet UIButton *playBtn;

@end

@implementation WTMainController

- (void)viewDidLoad {
    [super viewDidLoad];
    //
    
    NSLog(@"View Did Load 1");

    NSLog(@"View Did Load 2");
    
}

- (IBAction)playBtnAction:(UIButton *)sender {
    
    NSString *path = @"rtmp://live.hkstv.hk.lxdns.com/live/hks";
    path = @"rtmp://pull-g.kktv8.com/livekktv/100987038";
    path = @"http://media.fantv.hk/m3u8/archive/channel2_stream1.m3u8";
    NSDictionary *parameters = @{@"KxMovieParameterDisableDeinterlacing":@"1"};
    KxMovieViewController *vc = [KxMovieViewController movieViewControllerWithContentPath:path
                                                                               parameters:parameters];
    //[self presentViewController:vc animated:YES completion:nil];
    [self.navigationController pushViewController:vc animated:YES];
}


- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
}

@end
