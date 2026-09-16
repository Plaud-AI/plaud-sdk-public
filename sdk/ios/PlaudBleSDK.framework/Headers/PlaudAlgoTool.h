//
//  PlaudAlgoTool.h
//  PenBleSDK
//
//  Created for PlaudAlgo wrapper.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PlaudAlgoTool : NSObject

+ (instancetype)shared;

/// 是否启用 PlaudAlgo 处理
@property (nonatomic, assign) BOOL enabled;

/// 初始化算法（如有需要可重复调用保证幂等）
- (void)setup;

/// 处理 PCM int16 数据，要求 length 为采样点数（每点 2 字节），内部按 256 帧切片
- (NSData *)processInt16:(int16_t *)input length:(int)length;

/// 处理 WAV 文件，inputPath 为 16k/16bit/mono 的 WAV，输出 WAV
- (BOOL)processWavFile:(NSString *)inputPath
        outputPath:(NSString *)outputPath
          progress:(void (^)(float progress))progressCallback;

/// 处理裸 PCM 文件，输入/输出均为 16k/16bit/mono 的 PCM
- (BOOL)processPcmFile:(NSString *)inputPath
            outputPath:(NSString *)outputPath
              progress:(void (^)(float progress))progressCallback;

/// 获取底层算法版本号
- (NSInteger)version;

@end

NS_ASSUME_NONNULL_END

