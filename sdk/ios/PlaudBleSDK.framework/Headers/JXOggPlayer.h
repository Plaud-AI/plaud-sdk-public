//
//  JXOggPlayer.h
//  PenBleSDK
//
//  Created by 天诺泰 on 2021/5/31.
//  Copyright © 2021 天诺泰. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@protocol JXOggPlayerDelegate <NSObject>

/// 播放状态改变
- (void)onStateChanged:(BOOL)isPlaying;
/// 播放进度（秒）
- (void)onPlayingLocation:(double)seconds;

@end

/// 直接播放录音笔ogg文件的类
@interface JXOggPlayer : NSObject

@property (nonatomic, weak) id<JXOggPlayerDelegate>    delegate;
@property (nonatomic, assign, readonly) BOOL isPrepared;
/// 文件路径，不要直接操作
@property (nonatomic, strong, readonly) NSString *filePath;
/// 文件总大小
@property (nonatomic, assign, readonly) NSInteger fileSize;
/// 录音文件总时长（单位毫秒）
@property (nonatomic, assign, readonly) NSInteger totalMillsec;
/// 录音当前播放进度（单位毫秒）
@property (nonatomic, assign, readonly) NSInteger curMillsec;

+ (instancetype)shared;

/// 设置ogg文件路径和音频声道数
/// @param oggPath ogg文件路径
/// @param channel 声道数
- (void)setOggPath:(NSString *)oggPath withChannel:(int)channel;

/// 设置opus文件路径和音频声道数
/// @param opusPath opus纯音频未解码数据文件路径
/// @param channel 声道数
- (void)setOpusPath:(NSString *)opusPath withChannel:(int)channel;

/// 设置 pcm 文件路径和音频声道数
/// @param pcmPath pcm 数据文件路径
/// @param channel 声道数
- (void)setPCMPath:(NSString *)pcmPath withChannel:(int)channel;

/// 是否开启降噪、增益（仅单声道）
- (void)openNsAgc:(BOOL)open;

/// 设置是否启用 Plaud 算法降噪（基于 plaud_algo，按 256 帧处理，16k 单声道）
- (void)setPlaudAlgo:(BOOL)enabled;

/// 开始播放
- (void)play;

/// 设置倍速播放
/// @param rate 播放倍率
- (void)setPlayRate:(Float32)rate;
/// 跳到某个位置；因为会清空音频队列，跳转后需要手动恢复播放
/// @param seconds 单位秒
- (void)seekTo:(NSTimeInterval)seconds;

/// 跳到某个位置；因为会清空音频队列，跳转后需要手动恢复播放
/// @param millSec 单位 毫秒
- (void)seekToMillSec:(NSTimeInterval)millSec;

/// 暂停播放
- (void)pause;
/// 结束播放
- (void)stop;
///是否正在播放
- (BOOL)isPlaying;


@end

NS_ASSUME_NONNULL_END
