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

#include <map>
#include <utility>
using namespace std;

#include <mach/mach_time.h>


#define kMaxFamesSupported 128
#define kMaxThreadsSupported 30


static inline NSTimeInterval timeIntervalFromMach(uint64_t mach_time){
    
    mach_timebase_info_data_t info;
    
    //if (info.denom == 0) {
        (void) mach_timebase_info(&info);
    //}
    
    uint64_t nanos = mach_time * info.numer / info.denom;
    NSTimeInterval seconds = (double)nanos / NSEC_PER_SEC;
    
    return seconds;
    
}

typedef struct BacktraceStruct{

    uintptr_t backtrace[kMaxFamesSupported];
    int lenght;

}BacktraceStruct;

@interface LMGCDWatchdog()

@property (nonatomic) float cpuUsagePercent;
@property (nonatomic, strong) NSString *threadsStackTrace;

@end
@implementation LMGCDWatchdog{
    
    
    processor_info_array_t cpuInfo, prevCpuInfo;
    mach_msg_type_number_t numCpuInfo, numPrevCpuInfo;
    unsigned numCPUs;
    NSLock *CPUUsageLock;
    
    LMGCDTimer *_watchdogBackgoundTimer;
    
    uint64_t _time_start;
    
    dispatch_queue_t _watchdog_queue;
    BOOL _waiting_in_main_queue;
    BOOL _deadlock;
    
    
    CFMutableDictionaryRef _threadsDict;
    
    map<int, BacktraceStruct>_threadsMap;
    map<int, int>_threadsStates;

    
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

    
    if (_threadsDict != NULL) {
        
        CFRelease(_threadsDict);
        _threadsDict = NULL;
    }
    // Dictionary With Non Retained Keys and Object Values
    _threadsDict = CFDictionaryCreateMutable(NULL, 0, NULL, &kCFTypeDictionaryValueCallBacks);
    
        __weak LMGCDWatchdog *weakSelf = self;
        if (!_watchdogBackgoundTimer) {
            
            
            if (_watchdog_queue == NULL) {
                [self createWatchdogQueue];
            }
            
            _watchdogBackgoundTimer = [LMGCDTimer timerWithInterval:.5 duration:0 leeway:0.1 repeat:YES startImmidiately:YES queue:_watchdog_queue block:^{
                
                [weakSelf watchdogOperation];
                //[weakSelf threadsAnalytics];
                [weakSelf threadsAnalyticsSimple];
                
            }];
            
            _watchdogBackgoundTimer.name = @"watchdog";
        }else{
            
            _watchdogBackgoundTimer.interval = .5;
            [_watchdogBackgoundTimer resume];
        }
}
-(void)stopWatchDog{
    
        [_watchdogBackgoundTimer pause];
    
}

#pragma mark - Private:

-(void)watchdogOperation{
    
    
    if(!_waiting_in_main_queue){
    
        _waiting_in_main_queue = YES;
        _time_start = mach_absolute_time();
        
        dispatch_async(dispatch_get_main_queue(), ^{
            
            _waiting_in_main_queue = NO;
            
            if (_deadlock) {
                
                uint64_t tNow = mach_absolute_time();
                _deadlock = NO;                
                NSTimeInterval seconds = timeIntervalFromMach(tNow - _time_start);
                
                [_delegate LMGCDWatchdog:self deadlockDidFinishWithduration:seconds];
            }
        });

    }else{
    
        if (!_deadlock) {
            _deadlock = YES;
            
            self.threadsStackTrace = [self threadsInfo];
            [self cpuInfo];
            
            [_delegate LMGCDWatchdogDidDetectLongerDeadlock:self stackTrace:_threadsStackTrace cpuUsagePercent:_cpuUsagePercent];
            
            //printf("<!");
        }

    }
    
}


#pragma mark - Info methods:

-(float)cpuInfo{
    
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

        return _cpuUsagePercent;
        
    } else {
        //DDLogCInfo(@"cpu sample error!");
    }
    

    return -1;
    
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


        void *backtrace[kMaxFamesSupported];
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
    vm_deallocate(this_task, (vm_address_t)threads, sizeof(thread_t) * thread_count);
    
    return sss;

}

