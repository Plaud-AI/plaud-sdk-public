//
//  NsAgcUtil.h
//  PenBleSDK
//
//  Created by 天诺泰 on 2020/2/24.
//  Copyright © 2020 天诺泰. All rights reserved.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NsAgcUtil : NSObject

- (nullable NSData *)process:(NSData *)pcmData channesl:(int)channels;

- (void)procress:(int16_t *)input channels:(int)channels;

@end

NS_ASSUME_NONNULL_END
