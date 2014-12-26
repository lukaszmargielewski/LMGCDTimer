//
//  LMGCDWatchdog.h
//  FF
//
//  Created by Lukasz Margielewski on 10/12/2014.
//
//

#import <Foundation/Foundation.h>

@class LMGCDWatchdog;

@protocol LMGCDWatchdogDelegate <NSObject>

-(void)LMGCDWatchdogDidDetectLongerDeadlock:(LMGCDWatchdog *)watchdog;
-(void)LMGCDWatchdog:(LMGCDWatchdog *)watchdog deadlockDidFinishWithduration:(double)duration;

@end

@interface LMGCDWatchdog : NSObject

@property (nonatomic, readonly) dispatch_queue_t queue;
@property (nonatomic) float cpuUsagePercent;
@property (nonatomic, strong) NSString *threadsStackTrace;

@property (nonatomic, assign) id<LMGCDWatchdogDelegate>delegate;

+(instancetype)singleton;

#pragma mark - Watchdog:

-(void)stopWatchDog;
-(void)startWatchDog;


@end
