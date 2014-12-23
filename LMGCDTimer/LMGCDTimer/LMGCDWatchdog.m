//
//  LMGCDWatchdog.m
//  FF
//
//  Created by Lukasz Margielewski on 10/12/2014.
//
//

#import "LMGCDWatchdog.h"
#import "LMGCDTimer.h"

#include <sys/sysctl.h>
#include <sys/types.h>
#include <mach/mach.h>
#include <mach/processor_info.h>
#include <mach/mach_host.h>

#include <signal.h>
#include <pthread.h>
#include <execinfo.h>
#include <stdio.h>
#include <stdlib.h>

#import "KSMach.h"
#import "KSBacktrace.h"
#import "KSBacktrace_Private.h"


#include <mach/mach_time.h>


#define kMaxFamesSupported 128
#define kMaxThreadsSupported 30

@interface LMGCDWatchdog()


@end
@implementation LMGCDWatchdog{
    
    
    processor_info_array_t cpuInfo, prevCpuInfo;
    mach_msg_type_number_t numCpuInfo, numPrevCpuInfo;
    unsigned numCPUs;
    NSLock *CPUUsageLock;
    
    LMGCDTimer *_watchdogBackgoundTimer;
    NSTimer     *_watchdogMainThreadTimer;
    
    uint64_t _mediaTimeWatchdogLastMainThreadPulse;
    
    
    dispatch_queue_t _watchdog_queue;
    
}
@synthesize queue = _queue;

+(instancetype)singleton{
    
    
    static dispatch_once_t pred;
    static LMGCDWatchdog *shared = nil;
    
    dispatch_once(&pred, ^{
        shared = [[LMGCDWatchdog alloc] init];
        
    });
    
    
    return shared;
}

-(void)createQueue{
    
    // Create operation queue:
    
    if (_queue == NULL) {
        

    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = infoDict[@"CFBundleIdentifier"];
    
    NSString *label = [NSString stringWithFormat:@"%@.LMGCDWatchdog", bundleId];
    NSUInteger maxBufferCount = sizeof(char) * (label.length + 1);
    
    char *_writeQueueLabel = (char *)malloc(maxBufferCount); // +1 for NULL termination
    
    BOOL ok = [label getCString:_writeQueueLabel maxLength:maxBufferCount encoding:NSUTF8StringEncoding];
    NSAssert(ok, @"Something wrong with LMGCDWatchdog queue label c string generation");
    
    _queue = dispatch_queue_create(_writeQueueLabel, DISPATCH_QUEUE_SERIAL);
    
    free(_writeQueueLabel);

    }
}

-(void)createWatchdogQueue{
    
    // Create operation queue:
    
    if(_watchdog_queue == NULL){
    NSDictionary *infoDict = [[NSBundle mainBundle] infoDictionary];
    NSString *bundleId = infoDict[@"CFBundleIdentifier"];
    
    NSString *label = [NSString stringWithFormat:@"%@.LMGCDWatchdog.watchdog", bundleId];
    NSUInteger maxBufferCount = sizeof(char) * (label.length + 1);
    
    char *_writeQueueLabel = (char *)malloc(maxBufferCount); // +1 for NULL termination
    
    BOOL ok = [label getCString:_writeQueueLabel maxLength:maxBufferCount encoding:NSUTF8StringEncoding];
    NSAssert(ok, @"Something wrong with LMGCDWatchdog queue label c string generation");
    
    _watchdog_queue = dispatch_queue_create(_writeQueueLabel, DISPATCH_QUEUE_SERIAL);
    
    //dispatch_set_target_queue(_watchdog_queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
    free(_writeQueueLabel);
    }
    
}

-(id)init{
    
    self = [super init];
    
    if (self){
        
        
        int mib[2U] = { CTL_HW, HW_NCPU };
        size_t sizeOfNumCPUs = sizeof(numCPUs);
        int status = sysctl(mib, 2U, &numCPUs, &sizeOfNumCPUs, NULL, 0U);
        if(status)
            numCPUs = 1;
        
        CPUUsageLock = [[NSLock alloc] init];
    
        [self createQueue];
        
    }
    return self;
}


