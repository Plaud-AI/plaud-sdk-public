//
//  JXWebSocketServer.h
//  PenBleSDK
//
//  Created by 天诺泰 on 2019/12/13.
//  Copyright © 2019 天诺泰. All rights reserved.
//

#import <Foundation/Foundation.h>


NS_ASSUME_NONNULL_BEGIN

@protocol JXWebSocketServerDelegate <NSObject>

- (void)serverDidStart;
- (void)serverDidFailWithError:(NSError *)error;
- (void)serverDidStop;

- (void)clientDidOpen;
- (void)clientDidReceiveText:(NSString *)text;
- (void)clientDidReceiveData:(NSData *)data;
- (void)clientDidFailWithError:(NSError *)error;
- (void)clientDidCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean;

@end

@interface JXWebSocketServer : NSObject

#pragma mark - Properties

@property (nonatomic, weak) id <JXWebSocketServerDelegate> delegate;

#pragma mark - Actions

- (void)startListen:(NSInteger)port;
- (void)sendText:(NSString *)text;
- (void)sendData:(NSData *)data;
- (void)closeClient;
- (void)close;

@end

NS_ASSUME_NONNULL_END
