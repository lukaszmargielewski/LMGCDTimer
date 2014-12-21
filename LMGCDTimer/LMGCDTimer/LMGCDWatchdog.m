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

@implementation LMGCDWatchdog{
    
    
    processor_info_array_t cpuInfo, prevCpuInfo;
    mach_msg_type_number_t numCpuInfo, numPrevCpuInfo;
    unsigned numCPUs;
    NSLock *CPUUsageLock;
    
    LMGCDTimer *_watchdog;
    
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
    
    dispatch_set_target_queue(_watchdog_queue, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0));
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

-(void)startWatchDogTimerWithInterval:(NSTimeInterval)interval withDuration:(NSTimeInterval)duration{

    __weak LMGCDWatchdog *weakSelf = self;
    
    if (!_watchdog) {
        
        
        if (_watchdog_queue == NULL) {
            [self createWatchdogQueue];
        }
        
        _watchdog = [LMGCDTimer timerWithInterval:interval duration:duration leeway:0 repeat:YES startImmidiately:YES queue:_watchdog_queue block:^{
            
            [weakSelf watchdogOperation];
            
        }];
        
        _watchdog.name = @"watchdog";
    }else{
    
        _watchdog.interval = interval;
        [_watchdog resume];
    }


}
-(void)stopWatchDog{

    [_watchdog pause];
}

#pragma mark - Private:

-(void)watchdogOperation{
    
    /*
    double loadavg[3];
    getloadavg(loadavg, 3);
    DDLogCInfo(@"- %.2f", loadavg[0]);
    return;

    */
    //DDLogCInfo(@"-- wd start --");
    
    [self cpuInfo];
    [self threadInfo];
    
    //DDLogCInfo(@"-- wd end --");
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
            
            //DDLogCInfo(@"cp: %u -> %.2f",i,inUse / total);
            
        }
        
        
        
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
-(void)threadInfo{

    /* Threads */
    
    
    thread_act_array_t threads;
    mach_msg_type_number_t thread_count;
    
    /* Get a list of all threads */
    if (task_threads(mach_task_self(), &threads, &thread_count) != KERN_SUCCESS) {
        
        thread_count = 0;
    }
    
    void *callstack[128];
    
    ///*
    printf("--- %i threads (self: %i): ", thread_count, pl_mach_thread_self());
    
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        printf("%i, ", threads[i]);}
    
    printf("\n");
    
    char name[256];
    
    for (mach_msg_type_number_t i = 0; i < thread_count; i++) {
        
        thread_t thread = threads[i];
        
        if (pl_mach_thread_self() == thread) {
            printf("%i. thread: self - skipping self\n", i + 1);
            
        }
        
        pthread_t pt = pthread_from_mach_thread_np(thread);
        
        if (pt) {
            name[0] = '\0';
            int rc = pthread_getname_np(pt, name, sizeof name);
            NSLog(@"mach thread %u: getname returned %d: %s", thread, rc, name);
        } else {
            NSLog(@"mach thread %u: no pthread found", thread);
        }
        
        
        
        int framesC = GetCallstack(pt, callstack, sizeof(callstack));
        
        printf("%i. thread: %i backtrace() returned %d addresses\n", i + 1, thread, framesC);
        
        char** strs = backtrace_symbols(callstack, framesC);
        for(int a = 0; a < framesC; ++a) {
            if(strs[a])
                printf("%s\n", strs[a]);
            else
                break;
        }
        free(strs);
        
    }
    

    printf("------\n");
    
   // */
    
    
    vm_deallocate(mach_task_self(), (vm_address_t)threads, sizeof(thread_t) * thread_count);

}


/**
 * Return a borrowed reference to the current thread's mach port. This differs
 * from mach_thread_self(), which acquires a new reference to the backing thread.
 *
 * @note The mach_thread_self() reference counting semantics differ from mach_task_self();
 * mach_task_self() returns a borrowed reference, and will not leak -- a wrapper
 * function such as this is not required for mach_task_self().
 */
thread_t pl_mach_thread_self (void) {
    thread_t result = mach_thread_self();
    mach_port_deallocate(mach_task_self(), result);
    return result;
}


static pthread_t callingThread = 0;
static pthread_t targetThread = 0;
static void** threadCallstackBuffer = NULL;
static int threadCallstackBufferSize = 0;
static int threadCallstackCount = 0;

#define CALLSTACK_SIG SIGUSR2

void* GetPCFromUContext(void* ucontext);

__attribute__((noinline))
static void _callstack_signal_handler(int signr, siginfo_t *info, void *secret) {
    
    pthread_t myThread = pthread_self();

    if(myThread != targetThread) {
    
        printf("myThread (%lu) != targetThread (%lu) - returning", myThread, targetThread);
        return;
    
    }
    threadCallstackCount = backtrace(threadCallstackBuffer, threadCallstackBufferSize);
    
    // Search for the frame origin.
    for(int i = 1; i < threadCallstackCount; ++i) {
        if(threadCallstackBuffer[i] != NULL) continue;
        
        // Found it at stack[i]. Thus remove the first i.
        const int IgnoreTopFramesNum = i;
        threadCallstackCount -= IgnoreTopFramesNum;
        memmove(threadCallstackBuffer, threadCallstackBuffer + IgnoreTopFramesNum, threadCallstackCount * sizeof(void*));
        threadCallstackBuffer[0] = GetPCFromUContext(secret); // replace by real PC ptr
        break;
    }
    
    // continue calling thread
    pthread_kill(callingThread, CALLSTACK_SIG);
}

static void _setup_callstack_signal_handler() {
    struct sigaction sa;
    sigfillset(&sa.sa_mask);
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = _callstack_signal_handler;
    sigaction(CALLSTACK_SIG, &sa, NULL);
}

__attribute__((noinline))
int GetCallstack(pthread_t threadId, void **buffer, int size) {
    
    if(threadId == 0 || threadId == pthread_self()) {
        int count = backtrace(buffer, size);
        static const int IgnoreTopFramesNum = 1; // remove this `GetCallstack` frame
        if(count > IgnoreTopFramesNum) {
            count -= IgnoreTopFramesNum;
            memmove(buffer, buffer + IgnoreTopFramesNum, count * sizeof(void*));
        }
        return count;
    }
    
    //Mutex::ScopedLock lock(callstackMutex.get());
    callingThread = pthread_self();
    targetThread = threadId;
    threadCallstackBuffer = buffer;
    threadCallstackBufferSize = size;
    
    _setup_callstack_signal_handler();
    
    // call _callstack_signal_handler in target thread
    int eee = pthread_kill(threadId, CALLSTACK_SIG);
    
    if(eee != 0){
        // something failed ...
       
         printf("pthread_kill error: %i ", eee);
        switch (eee) {
            case EINVAL:
                printf("(EINVAL) sig is an invalid or unsupported signal number.\n");
                break;
                case ESRCH:
                printf("(ESRCH) thread %lu is an invalid thread ID.\n", threadId);
                break;
            default:
                break;
        }
       
        return 0;
    }

    {
        sigset_t mask;
        sigfillset(&mask);
        sigdelset(&mask, CALLSTACK_SIG);
        
        // wait for CALLSTACK_SIG on this thread
        //sigsuspend(&mask);
    }
    
    threadCallstackBuffer = NULL;
    threadCallstackBufferSize = 0;
    return threadCallstackCount;
}


@end




