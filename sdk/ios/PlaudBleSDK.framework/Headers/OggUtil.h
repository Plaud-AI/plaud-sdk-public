//
//  OggUtil.h
//  PenBleSDK
//
//  Created by 天诺泰 on 2019/10/22.
//  Copyright © 2019 天诺泰. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OggUtil : NSObject

+ (instancetype)shared;

/// 生成声波
/// @param oggPath 原始文件路径
/// @param channels 声道数
/// @param callback 回调，每秒一个分贝值
- (void)generateSoundWave:(NSString *)oggPath
                 channels:(int)channels
                 callback:(void(^)(int second, int secVolume, int progress))callback;

/// 取消生成声波的任务
- (void)generateSoundWaveCancel;


///  封装ogg
/// @param avcPath  opus压缩文件路径
/// @param oggPath  目标ogg文件路径
/// @param cutOut   是否截取？（讯飞的离线识别虽然说是5个小时，但是好像只能传4小时59分50秒的样子）
/// @param channels 声道数(源数据声道）
/// @param targetChannels 目标声道（单声道还是双声道？双声道可以只获取单声道的，语音识别的一般只支持单声道；双声道转双声道有点问题，声音不好）
/// @param ns_agc 做降噪、增益
/// @param callback  回调
- (void)convertAvc:(NSString *)avcPath
             toOgg:(NSString *)oggPath
            cutOut:(BOOL)cutOut
          channels:(int32_t)channels
    targetChannels:(int32_t)targetChannels
            ns_agc:(BOOL)ns_agc
          callback:(void(^)(int64_t curPos))callback;

/// 取消转码任务
- (void)convertCancel;

///提取pcm纯数据
- (void)convertOgg:(NSString *)oggPath
            toOpus:(NSString *)opusPath
          channels:(int32_t)channels
          callback:(void(^)(Boolean completed))callback;

/// 单、双声道ogg转单声道ogg
/// @param originPath 双声道ogg（必须是从录音笔直接获取的，其他格式不支持）
/// @param singlePath 目标单声道ogg
/// @param callback 进度回调
- (void)convertOgg:(NSString *)originPath
          toSingle:(NSString *)singlePath
          channels:(int32_t)channels
          callback:(void(^)(int64_t curPos))callback;


/// 四声道ogg转单声道ogg
/// @param originPath 四声道ogg（必须是从录音笔直接获取的，其他格式不支持）
/// @param singlePath 目标单声道ogg
/// @param callback 进度回调
- (void)convertFourChannelOgg:(NSString *)originPath
                     toSingle:(NSString *)singlePath
                     callback:(void(^)(int64_t curPos))callback;



@end

NS_ASSUME_NONNULL_END
