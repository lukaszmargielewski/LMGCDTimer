//
//  LMGCDTimer.m
//  FF
//
//  Created by Lukasz Margielewski on 16/12/2014.
//
//

#import "LMGCDTimer.h"
#import "LMGCDWatchdog.h"

@implementation LMGCDTimer{
    
    dispatch_time_t _start_time_in_nano;
    dispatch_time_t _interval_in_nano;
    
    dispatch_time_t _end_time_in_nano;
    dispatch_time_t _duration_in_nano;
    
    
}
@synthesize name = _name;
@synthesize interval = _interval;
@synthesize dispatchSource = _dispatchSource;
@synthesize queue = _queue;
@synthesize repeat = _repeat;
@synthesize running = _running;
@synthesize immidiate = _immidiate;

+(instancetype)timerWithInterval:(NSTimeInterval)interval duration:(NSTimeInterval)duration leeway:(NSTimeInterval)leeway repeat:(BOOL)repeat startImmidiately:(BOOL)immidiate queue:(dispatch_queue_t)queue block:(void(^)())block{
    
    LMGCDTimer *timer = [[LMGCDTimer alloc] initWithInterval:interval duration:duration leeway:leeway repeat:repeat startImmidiately:immidiate queue:queue block:block];
    return timer;
}

-(id)init{

    NSAssert(NO, @"direct init not allowed. Use initWithInterval:.... instead");
    return nil;
}
-(id)initWithInterval:(NSTimeInterval)interval duration:(NSTimeInterval)duration leeway:(NSTimeInterval)leeway repeat:(BOOL)repeat startImmidiately:(BOOL)immidiate queue:(dispatch_queue_t)queue block:(void(^)())block{
    
    NSAssert(queue != nil && queue != NULL, @"LMGCDTimer queue must not be nil");
    NSAssert(block != nil, @"LMGCDTimer block must not be nil");
    
    self = [super init];
    
    if (self) {
        
        _dispatchSource = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        
        _leeway = leeway;
        _queue = queue;
        _repeat = repeat;
        _immidiate = immidiate;
        _duration = duration;
        _name = @"noname";
        
        _duration_in_nano = _duration*NSEC_PER_SEC;
        _end_time_in_nano = dispatch_time(_start_time_in_nano, _duration_in_nano);
        
        self.interval = interval;
        
        
        __weak LMGCDTimer *weakSelf = self;
        
        if (!_repeat || duration > 0) {
            
            void (^timerBlock)(void) = ^{
        
                block();
                
                dispatch_time_t now = dispatch_time(DISPATCH_TIME_NOW, 0);
                
                if (!_repeat || now > _end_time_in_nano) {
            
                    [weakSelf invalidate];
                }
            };
            
            dispatch_source_set_event_handler(_dispatchSource, timerBlock);
            
        }else{
            
            dispatch_source_set_event_handler(_dispatchSource, block);
        }
        
        [self resume];
        
    }
    return self;
}

-(void)setInterval:(NSTimeInterval)interval{

    _interval = interval;
    _interval_in_nano  = _interval*NSEC_PER_SEC;
    _start_time_in_nano    = (_immidiate) ? dispatch_time(DISPATCH_TIME_NOW, 0) : dispatch_time(DISPATCH_TIME_NOW, _interval_in_nano);
    
    // Create a dispatch source that'll act as a timer:
    dispatch_source_set_timer(_dispatchSource, _start_time_in_nano, _repeat ? _interval_in_nano : DISPATCH_TIME_FOREVER, _leeway*NSEC_PER_SEC);
    
}

-(void)pause{

    if (_running) {
        _running = NO;
        dispatch_suspend(_dispatchSource);
    }
}
-(void)resume{

    if (!_running) {
        _running = YES;
        dispatch_resume(_dispatchSource);
    }
}

-(void)dealloc{
    
    [self invalidate];
}

-(void)invalidate{
    
    //MILogInfo(@"%@ invalidating", _name);
    if (_running) {
        _running = NO;
        //MILogInfo(@"%@ invalidated", _name);
        dispatch_source_cancel(_dispatchSource);
    }
}


@end
