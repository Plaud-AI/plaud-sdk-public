//
//  JXOpusDecoder.h
//  PenBleSDK
//
//  Created by 天诺泰 on 2019/8/15.
//  Copyright © 2019 天诺泰. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface JXOpusDecoder : NSObject

/// 初始化解码器
/// @param channels 声道数，1，2，4
- (instancetype)initWithChannels:(int)channels;

///  解码数据·
/// @param avcData 数据，单声道包大小是80，双声道包大小是160，四声道是320
- (nullable NSData *)decode:(NSData *)avcData;

@end

NS_ASSUME_NONNULL_END
