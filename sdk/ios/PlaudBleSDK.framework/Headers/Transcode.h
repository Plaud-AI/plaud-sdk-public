//
//  Transcode.h
//  PenBleSDK
//
//  Created by 天诺泰 on 2018/11/12.
//  Copyright © 2018 天诺泰. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface Transcode : NSObject

@property (nonatomic, assign) BOOL isProjectJT;

+ (instancetype _Nonnull)shared;


+ (double)volume:(NSData *)pcmData buff:(short [80*4])buff;
+ (double)volume:(NSData *)pcmData;


/// pcm转wav
+ (void)translatePcmFile:(NSString *)pcmPath toWavFile:(NSString *)wavPath withChannels:(uint32_t)channels simpleRate:(uint32_t)simpleRate;

/// 生成Wav头信息
+ (NSData *)generateWavHeaderWithPcmLen:(uint32_t)pcmLen channels:(uint32_t)channels sampleRate:(uint32_t)sampleRate;

/// 获取文件的crc
+ (uint16_t)getCrc:(NSString *)filePath;
/// 检查文件的crc
+ (BOOL)checkCrc:(uint16_t)crc withFile:(NSString *)filePath;

/**
 分离双声道wave文件为左右声道两个文件

 @param wavePath wave文件路径
 @param leftPath 左声道文件路径
 @param rightPath 右声道文件路径
 @param handle block回调
 */
+ (void)divide:(NSString *)wavePath toLeft:(NSString *)leftPath andRight:(NSString *)rightPath handle:(void(^_Nullable)(void))handle;

/// 获取偏移量地址
long calculate(void);


@end

NS_ASSUME_NONNULL_END

