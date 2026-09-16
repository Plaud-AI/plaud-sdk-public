//
//  JXAvcFilePlayer.h
//  PenBleSDK
//
//  Created by 天诺泰 on 2019/5/21.
//  Copyright © 2019 天诺泰. All rights reserved.
//

#import <Foundation/Foundation.h>

@protocol JXAvcFilePlayerDelegate <NSObject>
/// 播放状态改变
- (void)onStateChanged:(BOOL)isPlaying;
/// 播放进度（秒）
- (void)onPlayLocation:(double)seconds;

@end

/// avc/opus文件播放器
/// @deprecated 废弃，请使用JXOggPlayer
@interface JXAvcFilePlayer : NSObject

@property (nonatomic, weak) id<JXAvcFilePlayerDelegate>    delegate;
@property (nonatomic, assign) BOOL isPrepared;
@property (nonatomic, strong) NSString *filePath;   //文件路径
@property (nonatomic, assign) NSInteger fileSize;   //文件大小
@property (nonatomic, assign) NSInteger curOffset;  //当前播放文件偏移量

+ (instancetype)shared;
/// 是否开启降噪、增益
- (void)openNsAgc:(BOOL)open;

/// 是否开启声加降噪
- (void)openSoundPlusNs:(BOOL)open;

/// 设置avc文件路径
- (void)setAudioPath:(NSString *)avcPath numerOfChannel:(int)channels;

/// 开始播放
- (void)play;
/// 播放速率
- (void)setPlayRate:(Float32)rate;
/// 跳到某个位置
- (void)seekTo:(NSTimeInterval)seconds;
/// 暂停播放
- (void)pause;
/// 结束播放
- (void)stop;
///是否正在播放
- (BOOL)isPlaying;
///播放到的毫秒值
- (NSInteger)curMillisec;
///总时长
- (double)duration;

@end
