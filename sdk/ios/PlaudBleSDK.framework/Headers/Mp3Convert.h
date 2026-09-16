//
//  Mp3Convert.h
//  PenBleSDK
//
//  Created by 天诺泰 on 2019/8/16.
//  Copyright © 2019 天诺泰. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Mp3Convert : NSObject

+ (instancetype)shared;

//+ (void)jx_swap:(int *)a :(int *)b;
/// 生成声波
/// @param avcPath 原始文件路径
/// @param channels 声道数
/// @param callback 回调，每秒一个分贝值
- (void)generateSoundWave:(NSString *)avcPath
                 channels:(int)channels
                 callback:(void(^)(int second, int secVolume))callback;

/// 生成音乐模式下wav的声波
/// @param wavPath wav文件
/// @param channels 声道数
/// @param simpleRate 采样率
/// @param callback 回调，每秒一个分贝值
- (void)generateSoundWave:(NSString *)wavPath
                 channels:(int)channels
               simpleRate:(int)simpleRate
                 callback:(void(^)(int second, int secVolume))callback;

/// 取消生成声波的任务
- (void)generateSoundWaveCancel;

/// avc转pcm
/// @param avcPath 原始文件路径
/// @param pcmPath 目标文件路径
/// @param channels 声道数
/// @param ns_agc 是否降噪增益
/// @param callback 进度回调
- (void)convertAvc:(NSString *)avcPath
             toPcm:(NSString *)pcmPath
          channels:(int)channels
            ns_agc:(BOOL)ns_agc
          callback:(void(^)(int64_t curPos))callback;

/// ogg转pcm
/// @param oggPath ogg文件路径
/// @param pcmPath pcm文件路径
/// @param channels 声道数
/// @param ns_agc 是否降噪增益
/// @param callback 进度回调
- (void)convertOgg:(NSString *)oggPath
             toPcm:(NSString *)pcmPath
          channels:(int)channels
            ns_agc:(BOOL)ns_agc
          callback:(void(^)(int64_t curPos))callback;

/// pcm转mp3
/// @param pcmPath pcm文件路径
/// @param mp3Path mp3文件路径
/// @param quality 音质质量(默认选7) 2 near-best quality, not too slow；5 good quality, fast； 7 ok quality, really fast
/// @param channels 声道数
/// @param callback 进度回调
- (void)convertPcm:(NSString *)pcmPath
             toMp3:(NSString *)mp3Path
           quality:(int)quality
          channels:(int)channels
          callback:(void(^)(int64_t curPos))callback;


/// avc转mp3
/// @param avcPath 原始未解码文件路径
/// @param mp3Path mp3文件路径
/// @param quality mp3音质 2 near-best quality, not too slow；5 good quality, fast；7 ok quality, really fast 默认7
/// @param channels 声道数
/// @param ns_agc 是否要做降噪增益？（笔端如果做了app就不用做）
/// @param callback 回调进度（已处理文件偏移量）
- (void)convertAvc:(NSString *)avcPath
             toMp3:(NSString *)mp3Path
           quality:(int)quality
          channels:(int)channels
            ns_agc:(BOOL)ns_agc
          callback:(void(^)(int64_t curPos))callback;

/// ogg转mp3
/// @param oggPath ogg文件路径
/// @param mp3Path 待生成的mp3文件路径
/// @param quality mp3音质 2 near-best quality, not too slow；5 good quality, fast；7 ok quality, really fast 默认7
/// @param channels ogg声道数
/// @param ns_agc 是否要做降噪增益？(@see BleDevice)
/// @param callback 回调进度（已处理文件偏移量）
- (void)convertOgg:(NSString *)oggPath
             toMp3:(NSString *)mp3Path
           quality:(int)quality
          channals:(int)channels
            ns_agc:(BOOL)ns_agc
          callback:(void(^)(int64_t curPos))callback;


/// avc转wave
/// @param avcPath 原始未解码文件路径
/// @param wavePath wave文件路径
/// @param channels 声道数
/// @param simpleRate  采样率，16000（16k）、48000（48k）
/// @param ns_agc 是否要做降噪增益？（笔端如果做了app就不用做）
/// @param callback 回调进度（已处理文件偏移量）
- (void)convertAvc:(NSString *)avcPath
            toWave:(NSString *)wavePath
          channels:(int)channels
        simpleRate:(uint32_t)simpleRate
            ns_agc:(BOOL)ns_agc
          callback:(void(^)(int64_t curPos))callback;

/// avc 转降噪 wave
/// @param avcPath 原始未解码文件路径
/// @param wavePath wave文件路径
/// @param channels 声道数
/// @param simpleRate  采样率，16000（16k）、48000（48k）
/// @param soundPlus 是否要做降噪增益？（笔端如果做了app就不用做）
/// @param callback 回调进度（已处理文件偏移量）
- (void)convertAvc:(NSString *)avcPath
            toNoiseReductionWave:(NSString *)wavePath
          channels:(int)channels
        simpleRate:(uint32_t)simpleRate
         soundPlus:(BOOL)soundPlus
noiseReductionGain:(int)gain
          callback:(void(^)(int64_t curPos))callback;


/// 取消avcToPcm的任务
- (void)convertAvcToPcmCancel;
/// 取消压缩PcmToMp3的任务
- (void)convertPcmToMp3Cancel;
/// 取消压缩AvcToMp3的任务
- (void)convertAvcToMp3Cancel;
/// 取消ogg转mp3的任务
- (void)convertOggToMp3Cancel;

/// 取消ogg转pcm的任务
- (void)convertOggToPcmCancel;
/// 取消压缩AvcToWav的任务
- (void)convertAvcToWavCancel;
/// 取消压缩AvcToNoiseReductionWav的任务
- (void)convertAvcToNoiseReductionWavCancel;
@end

NS_ASSUME_NONNULL_END
