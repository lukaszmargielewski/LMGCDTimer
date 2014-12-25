//
//  ViewController.m
//  LMGCDTimer
//
//  Created by Lukasz Margielewski on 21/12/2014.
//  Copyright (c) 2014 Lukasz Margielewski. All rights reserved.
//

#import "ViewController.h"
#import "LMGCDWatchdog.h"
#import "LMGCDTimer.h"

@interface ViewController ()
@property (nonatomic, strong) NSTimer *timer;

@end

@implementation ViewController{

    LMGCDTimer *timerLow;
    LMGCDTimer *timerDef;
    LMGCDTimer *timerHigh;
    LMGCDTimer *timerBack;

    unsigned long long timer_low_count;
    unsigned long long timer_def_count;
    unsigned long long timer_back_count;
    unsigned long long timer_high_count;
}

-(void)dealloc{

    [self.timer invalidate];
    [timerLow invalidate];
    [timerDef invalidate];
    [timerHigh invalidate];
    
}
- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view, typically from a nib.
    
    //return;
    [self.timer invalidate];
    
    
    timer_low_count = timer_back_count = timer_def_count = timer_high_count = 0;
    
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(update:) userInfo:nil repeats:YES];
    
    [timerLow invalidate];
    timerLow = [LMGCDTimer timerWithInterval:0.05 duration:0 leeway:0 repeat:YES startImmidiately:YES queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0) block:^{
    
    
        timer_low_count++;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
        
            self.timerLabelLow.text = [NSString stringWithFormat:@"%llu", timer_low_count];
        });
        
        
    }];
    
    [timerDef invalidate];
    timerDef = [LMGCDTimer timerWithInterval:0.1 duration:0 leeway:0 repeat:YES startImmidiately:YES queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) block:^{
        
        timer_def_count++;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
        
            self.timerLabelDef.text = [NSString stringWithFormat:@"%llu", timer_def_count];
        });
        
        
    }];
    
    [timerBack invalidate];
    timerBack = [LMGCDTimer timerWithInterval:0.15 duration:0 leeway:0 repeat:YES startImmidiately:YES queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0) block:^{
        
        timer_back_count++;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
        
            self.timerLabelBack.text = [NSString stringWithFormat:@"%llu", timer_back_count];
        });
        
        
        
    }];
    
    [timerHigh invalidate];
    timerHigh = [LMGCDTimer timerWithInterval:0.2 duration:0 leeway:0 repeat:YES startImmidiately:YES queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0) block:^{
        
        timer_high_count++;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
        
            self.timerLabelHigh.text = [NSString stringWithFormat:@"%llu", timer_high_count];
        });
        
        
        
    }];
    
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}
-(void)update:(NSTimer *)timer{
    
    float perc = [LMGCDWatchdog singleton].cpuUsagePercent;
    NSString *percText = [NSString stringWithFormat:@"%.1f", perc];
    self.cpuPercentLabel.text = percText;
    
}

-(IBAction)stopWatchdog:(id)sender{

    [[LMGCDWatchdog singleton] stopWatchDog];
}
-(IBAction)startWatchdog:(id)sender{

    [[LMGCDWatchdog singleton] startWatchDog];
}

-(IBAction)scheduleDeadlock:(id)sender{

    for (long long i = 0; i < 1000000; i++) {
        
        [self.view setNeedsLayout];
    }
    
}
@end