-(BOOL)threadsAnalytics{
    
    /* Threads */
    
    uint64_t ts     = mach_absolute_time();
    const task_t    this_task = mach_task_self();
    const thread_t  this_thread = mach_thread_self();
    
    kern_return_t kr;
    
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    
    kr = task_threads(this_task, &threads, &thread_count);
    
    
    // 1. Get a list of all threads:
    
    if (kr != KERN_SUCCESS) {
        printf("error getting threads: %s", mach_error_string(kr));
        return NO;
    }
    
    // 2. Get callstacks of all threads but not this:
    
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        
        thread_t thread = threads[i];
        
        if (this_thread == thread)continue;
        
        thread_info_data_t     thinfo;
        mach_msg_type_number_t thread_info_count;
        thread_info_count = THREAD_INFO_MAX;
        
        kr = thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if(kr != KERN_SUCCESS)continue;
           
        thread_basic_info_t basic_info_th;
        basic_info_th = (thread_basic_info_t)thinfo;
        
        if((kr = thread_suspend(thread)) != KERN_SUCCESS)continue;
        
        BacktraceStruct bs;
        bs.lenght = ksbt_backtraceThread(thread, (uintptr_t* const)bs.backtrace, sizeof(bs.backtrace));
        
        if((kr = thread_resume(thread)) != KERN_SUCCESS){}

        
        
        BacktraceStruct bsPrev = _threadsMap[thread];
        
        int c = MIN(bsPrev.lenght, bs.lenght);
        
        //printf("\nthread: %i \n", thread);
        if (c > 0) {
          
            // Prev:
            for(int a = 0; a < bsPrev.lenght; a++){
            
                uintptr_t pointer_prev = bsPrev.backtrace[a];
                //printf("%lu ", pointer_prev);
                
            }
            
            //printf("\n");
            //char** strs = backtrace_symbols((void * const *)(bsPrev.backtrace), bsPrev.lenght);
            
            for(int a = 0; a < bsPrev.lenght; ++a) {
                //if(bsPrev.backtrace[a])
                   // printf("%s\n", strs[a]);
            }
            //free(strs);
            
            // This:
            
            //printf("\n");
            for(int a = 0; a < bs.lenght; a++){
                
                uintptr_t pointer_this = bs.backtrace[a];
                //printf("%lu ", pointer_this);
            }
            
            //printf("\n");
            //strs = backtrace_symbols((void * const *)(bs.backtrace), bs.lenght);
            
            for(int a = 0; a < bs.lenght; ++a) {
                //if(bs.backtrace[a])
                    //printf("%s\n", strs[a]);
            }
            //free(strs);
            
            //printf("\n");
            
            if (bs.lenght != bsPrev.lenght) {
                //printf("\n diffrence!!! \n");
            }
            
        }
        
        //CFDictionarySetValue(_threadsDict, (void *)thread, (void *)&bs);
        
        _threadsMap[thread] = bs;
        
        mach_port_deallocate(this_task, thread);
    }

    
    //printf("\n *************** \n");
    
    mach_port_deallocate(this_task, this_thread);
    vm_deallocate(this_task, (vm_address_t)threads, sizeof(thread_t) * thread_count);
    
    uint64_t te = mach_absolute_time();
    
    printf("\n analytics sec: %f (%llu)" , timeIntervalFromMach(te - ts), te - ts);
    return NO;
}

-(BOOL)threadsAnalyticsSimple{
    
    /* Threads */
    
    uint64_t ts     = mach_absolute_time();
    const task_t    this_task = mach_task_self();
    const thread_t  this_thread = mach_thread_self();
    
    kern_return_t kr;
    
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    
    kr = task_threads(this_task, &threads, &thread_count);
    
    
    // 1. Get a list of all threads:
    
    if (kr != KERN_SUCCESS) {
        printf("error getting threads: %s", mach_error_string(kr));
        return NO;
    }
    
    // 2. Get callstacks of all threads but not this:
    
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        
        thread_t thread = threads[i];
        
        if (this_thread == thread)continue;
        
        thread_info_data_t     thinfo;
        mach_msg_type_number_t thread_info_count = THREAD_INFO_MAX;
        
        kr = thread_info(thread, THREAD_BASIC_INFO, (thread_info_t)thinfo, &thread_info_count);
        if(kr != KERN_SUCCESS)continue;
        
        thread_basic_info_t basic_info_th = (thread_basic_info_t)thinfo;
        integer_t run_state = basic_info_th->run_state;
        
        /*
        
        arm_unified_thread_state state;
        mach_msg_type_number_t state_count = ARM_UNIFIED_THREAD_STATE_COUNT;
        kr = thread_get_state(thread, ARM_UNIFIED_THREAD_STATE, (thread_state_t) &state, &state_count);

        */
        /*
        STRUCT_MCONTEXT_L machineContext;
        
        if(!ksmach_threadState(thread, &machineContext))
        {
            return 0;
        }
        */

        if (run_state != _threadsStates[thread]) {
            
            char const *sss;
            char const *pref;
            switch (run_state) {
                case TH_STATE_RUNNING:
                {
                    
                    sss = "running";
                    pref = "--- > ";
                }
                    break;
                case TH_STATE_STOPPED:
                {
                
                    sss = "stopped";
                    pref = "--- < ";
                }
                    
                    break;
                case TH_STATE_WAITING:
                {
                
                    sss = "waiting";
                    pref = "--- < ";
                
                }
                    //printf("\nthread %u is TH_STATE_WAITING", thread);
                    break;
                case TH_STATE_UNINTERRUPTIBLE:
                {
                    sss = "TH_STATE_UNINTERRUPTIBLE";
                    pref = "--- ! ";
                }
                    //printf("\nthread %u is TH_STATE_UNINTERRUPTIBLE", thread);
                    break;
                case TH_STATE_HALTED:
                    //printf("\nthread %u is TH_STATE_HALTED", thread);
                    sss = "halted";
                    pref = "--- # ";
                    break;
                default:
                    sss  = "unknown";
                    pref = "--- ? ";
                    break;
            }
            
            char queue_name[100];
            char thread_name[100];
            
            bool qn = ksmach_getThreadQueueName(thread, queue_name, 100);
            bool tn = ksmach_getThreadName(thread, thread_name, 100);
            
            NSString *aaa = [NSString stringWithFormat:@" %s thread %u (name: %s) (queue: %s) is %s | threads: %i", pref, thread, thread_name, queue_name, sss, thread_count];
            
        
            //printf("\n --- thread %u (name: %s) (queue: %s) is %s", thread, thread_name, queue_name, sss);
            [_delegate LMGCDWatchdog:self didDetectThreadStateChange:aaa];
        }
        
        
        
        _threadsStates[thread] = run_state;
        
        
        mach_port_deallocate(this_task, thread);
    }
    
    
    //printf("\n *************** \n");
    
    mach_port_deallocate(this_task, this_thread);
    vm_deallocate(this_task, (vm_address_t)threads, sizeof(thread_t) * thread_count);
    
    uint64_t te = mach_absolute_time();
    
    //printf("\n analytics sec: %f (%llu)\n\n" , timeIntervalFromMach(te - ts), te - ts);
    return NO;
}


@end




