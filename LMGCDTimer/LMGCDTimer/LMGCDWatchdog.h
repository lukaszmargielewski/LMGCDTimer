//
//  LMGCDWatchdog.h
//  FF
//
//  Created by Lukasz Margielewski on 10/12/2014.
//
//

#import <Foundation/Foundation.h>

#define D_MIN 60.0
#define D_HOUR D_MIN * 60.0
#define D_DAY D_HOUR * 24.0


typedef void(^VoidBlock)();


#pragma mark - GCD:


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

-(void)LMGCDWatchdogDidDetectLongerDeadlock:(LMGCDWatchdog *)watchdog cpuUsagePercent:(float)cpuUsagePercent;
-(void)LMGCDWatchdog:(LMGCDWatchdog *)watchdog deadlockDidFinishWithduration:(double)duration;
-(void)LMGCDWatchdog:(LMGCDWatchdog *)watchdog didDetectThreadStateChange:(NSString *)threadStateChangeInfo;

@end

@interface LMGCDWatchdog : NSObject
@property (nonatomic, readonly) dispatch_queue_t queue;
@property (nonatomic, assign) id<LMGCDWatchdogDelegate>delegate;
@property (nonatomic) int monitorThreadChangesAboveThreadCount;

@property (nonatomic) NSTimeInterval deadlockCheckTimeInterval;
@property (nonatomic) NSTimeInterval threadsCheckTimeInterval;
@property (nonatomic, strong) NSString *userId;
@property (nonatomic, strong) NSString *userEmail;
@property (nonatomic, strong) NSString *userName;

@property (nonatomic, readonly) NSTimeInterval watchdogTimeInterval;

+(instancetype)singleton;

#pragma mark - Watchdog:

-(void)stopWatchDog;
-(void)startWatchDogWithTimeInterval:(NSTimeInterval)timeInterval userId:(NSString *)userId userName:(NSString *)userName contactEmail:(NSString *)contactEmail;

-(float)cpuInfo;

@end

#pragma mark - GCD:

static inline void watch_disp_async(NSString *name, dispatch_queue_t queue, VoidBlock block)
{

    dispatch_async(queue, block);
    return;

    if (!name) {
        
        NSArray *stack = [NSThread callStackSymbols];
        name = (stack && stack.count > 1) ? stack[1] : @"sync ???";
    }
    
    
    dispatch_async(queue, ^{
        
        block();
    });
    
    
    
    
}
static inline void watch_disp_sync(NSString *name, dispatch_queue_t queue, VoidBlock block)
{
    
    dispatch_sync(queue, block);
    return;
    
    if (!name) {
        
        NSArray *stack = [NSThread callStackSymbols];
        name = (stack && stack.count > 1) ? stack[1] : @"sync ???";
    }
    
    dispatch_sync(queue, ^{
        
        block();
        
    });
    
    
}