-(void)dispatchDebug:(NSString *)name async:(void(^)())block{
    
#ifndef APPSTORE
    //if(name)DDLogCInfo(@"s: %@",name);
#endif

    if ([NSThread isMainThread]) {
        block();
        //if(name)DDLogCInfo(@"e: %@ (sync)",name);
        return;
    }
        dispatch_async(dispatch_get_main_queue(), ^{
            
            block();
#ifndef APPSTORE
            //if(name)DDLogCInfo(@"e: %@ (async)",name);
#endif
        });

    
}


#pragma mark - Watchdog:

-(void)startWatchDog{

    
    dispatch_async(dispatch_get_main_queue(), ^{

        _mediaTimeWatchdogLastMainThreadPulse = mach_absolute_time();
        
        [_watchdogMainThreadTimer invalidate];
        _watchdogMainThreadTimer = [NSTimer scheduledTimerWithTimeInterval:0.3 target:self selector:@selector(watchdorMainThreadPulse:) userInfo:nil repeats:YES];
        
        __weak LMGCDWatchdog *weakSelf = self;
        if (!_watchdogBackgoundTimer) {
            
            
            if (_watchdog_queue == NULL) {
                [self createWatchdogQueue];
            }
            
            _watchdogBackgoundTimer = [LMGCDTimer timerWithInterval:0.3 duration:0 leeway:0.3 repeat:YES startImmidiately:YES queue:_watchdog_queue block:^{
                
                [weakSelf watchdogOperation];
                
            }];
            
            _watchdogBackgoundTimer.name = @"watchdog";
        }else{
            
            _watchdogBackgoundTimer.interval = 0.3;
            [_watchdogBackgoundTimer resume];
        }

    
    });
    
    

}
-(void)stopWatchDog{

    dispatch_async(dispatch_get_main_queue(), ^{
    
        
        [_watchdogBackgoundTimer pause];
        [_watchdogMainThreadTimer invalidate];
        
    });
    
    
}

#pragma mark - Private:
-(void)watchdorMainThreadPulse:(NSTimer *)timer{

    _mediaTimeWatchdogLastMainThreadPulse = mach_absolute_time();
    
}
-(void)watchdogOperation{
    
    uint64_t tNow = mach_absolute_time();
    uint64_t passed = tNow - _mediaTimeWatchdogLastMainThreadPulse;
   
    /* Get the timebase info */
    static mach_timebase_info_data_t info;
    if (info.denom == 0)mach_timebase_info(&info);
    
    
    /* Do some code */
    
    
    /* Convert to nanoseconds */
    passed *= info.numer;
    passed /= info.denom;
    
    float inSec = (double)passed / NSEC_PER_SEC;
    
    
    if (inSec > 1) {
    
        [self watchdogLongerMainThreadBlockDetected];
    }

    
}

-(void)watchdogLongerMainThreadBlockDetected{
    
    _threadsStackTrace = [self threadsInfo];
    [self cpuInfo];
   
    [_delegate LMGCDWatchdogDidDetectLongerDeadlock:self];
    
}
#pragma mark - Info methods:

