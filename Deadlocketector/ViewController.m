//
//  ViewController.m
//  Deadlocketector
//
//  Created by Lukasz Margielewski on 21/12/2014.
//  Copyright (c) 2014 Lukasz Margielewski. All rights reserved.
//

#import "ViewController.h"
#import "ATDispatcher.h"
#import "ATTimer.h"

@interface ViewController ()
@property (nonatomic, strong) NSTimer *timer;

@end

@implementation ViewController{

    ATTimer *timerLow;
    ATTimer *timerDef;
    ATTimer *timerHigh;
    ATTimer *timerBack;

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
    [self.timer invalidate];
    
    
    timer_low_count = timer_back_count = timer_def_count = timer_high_count = 0;
    
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(update:) userInfo:nil repeats:YES];
    
    [timerLow invalidate];
    timerLow = [ATTimer timerWithInterval:0.1 duration:0 leeway:0 repeat:YES startImmidiately:YES queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0) block:^{
    
    
        timer_low_count++;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
        
            self.timerLabelLow.text = [NSString stringWithFormat:@"%llu", timer_low_count];
        });
        
        
    }];
    
    [timerDef invalidate];
    timerDef = [ATTimer timerWithInterval:0.1 duration:0 leeway:0 repeat:YES startImmidiately:YES queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0) block:^{
        
        timer_def_count++;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
        
            self.timerLabelDef.text = [NSString stringWithFormat:@"%llu", timer_def_count];
        });
        
        
    }];
    
    [timerBack invalidate];
    timerBack = [ATTimer timerWithInterval:0.1 duration:0 leeway:0 repeat:YES startImmidiately:YES queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0) block:^{
        
        timer_back_count++;
        
        dispatch_sync(dispatch_get_main_queue(), ^{
        
            self.timerLabelBack.text = [NSString stringWithFormat:@"%llu", timer_back_count];
        });
        
        
        
    }];
    
    [timerHigh invalidate];
    timerHigh = [ATTimer timerWithInterval:0.1 duration:0 leeway:0 repeat:YES startImmidiately:YES queue:dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0) block:^{
        
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
    
    float perc = [ATDispatcher singleton].cpuUsagePercent;
    NSString *percText = [NSString stringWithFormat:@"%.1f", perc];
    self.cpuPercentLabel.text = percText;
    
}

-(IBAction)stopWatchdog:(id)sender{

    [[ATDispatcher singleton] stopWatchDog];
}
-(IBAction)startWatchdog:(id)sender{

    [[ATDispatcher singleton] startWatchDogTimerWithInterval:0.1 withDuration:0];
}

-(IBAction)scheduleDeadlock:(id)sender{

    
}
@end
