//
//  LMGCDWatchdog.h
//  FF
//
//  Created by Lukasz Margielewski on 10/12/2014.
//
//

#import <Foundation/Foundation.h>



@interface LMGCDWatchdog : NSObject

@property (nonatomic, readonly) dispatch_queue_t queue;
@property (nonatomic) float cpuUsagePercent;

+(instancetype)singleton;

#pragma mark - Watchdog:

-(void)stopWatchDog;
-(void)startWatchDog;


@end
