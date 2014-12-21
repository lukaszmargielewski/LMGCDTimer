//
//  LMGCDTimer.h
//  FF
//
//  Created by Lukasz Margielewski on 16/12/2014.
//
//

#import <Foundation/Foundation.h>

@interface LMGCDTimer : NSObject

@property (nonatomic, strong) NSString *name;

@property (nonatomic) NSTimeInterval interval;
@property (nonatomic, readonly) NSTimeInterval duration;

@property (nonatomic, readonly) NSTimeInterval leeway;

@property (nonatomic, readonly) BOOL repeat;
@property (nonatomic, readonly) BOOL immidiate;

@property (nonatomic, strong, readonly) dispatch_queue_t queue;
@property (nonatomic, strong, readonly) dispatch_source_t dispatchSource;

@property (nonatomic, readonly) BOOL running;


+(instancetype)timerWithInterval:(NSTimeInterval)interval duration:(NSTimeInterval)duration leeway:(NSTimeInterval)leeway repeat:(BOOL)repeat startImmidiately:(BOOL)immidiate queue:(dispatch_queue_t)queue block:(void(^)())block;

-(void)pause;
-(void)resume;

-(void)invalidate;

@end