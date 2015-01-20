//
//  LMGCDWatchdog.h
//  FF
//
//  Created by Lukasz Margielewski on 10/12/2014.
//
//

#import <Foundation/Foundation.h>

@interface LMGCDWatchdogStruct : NSObject{

    dispatch_queue_t    dispatchQueue;
    NSOperationQueue    *operationQueue;
    BOOL                blocked;
    int64_t             timeStart;
    NSThread            *nsthread;
    pthread_t           pthread;
    
}

@end

    
@class LMGCDWatchdog;

@protocol LMGCDWatchdogDelegate <NSObject>

-(void)LMGCDWatchdogDidDetectLongerDeadlock:(LMGCDWatchdog *)watchdog stackTrace:(NSString *)stackTrace cpuUsagePercent:(float)cpuUsagePercent;
-(void)LMGCDWatchdog:(LMGCDWatchdog *)watchdog deadlockDidFinishWithduration:(double)duration;
-(void)LMGCDWatchdog:(LMGCDWatchdog *)watchdog didDetectThreadStateChange:(NSString *)threadStateChangeInfo;

@end

@interface LMGCDWatchdog : NSObject
@property (nonatomic, readonly) dispatch_queue_t queue;
@property (nonatomic, assign) id<LMGCDWatchdogDelegate>delegate;

+(instancetype)singleton;

#pragma mark - Watchdog:

-(void)stopWatchDog;
-(void)startWatchDog;

-(float)cpuInfo;

@end