-(void)cpuInfo{
    
    natural_t numCPUsU = 0U;
    kern_return_t err = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &numCPUsU, &cpuInfo, &numCpuInfo);
    if(err == KERN_SUCCESS) {
        
        [CPUUsageLock lock];
        
        float inUseAll = 0, totalAll = 0;
        
        float ticks_user;
        float ticks_syst;
        float ticks_nice;
        float ticks_idle;

        
        for(unsigned i = 0U; i < numCPUs; ++i) {
            
            float inUse, total;
            
            int cpui = (CPU_STATE_MAX * i);
            
            if(prevCpuInfo) {
                
                ticks_user = (cpuInfo[cpui + CPU_STATE_USER]    - prevCpuInfo[cpui + CPU_STATE_USER]);
                ticks_syst = (cpuInfo[cpui + CPU_STATE_SYSTEM]  - prevCpuInfo[cpui + CPU_STATE_SYSTEM]);
                ticks_nice = (cpuInfo[cpui + CPU_STATE_NICE]    - prevCpuInfo[cpui + CPU_STATE_NICE]);
                ticks_idle = (cpuInfo[cpui + CPU_STATE_IDLE]    - prevCpuInfo[cpui + CPU_STATE_IDLE]);
                
            } else {
                
                ticks_user = (cpuInfo[cpui + CPU_STATE_USER]);
                ticks_syst = (cpuInfo[cpui + CPU_STATE_SYSTEM]);
                ticks_nice = (cpuInfo[cpui + CPU_STATE_NICE]);
                ticks_idle = (cpuInfo[cpui + CPU_STATE_IDLE]);
                
            }
            
            total = (ticks_user + ticks_syst + ticks_nice + ticks_idle);
            
            inUse = (ticks_user); // Add whatever oyu choose:  + ticks_syst + ticks_nice
            
            inUseAll += inUse;
            totalAll += total;
            
        }
        
        _cpuUsagePercent = (inUseAll / totalAll) * 100.0;
        
        [CPUUsageLock unlock];
        
        if(prevCpuInfo) {
            size_t prevCpuInfoSize = sizeof(integer_t) * numPrevCpuInfo;
            vm_deallocate(mach_task_self(), (vm_address_t)prevCpuInfo, prevCpuInfoSize);
        }
        
        prevCpuInfo = cpuInfo;
        numPrevCpuInfo = numCpuInfo;
        
        cpuInfo = NULL;
        numCpuInfo = 0U;
        
        _cpuUsagePercent = (inUseAll / totalAll) * 100;

        
    } else {
        //DDLogCInfo(@"cpu sample error!");
    }
    

    
}

-(NSString *)threadsInfo{

    /* Threads */
    
    NSMutableString *sss = [[NSMutableString alloc] initWithCapacity:10000];
    
    const task_t    this_task = mach_task_self();
    const thread_t  this_thread = mach_thread_self();
    
    kern_return_t kr;
    
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    
    kr = task_threads(this_task, &threads, &thread_count);
    
    
    // 1. Get a list of all threads:
    
    if (kr != KERN_SUCCESS) {
        
        thread_count = 0;
        printf("error getting threads: %s", mach_error_string(kr));
    
        return nil;
    }
    
    // 3. Get callstacks of all threads but not this:
    void * backtrace[kMaxFamesSupported];
    

    ///*
    [sss appendFormat:@"\n--- %i threads (current: %i): ", thread_count, this_thread];
    
    
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        
        thread_t thread = threads[i];
        
        if (this_thread == thread) {
            //printf("\n%i. thread: %i self - current, skipping", i + 1, thread);
            continue;
        }
        
        if((kr = thread_suspend(thread)) != KERN_SUCCESS)
        {
            continue;
            // Don't treat this as a fatal error.
        }


        
        int backtraceLength = ksbt_backtraceThread(thread, (uintptr_t*)backtrace, sizeof(backtrace));
        
        [sss appendFormat:@"\n%i. thread %i  backtrace %i frames: \n", i + 1, thread, backtraceLength];
        
    
        
        char** strs = backtrace_symbols(backtrace, backtraceLength);
        
        for(int a = 0; a < backtraceLength; ++a) {
            
            //printf("%lu ", backtrace[a]);
            
            if(backtrace[a])
                [sss appendFormat:@"%s \n",strs[a]];
            else
                break;
            
        }
        free(strs);
        
    
        if((kr = thread_resume(thread)) != KERN_SUCCESS){}
        
        mach_port_deallocate(this_task, thread);
    }
    
    
    mach_port_deallocate(this_task, this_thread);
    // 4. Deallocation:

    vm_deallocate(this_task, (vm_address_t)threads, sizeof(thread_t) * thread_count);
    
    return sss;

}


@end




